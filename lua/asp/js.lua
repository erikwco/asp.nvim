-- Capa JavaScript de cliente de asp-ls: definición y referencias de los
-- identificadores de los bloques <script> del buffer, con el mismo contrato
-- que asp.symbols (Location / lista de Location / nil). El scope global de
-- la página se extiende con las declaraciones globales de los `.js` de sus
-- `<script src>` y del JS de las páginas incluidas (ver each_external).
--
-- Dos decisiones de diseño, ambas por determinismo:
--
--  * NO se usa la inyección html → javascript. Esa la trae
--    queries/html/injections.scm de nvim-treesitter, que no siempre está en
--    el runtimepath (no viene en $VIMRUNTIME); en su lugar los <script> se
--    ubican en la capa html que inyecta el propio plugin y su contenido se
--    parsea con un parser javascript PROPIO, confinado a esos rangos (ver
--    js_source sobre cómo se neutralizan los bloques <% %> de adentro).
--  * NO se usa vim.treesitter.get_node() global: ver el comentario extenso
--    de asp.symbols.M.definition sobre la carrera con el highlighter
--    incremental. Este parser no lo toca nadie más, así que el árbol que se
--    consulta es siempre el mismo para un mismo changedtick.
local M = {}

-- SymbolKind (LSP): Class=5, Method=6, Function=12, Variable=13, Constant=14

-- El nombre de una declaración de función es visible en el scope que la
-- contiene; el de una function expression con nombre (`function f() {}`
-- como valor) sólo dentro de la propia función.
local FUNCTION_DECLARATIONS = {
  function_declaration = true,
  generator_function_declaration = true,
}

local FUNCTION_EXPRESSIONS = {
  function_expression = true,
  generator_function = true,
}

-- type de <script> que el navegador ejecuta como JavaScript (la lista de
-- "JavaScript MIME type" de HTML, sin parámetros). Además de los actuales
-- incluye los legacy que aún aparecen en páginas de la época de Classic ASP
-- (text/jscript, application/x-javascript, ...). type="" equivale a ausente.
local JS_TYPES = {
  [''] = true,
  module = true,
  ['text/javascript'] = true,
  ['application/javascript'] = true,
  ['text/ecmascript'] = true,
  ['application/ecmascript'] = true,
  ['text/jscript'] = true,
  ['text/livescript'] = true,
  ['application/x-javascript'] = true,
  ['application/x-ecmascript'] = true,
  ['text/x-javascript'] = true,
  ['text/x-ecmascript'] = true,
}

-- Todo <script>, también los de `src` (sin raw_text): el cuerpo se busca
-- entre los hijos (ver script_regions).
local SCRIPT_QUERY = [[ (script_element (start_tag) @tag) @script ]]
local CONTENT_QUERY = [[ (content) @content ]]
--  * @scope: los nodos que abren un scope. let/const se tratan como var
--    (function-scoped, no block-scoped): límite documentado.
--  * @id: los identificadores resolubles. shorthand_property_identifier es
--    la `x` de `{ x }`: una lectura de la variable `x`, no una propiedad.
--  * @method: los nombres de método son property_identifier: se capturan
--    aparte sólo para el outline (documentSymbol); no son resolubles como
--    identificador suelto (se usan como `obj.metodo`, resolución por
--    objetos: fuera de alcance).
local JS_QUERY = [[
[
  (function_declaration)
  (generator_function_declaration)
  (function_expression)
  (generator_function)
  (arrow_function)
  (method_definition)
] @scope
(identifier) @id
(shorthand_property_identifier) @id
(method_definition name: (property_identifier) @method)
]]

-- Tipos de nodo de @id: los únicos que se resuelven bajo el cursor.
local IDENTIFIERS = {
  identifier = true,
  shorthand_property_identifier = true,
}

local function is_field(parent, field, node)
  local f = parent:field(field)[1]
  return f ~= nil and f:equal(node)
end

-- Misma semántica que el range_contains de asp.symbols (límites
-- inclusivos): confina la búsqueda al árbol javascript que contiene la
-- posición.
local function range_contains(node, row, col)
  local sr, sc, er, ec = node:range()
  if row < sr or (row == sr and col < sc) then return false end
  if row > er or (row == er and col > ec) then return false end
  return true
end

local function start_byte_of(node)
  local _, _, b = node:start()
  return b
end

