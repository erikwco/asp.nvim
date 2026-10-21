-- Capa JavaScript de cliente de asp-ls: definición y referencias de los
-- identificadores de los bloques <script> del buffer, de sus manejadores
-- de evento inline (`onclick="..."`) y de sus URLs `javascript:` (ver
-- handler_regions), con el mismo contrato que asp.symbols (Location /
-- lista de Location / nil). El scope global de la página se extiende con
-- las declaraciones globales de los `.js` de sus `<script src>` y del JS
-- de las páginas incluidas (ver each_external).
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
-- Todo atributo con valor, con o sin comillas, de cualquier elemento. Los
-- de manejador se eligen por nombre en Lua (ver handler_regions): #match?
-- sobre el nombre no se comporta igual en todas las versiones soportadas.
local ATTRIBUTE_QUERY = [[
(attribute (attribute_name) @name (attribute_value) @value)
(attribute (attribute_name) @name (quoted_attribute_value (attribute_value) @value))
(attribute (attribute_name) @empty_name (quoted_attribute_value) @empty_value)
]]
local CONTENT_QUERY = [[ (content) @content ]]
--  * @scope: los nodos que abren un scope. let/const se tratan como var
--    (function-scoped, no block-scoped): límite documentado.
--  * @id: los identificadores resolubles. shorthand_property_identifier es
--    la `x` de `{ x }`: una lectura de la variable `x`, no una propiedad;
--    shorthand_property_identifier_pattern, la de un patrón (`{ x } = o`,
--    `function f({ x })`): el binding `x`.
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
(shorthand_property_identifier_pattern) @id
(method_definition name: (property_identifier) @method)
]]

-- Lo que js_context.mask no recorre como código: ver opaque_of.
local OPAQUE_QUERY = [[ [(string) (template_string) (regex) (comment)] @opaque ]]

-- Tipos de nodo de @id: los únicos que se resuelven bajo el cursor.
local IDENTIFIERS = {
  identifier = true,
  shorthand_property_identifier = true,
  shorthand_property_identifier_pattern = true,
}

-- Abreviados: la clave del objeto es el propio nombre (ver references).
local SHORTHANDS = {
  shorthand_property_identifier = true,
  shorthand_property_identifier_pattern = true,
}

