-- Capa JavaScript de cliente de asp-ls: definición y referencias de los
-- identificadores de los bloques <script> del buffer, con el mismo contrato
-- que asp.symbols (Location / lista de Location / nil).
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

local SCRIPT_QUERY = [[ (script_element (start_tag) @tag (raw_text) @body) ]]
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

---¿El <script> de `tag` es JavaScript de cliente? Excluye el JScript de
---servidor (`runat="server"`), los type que no son JS (`text/template`,
---...) y, sin type, el `language` legacy que no lo es (`language="VBScript"`
---es VBScript de cliente de IE: HTML lo trata como type `text/vbscript`).
---@param tag TSNode start_tag
---@param bufnr integer
---@return boolean
local function is_client_js(tag, bufnr)
  local attrs = {}
  for child in tag:iter_children() do
    if child:type() == 'attribute' then
      local name, value
      for part in child:iter_children() do
        local t = part:type()
        if t == 'attribute_name' then
          name = vim.treesitter.get_node_text(part, bufnr):lower()
        elseif t == 'attribute_value' then
          value = vim.treesitter.get_node_text(part, bufnr)
        elseif t == 'quoted_attribute_value' then
          local inner = part:named_child(0)
          value = inner and vim.treesitter.get_node_text(inner, bufnr) or ''
        end
      end
      -- Atributo repetido: HTML se queda con el primero.
      if name and attrs[name] == nil then
        attrs[name] = vim.trim(value or ''):lower()
      end
    end
  end

  if attrs.runat == 'server' then return false end
  local mime = attrs.type
  if mime == nil and attrs.language and attrs.language ~= '' then
    mime = 'text/' .. attrs.language
  end
  if mime == nil then return true end
  mime = vim.trim(mime:match('^[^;]*'))
  return JS_TYPES[mime] == true or mime:match('^text/javascript1%.[0-5]$') ~= nil
end

---Regiones (una por <script> de JS de cliente) para el parser javascript:
---el rango del `raw_text` de cada bloque.
---
---Una región por <script> (no una sola combinada): un error de sintaxis en
---un bloque no altera el parseo de los siguientes, igual que en el
---navegador. El scope global compartido entre bloques se resuelve después,
---en resolve().
---@param html vim.treesitter.LanguageTree capa html, ya parseada
---@param bufnr integer
---@return Range6[][]
local function script_regions(html, bufnr)
  local regions = {}
  local sq = vim.treesitter.query.parse('html', SCRIPT_QUERY)
  for _, tree in pairs(html:trees()) do
    for _, match in sq:iter_matches(tree:root(), bufnr) do
      local tag, body
      for id, nodes in pairs(match) do
        -- Neovim 0.10 entrega un nodo por captura; 0.11+ una lista.
        if type(nodes) ~= 'table' then nodes = { nodes } end
        if sq.captures[id] == 'tag' then tag = nodes[1] end
        if sq.captures[id] == 'body' then body = nodes[1] end
      end
      if tag and body and is_client_js(tag, bufnr) then
        table.insert(regions, { { body:range(true) } })
      end
    end
  end
  return regions
end

---Texto del buffer tal como lo ve el parser javascript: cada bloque ASP de
---la plantilla (todo hijo que no es `content`) se reemplaza byte a byte,
---conservando los saltos de línea, por un relleno de la misma longitud, así
---las posiciones coinciden con las del buffer:
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
---Devuelve también los intervalos de bytes `{inicio, fin}` (fin exclusivo)
---de todos los bloques ASP, en orden del documento: un identificador que se
---cruza con alguno es VBScript, entero (el relleno de un `<%= %>`) o en
---parte (`foo<%= x %>` se parsea como el identificador `foo________`), y se
---descarta (ver overlaps_asp).
---@param bufnr integer
---@param root TSNode raíz de la plantilla aspclassic
---@return string source, integer[][] blocks
local function js_source(bufnr, root)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local parts, blocks, prev = {}, {}, 0
  for i = 0, root:named_child_count() - 1 do
    local child = root:named_child(i)
    if child:type() ~= 'content' then
      local _, _, sb, _, _, eb = child:range(true)
      local piece = text:sub(sb + 1, eb)
      local fill = child:type() == 'output_directive' and '_' or ' '
      table.insert(blocks, { sb, eb })
      table.insert(parts, text:sub(prev + 1, sb))
      table.insert(parts, (piece:gsub('[^\n]', fill)))
      prev = eb
    end
  end
  table.insert(parts, text:sub(prev + 1))
  return table.concat(parts), blocks
end

---¿El tramo de bytes [sb, eb) se cruza con algún bloque ASP? Los bloques
---están ordenados y no se solapan, así que basta mirar el último que
---empieza antes de `eb` (búsqueda binaria).
---@param blocks integer[][] de js_source
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

local function start_byte_of(node)
  local _, _, b = node:start()
  return b
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

---@param bufnr integer
---@return table|nil data
local function build(bufnr)
  -- Sin parser javascript la capa queda inerte; :checkhealth asp lo avisa.
  -- Neovim 0.10 lanza si el parser falta y no devuelve nada si lo carga;
  -- 0.11+ no lanza y devuelve true o nil + mensaje.
  local ok, added = pcall(vim.treesitter.language.add, 'javascript')
  if not ok or (added == nil and vim.fn.has('nvim-0.11') == 1) then return nil end

  local parser = vim.treesitter.get_parser(bufnr)
  -- parse(true): la capa html es una inyección y sólo existe con las
  -- injections resueltas (igual que en asp.symbols.identifier_at).
  local root = parser:parse(true)[1]:root()
  local html = parser:children().html

  local data = {
    trees = {},
    decls = {},       -- declaraciones, en orden del documento
    occurrences = {}, -- nombre → ocurrencias (usos y declaraciones)
    at = {},          -- byte de inicio → ocurrencia (para el cursor)
    bindings = {},    -- clave de scope → nombre → declaración
    fnames = {},      -- ídem, sólo los nombres de function expression
    parent = {},      -- clave de scope → clave del que lo envuelve
  }
  local regions = html and script_regions(html, bufnr) or {}
  if #regions == 0 then return data end

  local source, blocks = js_source(bufnr, root)
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
  lt:set_included_regions(regions)
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
  return data
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

local function lsp_range(node)
  local r0, c0, r1, c1 = node:range()
  return {
    start = { line = r0, character = c0 },
    ['end'] = { line = r1, character = c1 },
  }
end

local function location(bufnr, node)
  return { uri = vim.uri_from_bufnr(bufnr), range = lsp_range(node) }
end

local function definition(bufnr, position)
  local data = get_data(bufnr)
  if not data then return nil end
  local occ = occurrence_at(data, position)
  if not occ then return nil end
  local best = resolve(data, occ)
  if not best then return nil end
  return location(bufnr, best.node)
end

local function references(bufnr, position)
  local data = get_data(bufnr)
  if not data then return nil end
  local occ = occurrence_at(data, position)
  if not occ then return nil end
  -- Sin declaración en la página (`document`, `alert`, un global
  -- implícito) no hay binding: nil, como definition.
  local binding = resolve(data, occ)
  if not binding then return nil end

  local out = {}
  for _, o in ipairs(data.occurrences[occ.name]) do
    if resolve(data, o) == binding then
      table.insert(out, location(bufnr, o.node))
    end
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

---Definición del identificador JS bajo `position` (case-sensitive).
---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return table|nil Location
function M.definition(bufnr, position)
  return safe(definition, bufnr, position)
end

---Ocurrencias del buffer que resuelven a la misma declaración que el
---identificador JS bajo `position`, incluida la declaración.
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