---Intervalos de bytes `{inicio, fin, output}` (fin exclusivo) de los
---bloques ASP de la plantilla, en orden del documento: todo hijo de la raíz
---que no es `content`; `output` marca los `<%= %>`. La capa html sólo ve
---los `content`, así que un nodo html que se cruza con alguno se armó con
---ASP (ver script_attrs), y en el javascript un identificador que se cruza
---con alguno es VBScript (ver js_source y overlaps_asp).
---@param root TSNode raíz de la plantilla aspclassic
---@return table[] blocks
local function asp_blocks(root)
  local blocks = {}
  for i = 0, root:named_child_count() - 1 do
    local child = root:named_child(i)
    if child:type() ~= 'content' then
      local _, _, sb, _, _, eb = child:range(true)
      table.insert(blocks, { sb, eb, output = child:type() == 'output_directive' })
    end
  end
  return blocks
end

---¿El tramo de bytes [sb, eb) se cruza con algún bloque ASP? Los bloques
---están ordenados y no se solapan, así que basta mirar el último que
---empieza antes de `eb` (búsqueda binaria).
---@param blocks table[] de asp_blocks
---@param sb integer
---@param eb integer
---@return boolean
local function overlaps_asp(blocks, sb, eb)
  local lo, hi, last = 1, #blocks, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if blocks[mid][1] < eb then
      last, lo = mid, mid + 1
    else
      hi = mid - 1
    end
  end
  return last ~= nil and blocks[last][2] > sb
end

---Atributos del start_tag de un <script>: nombre en minúsculas → valor sin
---comillas ni espacios exteriores. Atributo repetido: HTML se queda con el
---primero.
---
---También devuelve el conjunto de nombres de los atributos que se arman
---con ASP. Eso se decide sobre el rango del `attribute` completo, no sobre
---el texto del valor: el parser html no ve los bloques ASP, así que en
---`src="<%= base %>a.js"` el `attribute_value` interior es sólo `a.js` y
---parecería estático. Sin comillas el valor sigue hasta el primer blanco o
---`>`: un bloque pegado a su final (`src=a.js<%= v %>`) también es parte
---del valor, aunque el `attribute` termine justo donde empieza el bloque.
---@param tag TSNode start_tag
---@param source integer|string bufnr o texto del archivo
---@param blocks table[] de asp_blocks
---@return table<string, string> attrs, table<string, true> dynamic
local function script_attrs(tag, source, blocks)
  local attrs, dynamic = {}, {}
  for child in tag:iter_children() do
    if child:type() == 'attribute' then
      local name, value, quoted
      for part in child:iter_children() do
        local t = part:type()
        if t == 'attribute_name' then
          name = vim.treesitter.get_node_text(part, source):lower()
        elseif t == 'attribute_value' then
          value = vim.treesitter.get_node_text(part, source)
        elseif t == 'quoted_attribute_value' then
          local inner = part:named_child(0)
          value = inner and vim.treesitter.get_node_text(inner, source) or ''
          quoted = true
        end
      end
      if name and attrs[name] == nil then
        attrs[name] = vim.trim(value or '')
        local _, _, sb, _, _, eb = child:range(true)
        if overlaps_asp(blocks, sb, (value and not quoted) and eb + 1 or eb) then
          dynamic[name] = true
        end
      end
    end
  end
  return attrs, dynamic
end

---¿Los atributos son los de un <script> de JavaScript de cliente? Excluye
---el JScript de servidor (`runat="server"`), los type que no son JS
---(`text/template`, ...) y, sin type, el `language` legacy que no lo es
---(`language="VBScript"` es VBScript de cliente de IE: HTML lo trata como
---type `text/vbscript`).
---@param attrs table<string, string> de script_attrs
---@return boolean
local function is_client_js(attrs)
  if (attrs.runat or ''):lower() == 'server' then return false end
  local mime = attrs.type and attrs.type:lower()
  if mime == nil and attrs.language and attrs.language ~= '' then
    mime = 'text/' .. attrs.language:lower()
  end
  if mime == nil then return true end
  mime = vim.trim(mime:match('^[^;]*'))
  return JS_TYPES[mime] == true or mime:match('^text/javascript1%.[0-5]$') ~= nil
end