-- Patrones que envuelven un nombre declarado: `a = 1`, `...a`, `[a]`,
-- `{a}`, `{k: a}`, `{a = 1}`, anidados. El valor es el campo por el que
-- se baja al nombre (false: cualquier hijo); por el otro lado de un
-- default (`a = b`) o por la clave de un par (`{k: a}`) no se declara.
local PATTERNS = {
  assignment_pattern = 'left',
  object_assignment_pattern = 'left',
  pair_pattern = 'value',
  rest_pattern = false,
  array_pattern = false,
  object_pattern = false,
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

---Intervalos de bytes `{inicio, fin, output, range}` (fin exclusivo) de los
---bloques ASP de la plantilla, en orden del documento: todo hijo de la raíz
---que no es `content`; `output` marca los `<%= %>` y `range` es el Range6
---del bloque. La capa html sólo ve los `content`, así que un nodo html que
---se cruza con alguno se armó con ASP (ver script_attrs), y en el
---javascript un identificador que se cruza con alguno es VBScript (ver
---js_source y overlaps_asp).
---@param root TSNode raíz de la plantilla aspclassic
---@return table[] blocks
local function asp_blocks(root)
  local blocks = {}
  for i = 0, root:named_child_count() - 1 do
    local child = root:named_child(i)
    if child:type() ~= 'content' then
      local range = { child:range(true) }
      table.insert(blocks, { range[3], range[6], output = child:type() == 'output_directive', range = range })
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
      local body, closing
      for child in f.script:iter_children() do
        if child:type() == 'raw_text' then
          table.insert(regions, { { child:range(true) } })
          body = true
        elseif child:type() == 'end_tag' then
          closing = child
        end
      end
      if not body and closing then
        local sr, sc, sb = f.tag:end_()
        local er, ec, eb = closing:start()
        table.insert(regions, { { sr, sc, sb, er, ec, eb } })
      end
      if attrs.src and attrs.src ~= '' and not dynamic.src then
        table.insert(srcs, attrs.src)
      end
    end
  end
  return regions, srcs
end

---Regiones del JS de los atributos: el valor de todo atributo `on*` de
---cualquier elemento (`onclick`, `ONCHANGE`, ...) y el de un `href` con
---URL `javascript:`, desde después del prefijo. Cada uno es su propia
---región, como cada <script>, pero no corren igual en el navegador: un
---manejador `on*` es el cuerpo de una función aparte, con su propio scope
---(ver index_js); una URL `javascript:` es un script global, y sus `var` y
---funciones son de la página: su región lleva `url`.
---
---El rango del `attribute_value` se ensancha sobre los bloques ASP pegados
---a sus bordes: el parser html no los ve, así que en
---`onkeyup="<%= p %>g()"` el valor interior empieza en `g`. Ensanchado,
---`g` queda pegado al relleno del bloque y se descarta como en un <script>
---(ver js_source). Un valor que es entero un bloque ASP no tiene
---`attribute_value` y no da región; un `href` con un bloque delante
---(`<%= url %>javascript:...`) tampoco: su prefijo no es estático.
---
---No se decodifican las entidades HTML del valor (`&quot;`) ni los `%xx`
---de una URL `javascript:`: el JS queda con un error de sintaxis donde
---aparecen y el resto resuelve igual.
---@param html vim.treesitter.LanguageTree capa html, ya parseada
---@param source integer|string bufnr o texto del archivo
---@param blocks table[] de asp_blocks
---@return table[] handlers {range: Range6, url?: true} en orden del documento
local function handler_regions(html, source, blocks)
  local starts, ends = {}, {}
  for _, b in ipairs(blocks) do
    starts[b[1]], ends[b[2]] = b.range, b.range
  end
  local aq = vim.treesitter.query.parse('html', ATTRIBUTE_QUERY)
  local handlers = {}
  for _, tree in pairs(html:trees()) do
    for _, match in aq:iter_matches(tree:root(), source) do
      local name, value, empty_name, empty_value
      for id, nodes in pairs(match) do
        if type(nodes) ~= 'table' then nodes = { nodes } end
        if aq.captures[id] == 'name' then name = nodes[1] end
        if aq.captures[id] == 'value' then value = nodes[1] end
        if aq.captures[id] == 'empty_name' then empty_name = nodes[1] end
        if aq.captures[id] == 'empty_value' then empty_value = nodes[1] end
      end
      local empty = empty_value and empty_value:named_child_count() == 0
      if empty then name, value = empty_name, empty_value end
      local attr = name and value and vim.treesitter.get_node_text(name, source):lower()
      local skip -- bytes del valor antes del JS: el prefijo `javascript:`
      if attr and attr:match('^on%a+$') then
        skip = 0
      elseif attr == 'href' and not ends[start_byte_of(value)] then
        local lead = vim.treesitter.get_node_text(value, source):lower():match('^[ \t]*javascript:')
        skip = lead and #lead
      end
      if skip then
        local r = { value:range(true) }
        if empty then
          r[2], r[3], r[5], r[6] = r[2] + 1, r[3] + 1, r[5] - 1, r[6] - 1
        end
        r[2], r[3] = r[2] + skip, r[3] + skip
        while ends[r[3]] do
          local b = ends[r[3]]
          r[1], r[2], r[3] = b[1], b[2], b[3]
        end
        while starts[r[6]] do
          local b = starts[r[6]]
          r[4], r[5], r[6] = b[4], b[5], b[6]
        end
        if r[3] <= r[6] then
          table.insert(handlers, { range = r, url = attr == 'href' or nil })
        end
      end
    end
  end
  table.sort(handlers, function(a, b) return a.range[3] < b.range[3] end)
  return handlers
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
---  * 'inner': en ese mismo scope (variables, clases).
---  * 'parameter': en ese scope, visible también en los defaults.
---
---nil si el identificador es un uso.
---
---Un nombre dentro de patrones (ver PATTERNS) se clasifica por el nodo
---que los contiene: los de un parámetro (`function f(a = 1, ...b, {c})`)
---son parámetros y los de un declarador (`var [a, b] = xs`), variables.
---@param n TSNode
---@return integer|nil kind, TSNode|nil decl, string|nil where
local function classify(n)
  local p = n:parent()
  -- `top`: el patrón más externo que envuelve a `n`, o `n`. Envuelto, `n`
  -- no es hijo de `p` y solo pueden coincidir las dos ramas que miran a
  -- `top` o no miran campos: formal_parameters y variable_declarator.
  local top = n
  while p and PATTERNS[p:type()] ~= nil do
    local field = PATTERNS[p:type()]
    if field and not is_field(p, field, top) then return nil end
    top, p = p, p:parent()
  end
  if not p then return nil end
  local pt = p:type()
  if FUNCTION_DECLARATIONS[pt] and is_field(p, 'name', n) then
    return 12, p, 'outer'
  elseif FUNCTION_EXPRESSIONS[pt] and is_field(p, 'name', n) then
    return 12, p, 'name'
  elseif pt == 'class_declaration' and is_field(p, 'name', n) then
    return 5, p, 'inner'
  elseif pt == 'variable_declarator' and is_field(p, 'name', top) then
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
    return 13, n, 'parameter'
  elseif pt == 'arrow_function' and is_field(p, 'parameter', n) then
    -- `x => ...`: parámetro único sin paréntesis (no hay formal_parameters).
    return 13, n, 'parameter'
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
---documento; 0 es el global, compartido por todos los <script>,
---manejadores y URLs `javascript:` de la página. Las declaraciones se
---indexan por (clave, nombre); en cada clave gana la primera del documento
---(un `var x` redeclarado es la misma variable), salvo que sea de una URL
---`javascript:`: la de un <script> le gana aunque venga después, porque el
---<script> corre al cargar la página y la URL recién al hacer clic.
---@param data table
---@param scopes table[] {node, sb, eb, handler?} de las capturas @scope y
---  de los manejadores de evento
---@param items table[] {node, sb, method, url?} de @id/@method, en orden
local function index(data, scopes, items)
  table.sort(scopes, function(a, b)
    if a.sb ~= b.sb then return a.sb < b.sb end
    if a.eb ~= b.eb then return a.eb > b.eb end
    -- `onclick="x => x"`: la función ocupa el manejador entero y va adentro.
    return a.handler == true and not b.handler
  end)
  local stack, next_scope = {}, 1
  local function close_before(byte)
    while stack[#stack] and stack[#stack].eb <= byte do
      stack[#stack] = nil
    end
  end

  local function enter_until(byte)
    -- `<=`: un scope que empieza en el mismo byte que el identificador lo
    -- contiene (el parámetro de `x => x`).
    while scopes[next_scope] and scopes[next_scope].sb <= byte do
      local s = scopes[next_scope]
      close_before(s.sb)
      s.key = next_scope
      s.parent = stack[#stack]
      data.parent[s.key] = s.parent and s.parent.key or 0
      local params = s.node:field('parameters')[1]
      if params then
        local _, _, stop = params:end_()
        data.parameter_ends[s.key] = stop
      end
      stack[#stack + 1] = s
      next_scope = next_scope + 1
    end
  end

  for _, it in ipairs(items) do
    enter_until(it.sb)
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
      local occ = {
        name = name, node = it.node, byte = it.sb, scope = inner and inner.key or 0,
        shorthand = SHORTHANDS[it.node:type()],
      }
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
          parameter = where == 'parameter',
          url = it.url,
          slot = slots[key],
        }
        local first = e.slot[name]
        if not first or (first.url and not e.url) then e.slot[name] = e end
        table.insert(data.decls, e)
        occ.decl = e
      end
      data.occurrences[name] = data.occurrences[name] or {}
      table.insert(data.occurrences[name], occ)
      data.at[it.sb] = occ
    end
  end
  enter_until(math.huge)
  data.scopes = scopes
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
    parameter_ends = {}, -- clave de scope → byte final de sus parámetros
    scopes = {},     -- intervalos de scope, también para posiciones sin token
    regions = {},    -- rangos originales, incluidos sus espacios exteriores
    blocks = {},     -- ASP excluido del JS
    srcs = {},        -- `src` de los <script>, sin resolver (externals)
  }
end

---Sin parser javascript la capa queda inerte; :checkhealth asp lo avisa.
---@return boolean
local function has_js_parser()
  return require('asp.ts').add('javascript')
end

---Parsea `source` con un parser javascript propio y llena los índices de
---`data`.
---@param data table de new_data
---@param source string texto de js_source (o un .js entero)
---@param regions Range6[][]|nil nil: todo el texto (un .js)
---@param blocks table[] de asp_blocks ({} en un .js)
---@param handlers table[] de handler_regions, también en `regions`
local function index_js(data, source, regions, blocks, handlers)
  data.source = source
  data.regions, data.blocks = regions or {}, blocks
  -- Parser STRING sobre el texto con los bloques ASP neutralizados (ver
  -- js_source), confinado a los <script> y manejadores. Injection query
  -- vacía: el JS puede traer regex/jsdoc/... inyectados (queries de
  -- nvim-treesitter) que esta capa no usa y sólo costarían parseo.
  -- parse(true) porque parse() a secas no parsea regiones no vacías (ver
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
  -- Un manejador `on*` es el cuerpo de una función: sus `var` y sus
  -- funciones no son globales. Se abre como un scope más, sobre el rango de
  -- su región, con la raíz de su árbol como nodo. Una URL `javascript:` no
  -- abre ninguno: corre en el global; sólo se marcan sus capturas (ver
  -- index). La raíz de cada árbol empieza en el primer token de su región
  -- (o en su final, si no tiene ninguno), así que basta buscar la región
  -- que la contiene.
  local h, url = 1, {}
  for i, tree in ipairs(data.trees) do
    local rb = start_byte_of(tree:root())
    while handlers[h] and handlers[h].range[6] < rb do h = h + 1 end
    local r = handlers[h] and handlers[h].range
    if r and r[3] <= rb then
      if handlers[h].url then
        url[i] = true
      else
        table.insert(scopes, { node = tree:root(), sb = r[3], eb = r[6], handler = true })
      end
    end
  end
  for i, tree in ipairs(data.trees) do
    for id, node in q:iter_captures(tree:root(), source) do
      local _, _, sb = node:start()
      local _, _, eb = node:end_()
      if q.captures[id] == 'scope' then
        table.insert(scopes, { node = node, sb = sb, eb = eb })
      elseif not overlaps_asp(blocks, sb, eb) then
        table.insert(items, { node = node, sb = sb, method = q.captures[id] == 'method', url = url[i] })
      end
    end
  end
  index(data, scopes, items)
end

---Llena `data` con el JS de una página (el buffer o una incluida): sus
---<script> de JS de cliente, sus manejadores de evento y sus URLs
---`javascript:`, cada uno en su región, en orden del documento.
---@param data table de new_data
---@param html vim.treesitter.LanguageTree capa html, ya parseada
---@param source integer|string bufnr o texto del archivo
---@param blocks table[] de asp_blocks
local function index_page(data, html, source, blocks)
  local regions
  regions, data.srcs = script_regions(html, source, blocks)
  local handlers = handler_regions(html, source, blocks)
  if #regions + #handlers == 0 then return end
  -- Las regiones no se solapan: un valor de atributo está dentro de un tag
  -- y un raw_text en el cuerpo de un <script>, y el ensanche de un
  -- manejador sólo toma bloques ASP pegados a su valor. Ordenadas, sus
  -- árboles dan las capturas en orden del documento, como pide index.
  for _, r in ipairs(handlers) do table.insert(regions, { r.range }) end
  table.sort(regions, function(a, b) return a[1][3] < b[1][3] end)

  local text = type(source) == 'number'
    and table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n')
    or source
  index_js(data, js_source(text, blocks), regions, blocks, handlers)
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
  index_page(data, html, bufnr, asp_blocks(root))
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
    -- La ayuda sale del árbol: se extrae antes de soltarlo, sin otra
    -- lectura para mostrarla (ver help_entry).
    e.help = require('asp.js_info').declaration(e, data.source)
    e.node, e.decl, e.scope, e.class = nil, nil, nil, nil
  end
  data.trees, data.ltree, data.source, data.at, data.decls = nil, nil, nil, nil, nil
  data.scopes, data.regions, data.blocks = nil, nil, nil
  return data
end

---Datos JS de un archivo de disco, sin buffer. `kind`:
---
---  * 'js': un `.js` de `<script src>`, JavaScript puro, parseado entero.
---  * 'page': una página incluida (.asp/.inc/...), que es una plantilla:
---    se parsea la capa aspclassic, de ahí sólo la capa html confinada a
---    los `content` (sin vbscript ni las inyecciones js/css de html), y
---    el javascript confinado a sus <script> y sus manejadores de evento,
---    con el mismo relleno de bloques ASP que el buffer (js_source).
---@param content string
---@param kind 'js'|'page'
---@return table data
local function build_file(content, kind)
  local data = new_data()
  if kind == 'js' then
    index_js(data, content, nil, {}, {})
    return detach(data)
  end
  -- Sin <script>, manejadores de evento ni URLs `javascript:` no hay nada
  -- que extraer: los includes de puro VBScript (los más) no se parsean. Un
  -- falso positivo (`If online = 1` en VBScript) sólo cuesta el parseo.
  local lower = content:lower()
  if not (lower:find('<script', 1, true) or lower:find('javascript:', 1, true)
      or lower:find('[%s"\'/]on%a+%s*=')) then
    return data
  end

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
  index_page(data, hp, content, asp_blocks(troot))
  return detach(data)
end

-- Tope de archivos de disco en file_cache; al pasarlo se expulsa el usado
-- hace más tiempo (LRU). Cada entrada guarda el rango de cada ocurrencia
-- JS del archivo (un .js de 250 funciones ocupa ~1,2 MiB de Lua), y sin
-- tope la caché crecía con cada archivo consultado en la sesión. 64 cubre
-- el conjunto de casi cualquier página (sus `<script src>` y su grafo de
-- includes); el de una página más grande no se expulsa (ver trim).
local FILE_CACHE_MAX = 64

-- ruta → {stamp, used, js?, page?}; `used` es el valor de `clock` en la
-- última consulta de la entrada.
local file_cache = {}
local clock = 0

---Clave de caché de un archivo: mtime y tamaño (el tamaño cubre los
---sistemas de archivos con mtime de un segundo).
local function stamp_of(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. ':' .. st.mtime.nsec .. ':' .. st.size) or nil
end

---Cierra un recorrido de each_external que empezó con `clock` en `start`:
---expulsa las entradas usadas hace más tiempo hasta volver a
---FILE_CACHE_MAX, pero nunca una que usó ese recorrido. El tope efectivo
---es el mayor entre FILE_CACHE_MAX y el conjunto del recorrido: con un
---tope fijo, una página más grande expulsaba cada archivo antes de volver
---a usarlo (cada consulta recorre el conjunto en el mismo orden) y todo se
---releía de disco. Se recorta al terminar y no al guardar cada entrada
---para que también vuelva al tope un recorrido que sólo encuentra
---entradas cacheadas, y para hacerlo en una sola pasada.
---@param start integer
local function trim(start)
  local count, old = 0, {}
  for p, e in pairs(file_cache) do
    count = count + 1
    if e.used < start then table.insert(old, p) end
  end
  if count <= FILE_CACHE_MAX then return end
  table.sort(old, function(a, b) return file_cache[a].used < file_cache[b].used end)
  for i = 1, math.min(count - FILE_CACHE_MAX, #old) do file_cache[old[i]] = nil end
end

---Quita de file_cache los archivos que ya no existen. El resolver de rutas
---descarta un archivo borrado antes de que llegue a file_data, así que su
---entrada no se revalida nunca: sin esto quedaría hasta que la expulse el
---LRU. Cuesta un fs_stat por entrada, en cada recorrido de each_external.
local function prune()
  for p in pairs(file_cache) do
    if not vim.uv.fs_stat(p) then file_cache[p] = nil end
  end
end

---Datos de `path` cacheados por mtime, o nil si no se puede leer o
---parsear.
---@param path string ruta absoluta normalizada
---@param kind 'js'|'page' ver build_file
---@return table|nil
local function file_data(path, kind)
  local stamp = stamp_of(path)
  if not stamp then
    -- Borrado o inaccesible: su entrada ya no sirve.
    file_cache[path] = nil
    return nil
  end
  clock = clock + 1
  local hit = file_cache[path]
  if hit and hit.stamp == stamp then
    hit.used = clock
  else
    hit = { stamp = stamp, used = clock }
    file_cache[path] = hit
  end
  if hit[kind] == nil then
    local ok, data = pcall(function()
      -- Las columnas del buffer que abriría Neovim: sin el BOM, que no
      -- muestra, y en UTF-8 aunque el archivo sea latin1 (asp.pages.read).
      -- Si no, una línea con acentos antes de un nombre lo corre de lugar.
      return build_file(assert(require('asp.pages').read(path)), kind)
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

-- Para los tests: el tope y las rutas de file_cache.
M._FILE_CACHE_MAX = FILE_CACHE_MAX
function M._cached_files()
  return vim.tbl_keys(file_cache)
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
---@return boolean|nil nombre de propiedad sin binding
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
      if node and node:type() == 'property_identifier' then return nil, true end
      return nil
    end
  end
  return nil
end

---Declaración a la que resuelve `occ`: se suben sus scopes, del más
---interno al global (compartido por todos los <script> y manejadores de
---la página), buscando el nombre en las declaraciones de cada uno y, si
---el scope es una function expression con nombre, en ese nombre después.
---
---Si `occ` es él mismo el nombre de una declaración, resuelve a la que
---gana en su mismo binding (ver index): así un `var x` redeclarado
---resuelve al primero (misma variable en JS) y el nombre de una function
---expression a la propia función, aunque un parámetro homónimo la sombree
---adentro.
---@param data table
---@param occ table de data.occurrences
---@return table|nil entry
local function resolve(data, occ)
  if occ.decl then return occ.decl.slot[occ.name] end
  local key = occ.scope
  while key do
    local b, f = data.bindings[key], data.fnames[key]
    local hit = b and b[occ.name]
    -- Un default, también dentro de una función anidada, no ve las
    -- declaraciones del cuerpo de la función que recibe ese parámetro.
    local stop = data.parameter_ends[key]
    if hit and not hit.parameter and stop and occ.byte < stop then hit = nil end
    hit = hit or (f and f[occ.name])
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

-- Recorrido de each_external, sin el mantenimiento de file_cache.
local function walk_externals(bufnr, data, visit)
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

---Archivos externos cuyo JS global ve la página, en orden de prioridad de
---resolución: los `.js` de los `<script src>` del buffer, en orden del
---documento, y después cada include de includes.buffer_graph (su JS
---inline y luego sus `<script src>`, resueltos relativos al include). Un
---`src` externo (`http://`, CDN), inexistente o que no es `.js` se ignora.
---
---Cada archivo se carga recién al visitarlo: `visit` devuelve un valor no
---nil para cortar el recorrido (primer match de definition) y
---each_external lo devuelve. Al terminar, también tras un corte, recorta
---file_cache (ver trim).
---@param bufnr integer
---@param data table del buffer
---@param visit fun(uri: string, ext: table): any
---@return any
local function each_external(bufnr, data, visit)
  prune()
  -- El inicio es local a cada recorrido: uno anidado no puede moverlo.
  -- Ninguna ruta de producción anida recorridos (haría falta que `visit`
  -- o pages.resolve volvieran a consultar); si pasara, el anidado
  -- recortaría al terminar con su propio inicio y podría expulsar
  -- archivos que el exterior ya visitó: el resultado no cambia, sólo se
  -- releerían en la consulta siguiente. Si un error corta el recorrido,
  -- no se recorta: lo hace la consulta siguiente.
  local start = clock + 1
  local hit = walk_externals(bufnr, data, visit)
  trim(start)
  return hit
end

---Strings, templates, regex y comentarios del buffer por byte de inicio,
---{stop, kind}, para js_context.mask. Se arman la primera vez que se
---enmascara en cada changedtick: definition, references y hover no los
---usan.
---@param data table del buffer, con sus árboles
---@return table<integer, table>
local function opaque_of(data)
  if data.opaque then return data.opaque end
  data.opaque = {}
  local q = vim.treesitter.query.parse('javascript', OPAQUE_QUERY)
  for _, tree in ipairs(data.trees) do
    for _, node in q:iter_captures(tree:root(), data.source) do
      local _, _, sb = node:start()
      local _, _, eb = node:end_()
      data.opaque[sb] = { stop = eb, kind = node:type() }
    end
  end
  return data.opaque
end

local function region_at(bufnr, position)
  -- Un bloque ASP es VBScript: se descarta con el árbol de la plantilla,
  -- sin construir el índice JS, porque completion y signatureHelp de
  -- VBScript preguntan en cada tecla. Mismo criterio que overlaps_asp
  -- (byte, byte + 1): cuenta el bloque que empieza en el cursor, no el que
  -- termina ahí.
  local root = vim.treesitter.get_parser(bufnr):parse()[1]:root()
  local at = root:named_descendant_for_range(position.line, position.character,
    position.line, position.character)
  if at and at:type() ~= 'content' and not at:equal(root) then return nil end
  local data = get_data(bufnr)
  if not data then return nil end
  local byte = vim.api.nvim_buf_get_offset(bufnr, position.line) + position.character
  if overlaps_asp(data.blocks, byte, byte + 1) then return nil end
  for _, ranges in ipairs(data.regions) do
    local r = ranges[1]
    if r[3] <= byte and byte <= r[6] then
      local node
      for _, tree in ipairs(data.trees) do
        if range_contains(tree:root(), position.line, position.character) then
          node = tree:root():named_descendant_for_range(
            position.line, position.character, position.line, position.character)
          break
        end
      end
      return {
        source = data.source, range = r, byte = byte, node = node,
        opaque = function() return opaque_of(data) end,
      }, data
    end
  end
end

local function scope_at(data, byte)
  local key = 0
  for _, scope in ipairs(data.scopes) do
    if scope.sb > byte then break end
    if byte < scope.eb or (scope.handler and byte == scope.eb) then key = scope.key end
  end
  return key
end

-- Ayuda de una declaración. Las del buffer la calculan al pedirla, con su
-- texto (`source`); las de disco ya la traen (ver detach).
local function help_entry(entry, uri, source)
  if not entry.help then entry.help = require('asp.js_info').declaration(entry, source) end
  if not uri then return entry.help end
  local info = vim.tbl_extend('force', {}, entry.help)
  info.file = vim.uri_to_fname(uri)
  return info
end

local function named(bufnr, position, name)
  local ctx, data = region_at(bufnr, position)
  if not ctx then return nil end
  local occ = name and { name = name, byte = ctx.byte, scope = scope_at(data, ctx.byte) }
    or occurrence_at(data, position)
  if not occ then
    -- Sólo el nombre en la declaración del método. Resolver `obj.metodo`
    -- requeriría inferir el tipo de obj, fuera del alcance de esta capa.
    for _, e in ipairs(data.decls) do
      if e.member and ctx.node and e.node:equal(ctx.node) then return help_entry(e, nil, data.source) end
    end
    return nil
  end
  local entry = resolve(data, occ)
  if entry then return help_entry(entry, nil, data.source) end
  return each_external(bufnr, data, function(uri, ext)
    local e = global_binding(ext, occ.name)
    if e then return help_entry(e, uri) end
  end)
end

local function visible(bufnr, position)
  local ctx, data = region_at(bufnr, position)
  if not ctx then return nil end
  local out, seen = {}, {}
  local function add(slots, uri, parameter_only)
    local names = vim.tbl_keys(slots or {})
    table.sort(names)
    for _, name in ipairs(names) do
      local e = slots[name]
      if not seen[name] and (not parameter_only or e.parameter) then
        seen[name] = true
        out[#out + 1] = help_entry(e, uri, data.source)
      end
    end
  end
  -- El scope es el del nombre que se escribe, no el del cursor: al final
  -- de una arrow sin llaves (`x => x|`) o de una función sin cerrar, el
  -- cursor queda en el byte donde termina ese scope.
  local byte = ctx.byte
  while byte > ctx.range[3] and data.source:sub(byte, byte):match('[%w_$\128-\255]') do
    byte = byte - 1
  end
  local key = scope_at(data, byte)
  while key do
    local stop = data.parameter_ends[key]
    add(data.bindings[key], nil, stop and byte < stop)
    add(data.fnames[key])
    key = data.parent[key]
  end
  each_external(bufnr, data, function(uri, ext) add(ext.bindings[0], uri) end)
  return out
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

local function references(bufnr, position, opts)
  opts = opts or {}
  local data = get_data(bufnr)
  if not data then return nil end
  local occ, property = occurrence_at(data, position)
  if property then return {} end
  if not occ then return nil end
  local name = occ.name

  local out = {}
  -- Cada archivo resuelve con su propio índice: sus locales sombrean.
  local function collect(uri, d, keep)
    for _, o in ipairs(d.occurrences[name] or {}) do
      if keep(resolve(d, o)) then
        local loc = location(uri, o)
        if opts.rename_to and o.shorthand then
          loc.newText = name .. ': ' .. opts.rename_to
        end
        table.insert(out, loc)
      end
    end
  end

  -- Un local del buffer no puede aparecer en otro archivo: los externos
  -- sólo se cargan si el binding es global o no está en el buffer.
  local binding = resolve(data, occ)
  if binding and not binding.global then
    collect(vim.uri_from_bufnr(bufnr), data, function(r) return r == binding end)
    return out, location(vim.uri_from_bufnr(bufnr), binding)
  end

  -- En el navegador el scope global de la página es uno solo: los globales
  -- homónimos del buffer y de sus externos son la misma variable, y un uso
  -- que no resuelve en su archivo cae a ella. definition elige una de esas
  -- declaraciones por prioridad; references las reúne todas.
  local files = { { uri = vim.uri_from_bufnr(bufnr), data = data } }
  local declared = binding ~= nil
  if not opts.buffer_only then
    each_external(bufnr, data, function(uri, ext)
      table.insert(files, { uri = uri, data = ext })
      declared = declared or global_binding(ext, name) ~= nil
    end)
  end
  -- Sin declaración en la página ni en sus archivos externos (`document`,
  -- `alert`, un global implícito): {} y no nil. El usuario pidió las
  -- referencias de un nombre JS; una lista vacía (truthy en Lua) corta la
  -- cadena de asp.lsp para que asp.pages no responda con los usos de la
  -- página como si fueran referencias de ese identificador.
  if not declared and not opts.buffer_only then return {} end
  for _, f in ipairs(files) do
    collect(f.uri, f.data, function(r) return r == nil or r.global end)
  end
  return out, binding and location(vim.uri_from_bufnr(bufnr), binding) or nil
end

-- Ver M.occurrences.
local function occurrences(bufnr, name)
  local data = get_data(bufnr)
  if not data then return nil end
  local out = {}
  local function add(uri, d)
    for _, o in ipairs(d.occurrences[name] or {}) do
      local loc = location(uri, o)
      loc.declared = o.decl ~= nil
      table.insert(out, loc)
    end
  end
  add(vim.uri_from_bufnr(bufnr), data)
  each_external(bufnr, data, add)
  return out
end

local function document_symbols(bufnr)
  local data = get_data(bufnr)
  if not data then return nil end

  -- Sólo funciones y clases globales, como el outline de VBScript deja
  -- fuera los locales; los métodos van anidados en su clase. Lo que
  -- declara una URL `javascript:` es global pero vive en un atributo, como
  -- lo de un manejador: tampoco entra.
  local out, classes = {}, {}
  for _, e in ipairs(data.decls) do
    local global_fn = e.kind == 12 and FUNCTION_DECLARATIONS[e.decl:type()]
    if not e.member and not e.scope and not e.url and (global_fn or e.kind == 5) then
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
  local ok, res, binding = pcall(fn, bufnr, ...)
  if ok then return res, binding end
  return nil
end

---Región JS original y texto neutralizado, sin los bloques ASP interiores.
---El final es inclusivo para completar justo antes del cierre HTML.
function M.region_at(bufnr, position)
  local ctx = safe(region_at, bufnr, position)
  return ctx
end

---Ayuda del binding bajo el cursor, o del nombre en su scope actual.
---La firma y los parámetros salen del mismo índice que definition.
function M.named(bufnr, position, name)
  return safe(named, bufnr, position, name)
end

---Bindings visibles, del scope más interno a la página y sus externos.
function M.visible(bufnr, position)
  return safe(visible, bufnr, position)
end

---Declaraciones JS del buffer, en orden del documento: {name, kind, node,
---decl, scope} (scope nil = global; los métodos llevan member = true y las
---de una URL `javascript:`, url = true).
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
---Con buffer_only no consulta externos: devuelve candidatos del buffer
---aunque falte una declaración. El llamador debe resolverla antes de usarlos.
---Con rename_to agrega newText a las propiedades abreviadas, también las
---de un patrón, para conservar su clave: `{nombre}` pasa a
---`{nombre: nuevo}`.
---@param bufnr integer
---@param position table {line, character}
---@param opts? table {buffer_only?: boolean, rename_to?: string}
---@return table[]|nil Location[]
---@return table|nil binding Location de la declaración en el buffer
function M.references(bufnr, position, opts)
  return safe(references, bufnr, position, opts)
end

---Dónde aparece `name` (case-sensitive) en el JS del buffer y de sus
---archivos externos, en el orden de each_external: cada declaración o uso
---de cualquier scope, sin las propiedades (`obj.name`). Sirve a asp.rename
---para no elegir un nombre que ya existe. Sale de los índices cacheados de
---cada archivo: solo lee un externo que todavía no se cargó.
---@param bufnr integer
---@param name string
---@return table[]|nil Location[] con `declared` (true si declara el nombre)
function M.occurrences(bufnr, name)
  return safe(occurrences, bufnr, name)
end

---Funciones y clases JS globales (con sus métodos) para el outline, con
---detail = 'javascript'.
---@param bufnr integer
---@return table[]|nil DocumentSymbol[]
function M.document_symbols(bufnr)
  return safe(document_symbols, bufnr)
end

return M
