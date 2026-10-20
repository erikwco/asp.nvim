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

-- Nodos que abren un scope. let/const se tratan como var (function-scoped,
-- no block-scoped): límite documentado.
local SCOPE_TYPES = {
  function_declaration = true,
  generator_function_declaration = true,
  function_expression = true,
  generator_function = true,
  arrow_function = true,
  method_definition = true,
}

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
-- Los nombres de método son property_identifier: se capturan aparte sólo
-- para el outline (documentSymbol); no son resolubles como identificador
-- suelto (se usan como `obj.metodo`, resolución por objetos: fuera de
-- alcance).
local JS_QUERY = [[
(identifier) @id
(method_definition name: (property_identifier) @method)
]]

local function nearest_ancestor(node, types)
  local cur = node:parent()
  while cur do
    if types[cur:type()] then return cur end
    cur = cur:parent()
  end
  return nil
end

local function nearest_scope(node)
  return nearest_ancestor(node, SCOPE_TYPES)
end

-- nil es el scope global; dos nodos se comparan con :equal() porque los
-- scopes pueden venir de árboles distintos (un árbol por <script>) y
-- TSNode:id() sólo garantiza unicidad dentro de su propio árbol.
local function same_scope(a, b)
  if a == nil or b == nil then return a == b end
  return a:equal(b)
end

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
---Devuelve también el conjunto de bytes donde empieza cada tramo de relleno
---`_` (uno por línea): los identificadores que arrancan ahí son VBScript y
---se descartan.
---@param bufnr integer
---@param root TSNode raíz de la plantilla aspclassic
---@return string source, table<integer, true> placeholders
local function js_source(bufnr, root)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local parts, placeholders, prev = {}, {}, 0
  for i = 0, root:named_child_count() - 1 do
    local child = root:named_child(i)
    if child:type() ~= 'content' then
      local _, _, sb, _, _, eb = child:range(true)
      local piece = text:sub(sb + 1, eb)
      local fill = ' '
      if child:type() == 'output_directive' then
        fill = '_'
        local off = sb
        for seg in (piece .. '\n'):gmatch('([^\n]*)\n') do
          if #seg > 0 then placeholders[off] = true end
          off = off + #seg + 1
        end
      end
      table.insert(parts, text:sub(prev + 1, sb))
      table.insert(parts, (piece:gsub('[^\n]', fill)))
      prev = eb
    end
  end
  table.insert(parts, text:sub(prev + 1))
  return table.concat(parts), placeholders
end

---Clasifica un `identifier` como nombre de declaración. Devuelve
---kind, nodo de la declaración y scope (TSNode, o nil = global), o nil si
---el identificador es un uso.
---@param n TSNode
---@return integer|nil kind, TSNode|nil decl, TSNode|nil scope
local function classify(n)
  local p = n:parent()
  if not p then return nil end
  local pt = p:type()
  if FUNCTION_DECLARATIONS[pt] and is_field(p, 'name', n) then
    return 12, p, nearest_scope(p)
  elseif FUNCTION_EXPRESSIONS[pt] and is_field(p, 'name', n) then
    return 12, p, p
  elseif pt == 'class_declaration' and is_field(p, 'name', n) then
    return 5, p, nearest_scope(p)
  elseif pt == 'variable_declarator' and is_field(p, 'name', n) then
    local gp = p:parent()
    local gt = gp and gp:type()
    if gt == 'variable_declaration' then
      return 13, p, nearest_scope(p)
    elseif gt == 'lexical_declaration' then
      -- El primer hijo de lexical_declaration es la keyword (`let`/`const`).
      local kw = gp:child(0)
      return (kw and kw:type() == 'const') and 14 or 13, p, nearest_scope(p)
    end
  elseif pt == 'formal_parameters' then
    -- nearest_scope(n) es la función dueña de los parámetros.
    return 13, n, nearest_scope(n)
  elseif pt == 'arrow_function' and is_field(p, 'parameter', n) then
    -- `x => ...`: parámetro único sin paréntesis (no hay formal_parameters).
    return 13, n, p
  end
  return nil