---Regiones (una por <script> de JS de cliente) para el parser javascript:
---el rango del `raw_text` de cada bloque. También devuelve los `src` de
---esos <script>, en orden del documento y sin resolver. Un `src` armado
---con ASP (`<%= base %>a.js`) se resuelve en runtime: no se puede seguir y
---se omite.
---
---Una región por <script> (no una sola combinada): un error de sintaxis en
---un bloque no altera el parseo de los siguientes, igual que en el
---navegador. El scope global compartido entre bloques se resuelve después,
---en resolve().
---@param html vim.treesitter.LanguageTree capa html, ya parseada
---@param source integer|string bufnr o texto del archivo
---@param blocks table[] de asp_blocks
---@return Range6[][] regions, string[] srcs
local function script_regions(html, source, blocks)
  local regions, srcs = {}, {}
  local sq = vim.treesitter.query.parse('html', SCRIPT_QUERY)
  local found = {}
  for _, tree in pairs(html:trees()) do
    for _, match in sq:iter_matches(tree:root(), source) do
      local tag, script
      for id, nodes in pairs(match) do
        -- Neovim 0.10 entrega un nodo por captura; 0.11+ una lista.
        if type(nodes) ~= 'table' then nodes = { nodes } end
        if sq.captures[id] == 'tag' then tag = nodes[1] end
        if sq.captures[id] == 'script' then script = nodes[1] end
      end
      if tag and script then
        table.insert(found, { tag = tag, script = script, sb = start_byte_of(script) })
      end
    end
  end
  -- La capa html del buffer puede traer varios árboles (pairs no tiene
  -- orden): el orden de los src es el de prioridad de resolución.
  table.sort(found, function(a, b) return a.sb < b.sb end)

  for _, f in ipairs(found) do
    local attrs, dynamic = script_attrs(f.tag, source, blocks)
    if is_client_js(attrs) then
      for child in f.script:iter_children() do
        if child:type() == 'raw_text' then
          table.insert(regions, { { child:range(true) } })
        end
      end
      if attrs.src and attrs.src ~= '' and not dynamic.src then
        table.insert(srcs, attrs.src)
      end
    end
  end
  return regions, srcs
end

---Texto tal como lo ve el parser javascript: cada bloque ASP de la
---plantilla (todo hijo que no es `content`) se reemplaza byte a byte,
---conservando los saltos de línea, por un relleno de la misma longitud, así
---las posiciones coinciden con las del texto original:
---
---  * `<%= x %>` → `________`, un identificador de relleno. Un `<%= %>` casi
---    siempre es un VALOR dentro del JS (`var n = <%= x %>;`, `f(<%= a %>)`,
---    `"<%= s %>"`), y con un identificador en su lugar el JS parsea limpio.
---    Con el texto crudo, `<%` se lee como JSX y el error se traga el resto
---    del bloque; con blancos, `var n = ;` hace que la recuperación de
---    errores tome la `function` siguiente como el valor de `n` (y deje de
---    ser una declaración global).
---  * `<% ... %>` y las directivas → blancos: son sentencias VBScript
---    (`<% If x Then %>...<% End If %>`) que no aportan nada al JS.
---
---Un identificador que se cruza con algún bloque es VBScript, entero (el
---relleno de un `<%= %>`) o en parte (`foo<%= x %>` se parsea como el
---identificador `foo________`), y se descarta (ver index_js).
---
---Sirve igual para el buffer (sus líneas unidas con `\n`) y para un archivo
---de disco (su contenido), con los bloques de la plantilla parseada de ese
---mismo texto.
---@param text string
---@param blocks table[] de asp_blocks sobre `text`
---@return string source
local function js_source(text, blocks)
  local parts, prev = {}, 0
  for _, b in ipairs(blocks) do
    local sb, eb = b[1], b[2]
    table.insert(parts, text:sub(prev + 1, sb))
    table.insert(parts, (text:sub(sb + 1, eb):gsub('[^\n]', b.output and '_' or ' ')))
    prev = eb
  end
  table.insert(parts, text:sub(prev + 1))
  return table.concat(parts)
end

---Clasifica un `identifier` como nombre de declaración. Devuelve kind, el
---nodo de la declaración y dónde vive el nombre respecto del scope más
---interno que contiene al identificador:
---
---  * 'outer': en el scope que envuelve a ese (el nombre de una function
---    declaration, cuyo scope más interno es la propia función).
---  * 'name': en un binding propio de la function expression, visible sólo
---    dentro de ella y por debajo de sus parámetros y locales
---    (`function f(f) { return f; }` devuelve el parámetro).
---  * 'inner': en ese mismo scope (variables, clases, parámetros).
---
---nil si el identificador es un uso.
---@param n TSNode
---@return integer|nil kind, TSNode|nil decl, string|nil where
local function classify(n)
  local p = n:parent()
  if not p then return nil end
  local pt = p:type()
  if FUNCTION_DECLARATIONS[pt] and is_field(p, 'name', n) then
    return 12, p, 'outer'
  elseif FUNCTION_EXPRESSIONS[pt] and is_field(p, 'name', n) then
    return 12, p, 'name'
  elseif pt == 'class_declaration' and is_field(p, 'name', n) then
    return 5, p, 'inner'
  elseif pt == 'variable_declarator' and is_field(p, 'name', n) then
    local gp = p:parent()
    local gt = gp and gp:type()
    if gt == 'variable_declaration' then
      return 13, p, 'inner'
    elseif gt == 'lexical_declaration' then
      -- El primer hijo de lexical_declaration es la keyword (`let`/`const`).
      local kw = gp:child(0)
      return (kw and kw:type() == 'const') and 14 or 13, p, 'inner'
    end
  elseif pt == 'formal_parameters' then
    -- El scope más interno es la función dueña de los parámetros.
    return 13, n, 'inner'
  elseif pt == 'arrow_function' and is_field(p, 'parameter', n) then
    -- `x => ...`: parámetro único sin paréntesis (no hay formal_parameters).
    return 13, n, 'inner'
  end
  return nil
end