end

local function start_byte_of(node)
  local _, _, b = node:start()
  return b
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

  local data = { trees = {}, decls = {}, by_name = {}, occurrences = {} }
  local regions = html and script_regions(html, bufnr) or {}
  if #regions == 0 then return data end

  local source, placeholders = js_source(bufnr, root)
  data.source = source
  data.placeholders = placeholders

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
  for _, tree in ipairs(data.trees) do
    for id, node in q:iter_captures(tree:root(), source) do
      local name = vim.treesitter.get_node_text(node, source)
      if placeholders[start_byte_of(node)] then
        -- relleno de un <%= %>: es VBScript, no un identificador JS
      elseif q.captures[id] == 'method' then
        local def = node:parent()
        local body = def and def:parent()
        table.insert(data.decls, {
          name = name,
          kind = 6,
          node = node,
          decl = def,
          class = body and body:parent(),
          member = true,
        })
      else
        local kind, decl, scope = classify(node)
        if kind then
          local e = { name = name, kind = kind, node = node, decl = decl, scope = scope }
          table.insert(data.decls, e)
          data.by_name[name] = data.by_name[name] or {}
          table.insert(data.by_name[name], e)
        end
        data.occurrences[name] = data.occurrences[name] or {}
        table.insert(data.occurrences[name], node)
      end
    end
  end
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
  cache[bufnr] = { tick = tick, data = data }
  return data
end

---`identifier` JS bajo `position`, buscado sólo en el árbol javascript
---propio que contiene la posición. Un property_identifier (`obj.prop`,
---`this.x`), el relleno de un `<%= %>` u otro nodo devuelve nil.
---@param data table
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return TSNode|nil
local function identifier_at(data, position)
  for _, tree in ipairs(data.trees) do
    local root = tree:root()
    if range_contains(root, position.line, position.character) then
      local node = root:named_descendant_for_range(
        position.line, position.character, position.line, position.character
      )
      if node and node:type() == 'identifier'
        and not data.placeholders[start_byte_of(node)] then
        return node
      end
      return nil
    end
  end
  return nil
end

---Declaración a la que resuelve `node`: se suben sus funciones envolventes,
---de la más interna a la más externa, buscando una declaración `name` cuyo
---scope sea esa función; al final, el scope global (compartido por todos
---los <script> de la página). Primer match gana (orden del documento).
---
---Si `node` es él mismo el nombre de una declaración, la búsqueda arranca
---en el scope de esa declaración: así un `var x` redeclarado resuelve al
---primero (misma variable en JS) y el nombre de una function expression a
---la propia función.
---@param data table
---@param node TSNode
---@param name string
---@return table|nil entry
local function resolve(data, node, name)
  local cands = data.by_name[name]
  if not cands then return nil end

  local scope
  local own
  for _, c in ipairs(cands) do
    if c.node:equal(node) then
      own = c
      break
    end
  end
  if own then
    scope = own.scope
  else
    scope = nearest_scope(node)
  end

  while true do
    for _, c in ipairs(cands) do
      if same_scope(c.scope, scope) then return c end
    end
    if not scope then return nil end
    scope = nearest_scope(scope)
  end
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
  local node = identifier_at(data, position)
  if not node then return nil end
  local best = resolve(data, node, vim.treesitter.get_node_text(node, data.source))
  if not best then return nil end
  return location(bufnr, best.node)
end

local function references(bufnr, position)
  local data = get_data(bufnr)
  if not data then return nil end
  local node = identifier_at(data, position)
  if not node then return nil end
  local name = vim.treesitter.get_node_text(node, data.source)
  local binding = resolve(data, node, name)

  -- Un identificador sin declaración en la página (`document`, `alert`, un
  -- global implícito) se trata como un único binding global: sus
  -- referencias son todas las ocurrencias homónimas que tampoco resuelven.
  local out = {}
  for _, n in ipairs(data.occurrences[name] or {}) do
    if resolve(data, n, name) == binding then
      table.insert(out, location(bufnr, n))
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