---Llena los índices de `data` en un solo barrido de las capturas, en orden
---del documento, con la pila de scopes abiertos (se anidan sin cruzarse: el
---tope es el scope más interno que contiene la posición actual). Así ni la
---construcción ni la resolución llaman a TSNode:parent() por ocurrencia,
---que en tree-sitter baja desde la raíz recorriendo hermanos: con miles de
---funciones en un <script>, references se volvía cuadrático.
---
---Cada scope recibe una clave entera, su posición en el orden del
---documento; 0 es el global, compartido por todos los <script> de la
---página. Las declaraciones se indexan por (clave, nombre); en cada clave
---gana la primera del documento (un `var x` redeclarado es la misma
---variable).
---@param data table
---@param scopes table[] {node, sb, eb} de las capturas @scope
---@param items table[] {node, sb, method} de @id/@method, en orden
local function index(data, scopes, items)
  table.sort(scopes, function(a, b)
    if a.sb ~= b.sb then return a.sb < b.sb end
    return a.eb > b.eb
  end)
  local stack, next_scope = {}, 1
  local function close_before(byte)
    while stack[#stack] and stack[#stack].eb <= byte do
      stack[#stack] = nil
    end
  end

  for _, it in ipairs(items) do
    -- `<=`: un scope que empieza en el mismo byte que el identificador lo
    -- contiene (el parámetro de `x => x`).
    while scopes[next_scope] and scopes[next_scope].sb <= it.sb do
      local s = scopes[next_scope]
      close_before(s.sb)
      s.key = next_scope
      s.parent = stack[#stack]
      data.parent[s.key] = s.parent and s.parent.key or 0
      stack[#stack + 1] = s
      next_scope = next_scope + 1
    end
    close_before(it.sb)
    local inner = stack[#stack]
    local name = vim.treesitter.get_node_text(it.node, data.source)

    if it.method then
      local def = it.node:parent()
      local body = def and def:parent()
      table.insert(data.decls, {
        name = name,
        kind = 6,
        node = it.node,
        decl = def,
        class = body and body:parent(),
        member = true,
      })
    else
      local occ = { name = name, node = it.node, scope = inner and inner.key or 0 }
      local kind, decl, where = classify(it.node)
      if kind then
        local s = inner
        if where == 'outer' and s and s.node:equal(decl) then s = s.parent end
        local key = s and s.key or 0
        local slots = where == 'name' and data.fnames or data.bindings
        slots[key] = slots[key] or {}
        local e = {
          name = name,
          kind = kind,
          node = it.node,
          decl = decl,
          scope = s and s.node,
          global = key == 0,
          slot = slots[key],
        }
        e.slot[name] = e.slot[name] or e
        table.insert(data.decls, e)
        occ.decl = e
      end
      data.occurrences[name] = data.occurrences[name] or {}
      table.insert(data.occurrences[name], occ)
      data.at[it.sb] = occ
    end
  end
end

local function new_data()
  return {
    trees = {},
    decls = {},       -- declaraciones, en orden del documento
    occurrences = {}, -- nombre → ocurrencias (usos y declaraciones)
    at = {},          -- byte de inicio → ocurrencia (para el cursor)
    bindings = {},    -- clave de scope → nombre → declaración
    fnames = {},      -- ídem, sólo los nombres de function expression
    parent = {},      -- clave de scope → clave del que lo envuelve
    srcs = {},        -- `src` de los <script>, sin resolver (externals)
  }
end

---Sin parser javascript la capa queda inerte; :checkhealth asp lo avisa.
---Neovim 0.10 lanza si el parser falta y no devuelve nada si lo carga;
---0.11+ no lanza y devuelve true o nil + mensaje.
---@return boolean
local function has_js_parser()
  local ok, added = pcall(vim.treesitter.language.add, 'javascript')
  return ok and not (added == nil and vim.fn.has('nvim-0.11') == 1)
end

---Parsea `source` con un parser javascript propio y llena los índices de
---`data`.
---@param data table de new_data
---@param source string texto de js_source (o un .js entero)
---@param regions Range6[][]|nil nil: todo el texto (un .js)
---@param blocks table[] de asp_blocks ({} en un .js)
local function index_js(data, source, regions, blocks)
  data.source = source
  -- Parser STRING sobre el texto con los bloques ASP neutralizados (ver
  -- js_source), confinado a los <script>. Injection query vacía: el JS
  -- puede traer regex/jsdoc/... inyectados (queries de nvim-treesitter)
  -- que esta capa no usa y sólo costarían parseo. parse(true) porque
  -- parse() a secas no parsea regiones no vacías (ver
  -- asp.symbols.collect_file).
  local lt = vim.treesitter.get_string_parser(source, 'javascript', {
    injections = { javascript = '' },
  })
  if regions then lt:set_included_regions(regions) end
  lt:parse(true)
  -- Referencia al LanguageTree: mantiene vivos los árboles cuyos nodos se
  -- guardan en el caché.
  data.ltree = lt

  for _, tree in pairs(lt:trees()) do
    table.insert(data.trees, tree)
  end
  table.sort(data.trees, function(a, b)
    return start_byte_of(a:root()) < start_byte_of(b:root())
  end)

  local q = vim.treesitter.query.parse('javascript', JS_QUERY)
  local scopes, items = {}, {}
  for _, tree in ipairs(data.trees) do
    for id, node in q:iter_captures(tree:root(), source) do
      local _, _, sb = node:start()
      local _, _, eb = node:end_()
      if q.captures[id] == 'scope' then
        table.insert(scopes, { node = node, sb = sb, eb = eb })
      elseif not overlaps_asp(blocks, sb, eb) then
        table.insert(items, { node = node, sb = sb, method = q.captures[id] == 'method' })
      end
    end
  end
  index(data, scopes, items)
end

---@param bufnr integer
---@return table|nil data
local function build(bufnr)
  if not has_js_parser() then return nil end

  local parser = vim.treesitter.get_parser(bufnr)
  -- parse(true): la capa html es una inyección y sólo existe con las
  -- injections resueltas (igual que en asp.symbols.identifier_at).
  local root = parser:parse(true)[1]:root()
  local html = parser:children().html

  local data = new_data()
  if not html then return data end
  local blocks = asp_blocks(root)
  local regions
  regions, data.srcs = script_regions(html, bufnr, blocks)
  if #regions == 0 then return data end

  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  index_js(data, js_source(text, blocks), regions, blocks)
  return data
end

local function lsp_range(node)
  local r0, c0, r1, c1 = node:range()
  return {
    start = { line = r0, character = c0 },
    ['end'] = { line = r1, character = c1 },
  }
end

---Los datos de un archivo de disco se guardan sin nodos ni árboles, como
---los de asp.symbols.collect_file: cada ocurrencia y declaración conserva
---sólo su rango LSP, y el caché no retiene parsers por archivo.
---@param data table
---@return table data
local function detach(data)
  for _, list in pairs(data.occurrences) do
    for _, o in ipairs(list) do
      o.range, o.node = lsp_range(o.node), nil
    end
  end
  for _, e in ipairs(data.decls) do
    e.range = lsp_range(e.node)
    e.node, e.decl, e.scope, e.class = nil, nil, nil, nil
  end
  data.trees, data.ltree, data.source, data.at, data.decls = nil, nil, nil, nil, nil
  return data
end

---Datos JS de un archivo de disco, sin buffer. `kind`:
---
---  * 'js': un `.js` de `<script src>`, JavaScript puro, parseado entero.
---  * 'page': una página incluida (.asp/.inc/...), que es una plantilla:
---    se parsea la capa aspclassic, de ahí sólo la capa html confinada a
---    los `content` (sin vbscript ni las inyecciones js/css de html), y
---    el javascript confinado a sus <script>, con el mismo relleno de
---    bloques ASP que el buffer (js_source).
---@param content string
---@param kind 'js'|'page'
---@return table data
local function build_file(content, kind)
  local data = new_data()
  if kind == 'js' then
    index_js(data, content, nil, {})
    return detach(data)
  end
  -- Sin <script> no hay nada que extraer: los includes de puro VBScript
  -- (los más) no se parsean.
  if not content:lower():find('<script', 1, true) then return data end

  local tpl = vim.treesitter.get_string_parser(content, 'aspclassic')
  local troot = tpl:parse()[1]:root()
  local cq = vim.treesitter.query.parse('aspclassic', CONTENT_QUERY)
  local content_nodes = {}
  for _, node in cq:iter_captures(troot, content) do
    table.insert(content_nodes, node)
  end
  if #content_nodes == 0 then return data end

  -- Una sola región combinada, como la inyección html de
  -- queries/aspclassic/injections.scm.
  local hp = vim.treesitter.get_string_parser(content, 'html', {
    injections = { html = '' },
  })
  hp:set_included_regions({ content_nodes })
  hp:parse(true)
  local blocks = asp_blocks(troot)
  local regions
  regions, data.srcs = script_regions(hp, content, blocks)
  if #regions == 0 then return data end

  index_js(data, js_source(content, blocks), regions, blocks)
  return detach(data)
end

local file_cache = {}

---Clave de caché de un archivo: mtime y tamaño (el tamaño cubre los
---sistemas de archivos con mtime de un segundo).
local function stamp_of(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. ':' .. st.mtime.nsec .. ':' .. st.size) or nil
end

---Datos de `path` cacheados por mtime, o nil si no se puede leer o
---parsear.
---@param path string ruta absoluta normalizada
---@param kind 'js'|'page' ver build_file
---@return table|nil
local function file_data(path, kind)
  local stamp = stamp_of(path)
  if not stamp then return nil end
  local hit = file_cache[path]
  if not hit or hit.stamp ~= stamp then
    hit = { stamp = stamp }
    file_cache[path] = hit
  end
  if hit[kind] == nil then
    local ok, data = pcall(function()
      local f = assert(io.open(path, 'rb'))
      local content = f:read('*a')
      f:close()
      -- Neovim no muestra el BOM en el buffer: sin quitarlo, las columnas
      -- de la primera línea quedarían corridas tres bytes.
      return build_file((content:gsub('^\239\187\191', '')), kind)
    end)
    hit[kind] = ok and data or false
  end
  return hit[kind] or nil
end

---Olvida los datos cacheados de un archivo de disco (BufWritePost). El
---caché ya se valida por mtime en cada consulta; esto sólo lo adelanta.
---@param abs_path string
function M.invalidate(abs_path)
  file_cache[vim.fs.normalize(abs_path)] = nil
end

local cache = {}

---Datos de la capa para el estado actual del buffer, cacheados por
---changedtick. nil si no hay parser javascript.
---@param bufnr integer
---@return table|nil
local function get_data(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local hit = cache[bufnr]
  if hit and hit.tick == tick then return hit.data end
  -- Purga perezosa de buffers borrados (los bufnr no se reutilizan): evita
  -- registrar autocmds desde un handler, que puede correr bajo textlock
  -- (tagfunc).
  for b in pairs(cache) do
    if not vim.api.nvim_buf_is_valid(b) then cache[b] = nil end
  end
  local data = build(bufnr)
  -- La falta de parser no se cachea: la capa se activa en cuanto el
  -- usuario lo instala, sin tener que editar el buffer.
  cache[bufnr] = data and { tick = tick, data = data } or nil
  return data
end

---Ocurrencia JS bajo `position`, buscada sólo en el árbol javascript
---propio que contiene la posición. Un property_identifier (`obj.prop`,
---`this.x`), un identificador que se cruza con un bloque ASP (el relleno
---de un `<%= %>` o `foo<%= x %>`) u otro nodo devuelve nil.
---@param data table
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return table|nil occurrence {name, node, scope, decl?}
local function occurrence_at(data, position)
  for _, tree in ipairs(data.trees) do
    local root = tree:root()
    if range_contains(root, position.line, position.character) then
      local node = root:named_descendant_for_range(
        position.line, position.character, position.line, position.character
      )
      if node and IDENTIFIERS[node:type()] then
        -- Sin entrada si se cruza con un bloque ASP (ver build).
        return data.at[start_byte_of(node)]
      end
      return nil
    end
  end
  return nil
end

---Declaración a la que resuelve `occ`: se suben sus scopes, del más
---interno al global (compartido por todos los <script> de la página),
---buscando el nombre en las declaraciones de cada uno y, si el scope es
---una function expression con nombre, en ese nombre después.
---
---Si `occ` es él mismo el nombre de una declaración, resuelve a la primera
---de su mismo binding: así un `var x` redeclarado resuelve al primero
---(misma variable en JS) y el nombre de una function expression a la
---propia función, aunque un parámetro homónimo la sombree adentro.
---@param data table
---@param occ table de data.occurrences
---@return table|nil entry
local function resolve(data, occ)
  if occ.decl then return occ.decl.slot[occ.name] end
  local key = occ.scope
  while key do
    local b, f = data.bindings[key], data.fnames[key]
    local hit = (b and b[occ.name]) or (f and f[occ.name])
    if hit then return hit end
    key = data.parent[key]
  end
  return nil
end

---@param uri string
---@param item table ocurrencia o declaración (con node, o range si es de disco)
local function location(uri, item)
  return { uri = uri, range = item.range or lsp_range(item.node) }
end

local function global_binding(data, name)
  local g = data.bindings[0]
  return g and g[name]
end

---Archivos externos cuyo JS global ve la página, en orden de prioridad de
---resolución: los `.js` de los `<script src>` del buffer, en orden del
---documento, y después cada include de includes.buffer_graph (su JS
---inline y luego sus `<script src>`, resueltos relativos al include). Un
---`src` externo (`http://`, CDN), inexistente o que no es `.js` se ignora.
---
---Cada archivo se carga recién al visitarlo: `visit` devuelve un valor no
---nil para cortar el recorrido (primer match de definition) y
---each_external lo devuelve.
---@param bufnr integer
---@param data table del buffer
---@param visit fun(uri: string, ext: table): any
---@return any
local function each_external(bufnr, data, visit)
  local pages = require('asp.pages')
  local seen = {}
  local function from_src(src, from)
    local path = pages.resolve(src, from)
    if not path or not path:lower():match('%.js$') or seen[path] then return nil end
    seen[path] = true
    local ext = file_data(path, 'js')
    if ext then return visit(vim.uri_from_fname(path), ext) end
    return nil
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  for _, src in ipairs(data.srcs) do
    local hit = from_src(src, name)
    if hit ~= nil then return hit end
  end
  for _, path in ipairs(require('asp.includes').buffer_graph(bufnr).order) do
    local ext = file_data(path, 'page')
    if ext then
      local hit = visit(vim.uri_from_fname(path), ext)
      if hit ~= nil then return hit end
      for _, src in ipairs(ext.srcs) do
        hit = from_src(src, path)
        if hit ~= nil then return hit end
      end
    end
  end
  return nil
end

local function definition(bufnr, position)
  local data = get_data(bufnr)
  if not data then return nil end
  local occ = occurrence_at(data, position)
  if not occ then return nil end
  local best = resolve(data, occ)
  if best then return location(vim.uri_from_bufnr(bufnr), best) end
  -- Sin binding en el buffer (tampoco en su global): el global de los
  -- archivos externos, primer match gana. Sus locales no existen para la
  -- página.
  return each_external(bufnr, data, function(uri, ext)
    local e = global_binding(ext, occ.name)
    if e then return location(uri, e) end
    return nil
  end)
end

local function references(bufnr, position)
  local data = get_data(bufnr)
  if not data then return nil end
  local occ = occurrence_at(data, position)
  if not occ then return nil end
  local name = occ.name

  local out = {}
  -- Cada archivo resuelve con su propio índice: sus locales sombrean.
  local function collect(uri, d, keep)
    for _, o in ipairs(d.occurrences[name] or {}) do
      if keep(resolve(d, o)) then table.insert(out, location(uri, o)) end
    end
  end

  -- Un local del buffer no puede aparecer en otro archivo: los externos
  -- sólo se cargan si el binding es global o no está en el buffer.
  local binding = resolve(data, occ)
  if binding and not binding.global then
    collect(vim.uri_from_bufnr(bufnr), data, function(r) return r == binding end)
    return out
  end

  -- En el navegador el scope global de la página es uno solo: los globales
  -- homónimos del buffer y de sus externos son la misma variable, y un uso
  -- que no resuelve en su archivo cae a ella. definition elige una de esas
  -- declaraciones por prioridad; references las reúne todas.
  local files = { { uri = vim.uri_from_bufnr(bufnr), data = data } }
  local declared = binding ~= nil
  each_external(bufnr, data, function(uri, ext)
    table.insert(files, { uri = uri, data = ext })
    declared = declared or global_binding(ext, name) ~= nil
  end)
  -- Sin declaración en la página ni en sus archivos externos (`document`,
  -- `alert`, un global implícito): nil, como definition.
  if not declared then return nil end
  for _, f in ipairs(files) do
    collect(f.uri, f.data, function(r) return r == nil or r.global end)
  end
  return out
end

local function document_symbols(bufnr)
  local data = get_data(bufnr)
  if not data then return nil end

  -- Sólo funciones y clases globales, como el outline de VBScript deja
  -- fuera los locales; los métodos van anidados en su clase.
  local out, classes = {}, {}
  for _, e in ipairs(data.decls) do
    local global_fn = e.kind == 12 and FUNCTION_DECLARATIONS[e.decl:type()]
    if not e.member and not e.scope and (global_fn or e.kind == 5) then
      local sym = {
        name = e.name,
        kind = e.kind,
        detail = 'javascript',
        range = lsp_range(e.decl),
        selectionRange = lsp_range(e.node),
        children = {},
      }
      table.insert(out, sym)
      if e.kind == 5 then
        table.insert(classes, { decl = e.decl, sym = sym })
      end
    end
  end
  for _, e in ipairs(data.decls) do
    if e.member and e.class then
      for _, c in ipairs(classes) do
        if c.decl:equal(e.class) then
          table.insert(c.sym.children, {
            name = e.name,
            kind = e.kind,
            detail = 'javascript',
            range = lsp_range(e.decl),
            selectionRange = lsp_range(e.node),
            children = {},
          })
          break
        end
      end
    end
  end
  return out
end

-- Toda función pública devuelve nil ante cualquier error (pcall): los
-- handlers de asp.lsp encadenan capas con `or` y jamás deben lanzar.
local function safe(fn, bufnr, ...)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local ok, res = pcall(fn, bufnr, ...)
  if ok then return res end
  return nil
end

---Declaraciones JS del buffer, en orden del documento: {name, kind, node,
---decl, scope} (scope nil = global; los métodos llevan member = true).
---@param bufnr integer
---@return table[]|nil
function M.collect(bufnr)
  return safe(function(b)
    local data = get_data(b)
    return data and data.decls
  end, bufnr)
end

---Definición del identificador JS bajo `position` (case-sensitive): en el
---buffer, o si su global no lo declara, en el global de los archivos
---externos (ver each_external).
---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return table|nil Location
function M.definition(bufnr, position)
  return safe(definition, bufnr, position)
end

---Ocurrencias del buffer y de sus archivos externos que resuelven a la
---misma declaración que el identificador JS bajo `position`, incluida la
---declaración. Un global es uno solo para toda la página: reúne las
---declaraciones homónimas de todos esos archivos y sus usos.
---@param bufnr integer
---@param position table {line, character}
---@return table[]|nil Location[]
function M.references(bufnr, position)
  return safe(references, bufnr, position)
end

---Funciones y clases JS globales (con sus métodos) para el outline, con
---detail = 'javascript'.
---@param bufnr integer
---@return table[]|nil DocumentSymbol[]
function M.document_symbols(bufnr)
  return safe(document_symbols, bufnr)
end

return M
