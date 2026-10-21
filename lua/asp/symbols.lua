local M = {}

-- SymbolKind (LSP): Class=5, Property=7, Function=12, Variable=13, Constant=14
--
-- IMPORTANTE sobre el orden de los patrones: los patrones "nombre anclado"
-- (1, 2, 4 — sub/function/property) DEBEN preceder a sus contrapartes
-- "todos los identifier hijos" (7, 8, 9). El dedupe vía seen[name_node:id()]
-- hace que el PRIMER patrón que visita un name_node dado sea el que fija su
-- kind — si el patrón unanchored corriera primero, el nombre de la propia
-- declaración se clasificaría con kind Variable (13) en vez de Function/
-- Property. Por eso 7/8/9 quedan al final: para cuando corren, el nombre ya
-- fue registrado por su patrón anclado y el dedupe deja pasar solo los
-- parámetros.
local QUERY = [[
(sub_statement . (identifier) @name) @decl
(function_statement . (identifier) @name) @decl
(class_statement name: (identifier) @name) @decl
(property_statement . (identifier) @name) @decl
(dim_statement (identifier) @name) @decl
(const_statement (identifier) @name) @decl
(sub_statement (identifier) @name) @decl
(function_statement (identifier) @name) @decl
(property_statement (identifier) @name) @decl
]]
-- Patrones 1-6: nombres de declaraciones (anclados donde aplica).
-- Patrones 7-9: hijos identifier directos de sub/function/property —
-- capturan nombre Y parámetros (los _arg son reglas ocultas); el nombre se
-- descarta por dedupe (ya visto por 1-2-4) y quedan solo los parámetros,
-- kind Variable.
local PATTERN_KINDS = { 12, 12, 5, 7, 13, 14, 13, 13, 13 }

local SCOPE_TYPES = {
  sub_statement = true,
  function_statement = true,
  property_statement = true,
}

local function nearest_ancestor(node, types)
  local cur = node:parent()
  while cur do
    if types[cur:type()] then return cur end
    cur = cur:parent()
  end
  return nil
end

-- Primer hijo directo de tipo identifier: por gramática es el nombre de la
-- declaración (sub/function/property), a diferencia de los identificadores
-- posteriores que son parámetros.
local function first_identifier_child(node)
  for i = 0, node:child_count() - 1 do
    local c = node:child(i)
    if c and c:type() == 'identifier' then return c end
  end
  return nil
end

local function callable_info(node, source, declaration)
  local params, labels, modifiers = {}, {}, {}
  local name
  for child in node:iter_children() do
    if child:type() == 'block' then break end
    local text = vim.treesitter.get_node_text(child, source)
    local lower = text:lower()
    if child:type() == 'identifier' then
      if not name then
        name = text
      else
        local modifier = table.concat(modifiers, ' ')
        params[#params + 1] = {
          name = text, optional = modifier:lower():find('optional', 1, true) ~= nil,
          doc = modifier ~= '' and ('Parámetro ' .. modifier .. '.') or 'Parámetro del procedimiento.',
        }
        labels[#labels + 1] = modifier ~= '' and (modifier .. ' ' .. text) or text
        modifiers = {}
      end
    elseif lower == 'byval' or lower == 'byref' or lower == 'optional' or lower == 'paramarray' then
      modifiers[#modifiers + 1] = text
    end
  end
  local prefix = declaration:match('^(.-)%(')
  return (prefix or name) .. '(' .. table.concat(labels, ', ') .. ')', params
end

-- Recorrido de matches compartido entre fuente-buffer (M.collect) y
-- fuente-string (M.collect_file): `source` acepta bufnr|string — tanto
-- vim.treesitter.get_node_text() como query:iter_matches() aceptan ambas
-- formas indistintamente.
---@param roots TSNode[]
---@param source integer|string
---@return table[] entries
local function collect_from_roots(roots, source)
  local query = vim.treesitter.query.parse('vbscript', QUERY)
  local entries = {}
  local seen = {}
  local declarations = {}

  for _, root in ipairs(roots) do
    for pattern, match in query:iter_matches(root, source) do
      local name_nodes, decl_node
      for id, nodes in pairs(match) do
        if type(nodes) ~= 'table' then nodes = { nodes } end
        local cap = query.captures[id]
        if cap == 'name' then name_nodes = nodes end
        if cap == 'decl' then decl_node = nodes[#nodes] end
      end
      for _, name_node in ipairs(name_nodes or {}) do
        if not seen[name_node:id()] then
          seen[name_node:id()] = true
          local class_anc = nearest_ancestor(name_node, { class_statement = true })
          local scope_anc = nearest_ancestor(name_node, SCOPE_TYPES)
          -- Para patrones 1-2 (nombre de sub/function), nearest_ancestor
          -- devuelve el propio sub/function_statement (es su padre). Si el
          -- ancestro hallado ES la propia declaración Y name_node es
          -- justamente el identifier-nombre de esa declaración (su primer
          -- hijo identifier), no cuenta como scope contenedor: subir al
          -- siguiente ancestro real (o nil). Los parámetros (patrones 7-8)
          -- también tienen scope_anc == decl_node estructuralmente (son
          -- hijos directos del mismo sub/function), pero NO son el nombre,
          -- así que conservan el scope tal cual.
          if scope_anc and scope_anc:id() == decl_node:id() then
            local self_name = first_identifier_child(scope_anc)
            if not self_name or self_name:id() == name_node:id() then
              scope_anc = nearest_ancestor(scope_anc, SCOPE_TYPES)
            end
          end
          if class_anc and class_anc:id() == decl_node:id() then
            class_anc = nearest_ancestor(class_anc, { class_statement = true })
          end
          local r0, c0, r1, c1 = decl_node:range()
          local sr0, sc0, sr1, sc1 = name_node:range()
          local entry = {
            name = vim.treesitter.get_node_text(name_node, source),
            kind = PATTERN_KINDS[pattern],
            range = { r0, c0, r1, c1 },
            selection = { sr0, sc0, sr1, sc1 },
            decl_id = decl_node:id(),
            class_id = class_anc and class_anc:id() or nil,
            scope_id = scope_anc and scope_anc:id() or nil,
          }
          local decl_id = entry.decl_id
          declarations[decl_id] = declarations[decl_id]
            or vim.treesitter.get_node_text(decl_node, source):match('^[^\r\n]*')
          entry.declaration = declarations[decl_id]
          if pattern == 1 or pattern == 2 or pattern == 4 then
            entry.signature, entry.params = callable_info(decl_node, source, entry.declaration)
            entry.doc = 'Procedimiento definido por el usuario.'
          end
          table.insert(entries, entry)
        end
      end
    end
  end
  return entries
end

---Declaraciones de árboles VBScript ya parseados (ver collect_from_roots).
---Los diagnósticos (asp.diagnostics) la usan con su propio árbol VBScript
---del buffer: comparten así los scope_id/class_id con su recorrido.
M.collect_roots = collect_from_roots

---@param bufnr integer
---@return table[] entries
function M.collect(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return {} end
  parser:parse(true)
  local child = parser:children().vbscript
  if not child then return {} end

  local roots = {}
  for _, tree in ipairs(child:trees()) do
    table.insert(roots, tree:root())
  end
  return collect_from_roots(roots, bufnr)
end

local help_cache = {}
vim.api.nvim_create_autocmd('BufWipeout', {
  callback = function(args) help_cache[args.buf] = nil end,
})

---Datos de ayuda del buffer, derivados de su árbol inyectado y cacheados
---por changedtick. Los ids de scope siempre pertenecen al mismo parseo.
function M.help(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local hit = help_cache[bufnr]
  if hit and hit.tick == tick then return hit end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return { entries = {}, assignments = {} } end
  parser:parse(true)
  local roots = {}
  local child = parser:children().vbscript
  for _, tree in ipairs(child and child:trees() or {}) do roots[#roots + 1] = tree:root() end
  hit = {
    tick = tick, entries = collect_from_roots(roots, bufnr),
    assignments = require('asp.types').scan(roots, bufnr),
  }
  help_cache[bufnr] = hit
  return hit
end

function M.scope_at(entries, position)
  local scope
  for _, entry in ipairs(entries) do
    local r = entry.range
    if entry.params
      and (position.line > r[1] or (position.line == r[1] and position.character >= r[2]))
      and (position.line < r[3] or (position.line == r[3] and position.character < r[4])) then
      scope = entry.decl_id
    end
  end
  return scope
end

local file_cache = {}
-- ruta → {stamp, names} o {stamp, words}: ocurrencias de identificadores
-- de un archivo de disco que se ven a nivel de página, agrupadas por nombre
-- en minúsculas, o solo sus palabras si todavía no hizo falta parsearlo
-- (ver page_occurrences). Separada de file_cache porque workspace/symbol
-- llena esa con todo el proyecto y no necesita las ocurrencias.
local occurrence_cache = {}

---Clave de caché de un archivo: mtime y tamaño (el tamaño cubre los
---sistemas de archivos con mtime de un segundo), como asp.includes.
local function stamp_of(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. ':' .. st.mtime.nsec .. ':' .. st.size) or nil
end

---@param abs_path string
function M.invalidate(abs_path)
  -- Los archivos del sitio (asp.site) se cachean por su ruta real; los del
  -- grafo de includes, por la ruta resuelta. Se olvidan las dos.
  for _, path in ipairs({ vim.fs.normalize(abs_path), vim.uv.fs_realpath(abs_path) }) do
    file_cache[path] = nil
    occurrence_cache[path] = nil
  end
end

---Parsea el contenido de un archivo sin necesidad de un buffer abierto.
---Técnica clave (también el fix del backlog de parseo en frío de ~33s en la
---indexación): parsear el contenido con un parser STRING de aspclassic (solo
---capa top — barato), recolectar los bloques `<% %>` y `<%= %>`
---(asp.ts.vbscript_blocks), y crear un parser STRING de vbscript con
---set_included_regions({bloques}) (una única región combinada, igual que el
---injection "combined" normal) — así solo se parsea VBScript, sin
---injections de html/js/css/regex.
---
---Sin bloques de código devuelve nil.
---@param content string
---@return TSNode|nil vroot
local function parse_content(content)
  -- Capa plantilla: solo top layer, sin injections (barato).
  local tpl = vim.treesitter.get_string_parser(content, 'aspclassic')
  local troot = tpl:parse()[1]:root()
  local blocks = require('asp.ts').vbscript_blocks(troot, content)
  if #blocks == 0 then return nil end

  -- Capa vbscript SOLO en los bloques: nada de html/js/regex.
  -- set_included_regions espera una lista de REGIONES (cada región es una
  -- lista de nodos/rangos parseados en un mismo contexto); envolvemos los
  -- bloques en una región única para que, igual que el injection
  -- "combined" normal, todos los bloques <% %> del archivo formen un solo
  -- árbol vbscript. LanguageTree no tiene `set_included_ranges`, y parse()
  -- sin argumentos NO reparsea regiones incluidas no vacías: hace falta
  -- parse(true).
  local vp = vim.treesitter.get_string_parser(content, 'vbscript')
  vp:set_included_regions({ blocks })
  return vp:parse(true)[1]:root()
end

---Lee y parsea un archivo de disco (ver parse_content). El contenido sale
---de asp.pages.read (sin BOM, latin1 convertido) para que las columnas
---coincidan con las del buffer y con los usos de páginas.
---
---Lanza si el archivo no se puede leer. Sin bloques de código devuelve el
---contenido y nil.
---@param abs_path string
---@return string content
---@return TSNode|nil vroot
local function parse_file(abs_path)
  local content = assert(require('asp.pages').read(abs_path))
  return content, parse_content(content)
end

-- Indicios de un archivo sin bloques de código o que no se pudo leer.
local NO_FACTS = { option_explicit = false }

---Entrada de file_cache de un archivo de disco: sus declaraciones y sus
---indicios para los diagnósticos (asp.vbscript_scan.facts), sacados del
---mismo parseo (ver parse_file) y cacheados por mtime y tamaño. Nil si el
---archivo no existe.
---@param abs_path string
---@return table|nil {stamp, entries, facts, assignments}
local function load_file(abs_path)
  abs_path = vim.fs.normalize(abs_path)
  local stamp = stamp_of(abs_path)
  if not stamp then return nil end
  local hit = file_cache[abs_path]
  if hit and hit.stamp == stamp then return hit end

  local ok, entries, facts, assignments = pcall(function()
    local content, vroot = parse_file(abs_path)
    if not vroot then return {}, NO_FACTS, {} end
    local out = collect_from_roots({ vroot }, content)
    for _, e in ipairs(out) do
      e.file = abs_path
    end
    return out, require('asp.vbscript_scan').facts(vroot, content), require('asp.types').scan({ vroot }, content)
  end)
  hit = { stamp = stamp, entries = ok and entries or {}, facts = ok and facts or NO_FACTS,
    assignments = ok and assignments or {} }
  file_cache[abs_path] = hit
  return hit
end

---La inferencia comparte la lectura y el parseo de collect_file/file_facts.
function M.file_help(abs_path)
  return load_file(abs_path) or { entries = {}, assignments = {} }
end

---Declaraciones de un archivo en disco (ver parse_file), cacheadas por
---mtime y tamaño.
---@param abs_path string
---@return table[] entries (con campo file)
function M.collect_file(abs_path)
  local hit = load_file(abs_path)
  return hit and hit.entries or {}
end

---Indicios de un archivo en disco para los diagnósticos: Option Explicit y
---primer Eval/Execute/ExecuteGlobal (ver asp.vbscript_scan.facts).
---Comparten caché y parseo con M.collect_file.
---@param abs_path string
---@return table { option_explicit, dynamic? }
function M.file_facts(abs_path)
  local hit = load_file(abs_path)
  return hit and hit.facts or NO_FACTS
end

-- ¿(row,col) cae dentro del rango [start,end] de `node`? Misma semántica que
-- vim.treesitter._range.Range.contains (límites inclusivos): usada para
-- confinar la búsqueda de definition al árbol vbscript correcto en vez de
-- recorrer todo el árbol de inyecciones (ver comentario en M.definition).
local function range_contains(node, row, col)
  local sr, sc, er, ec = node:range()
  if row < sr or (row == sr and col < sc) then return false end
  if row > er or (row == er and col > ec) then return false end
  return true
end

---¿`node` (un `identifier`) es un nombre? Un identificador que cruza líneas
---o cuyo texto no es el de un nombre no lo es: la región combinada de un
---parser que no incluye los delimitadores de los bloques puede leer el
---final de un bloque y el comienzo del siguiente como uno solo.
---@param node TSNode
---@param source integer|string
---@return boolean
function M.is_name(node, source)
  local r0, _, r1 = node:range()
  return r0 == r1 and vim.treesitter.get_node_text(node, source):match('^[%a_][%w_]*$') ~= nil
end

---Localiza el TSNode bajo `position`, confinado a la capa
---vbscript (`children().vbscript` + `named_descendant_for_range`). Compartido
---por M.definition y M.references — ver el comentario extenso en
---M.definition sobre por qué esto NUNCA debe volver a un `vim.treesitter.
---get_node()` genérico (race con el árbol de inyecciones bajo highlighter
---incremental async).
---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return TSNode|nil
function M.node_at(bufnr, position)
  local pok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not pok or not parser then return nil end
  parser:parse(true)

  local vbscript = parser:children().vbscript
  if not vbscript then return nil end

  local node
  for _, tree in ipairs(vbscript:trees()) do
    local root = tree:root()
    if range_contains(root, position.line, position.character) then
      node = root:named_descendant_for_range(
        position.line, position.character, position.line, position.character
      )
      break
    end
  end
  -- Un identificador que no es un nombre no se resuelve (ver M.is_name).
  if node and node:type() == 'identifier' and not M.is_name(node, bufnr) then return nil end
  return node
end

---Filtro de identificadores para navegación; hover también admite literales.
function M.identifier_at(bufnr, position)
  local node = M.node_at(bufnr, position)
  return node and node:type() == 'identifier' and node or nil
end

---Resuelve, entre las declaraciones del buffer actual, cuál referencia
---`node` (identificador bajo el cursor) según los mismos tiers que
---M.definition: local del scope del cursor → página (sin scope ni clase) →
---miembro de clase homónimo. Devuelve la
---entry completa (con su scope_id/class_id) o nil si `wanted` no tiene
---ninguna declaración en este buffer. Compartida por M.definition y
---M.references — ver el comentario extenso en M.definition sobre los
---tiers y el refinamiento class_id.
---@param entries table[] declaraciones del buffer
---@param node TSNode identificador bajo el cursor
---@param wanted string ya en minúsculas
---@return table|nil entry
local function resolve_binding(entries, node, wanted)
  local cursor_scope = nearest_ancestor(node, SCOPE_TYPES)
  local cursor_scope_id = cursor_scope and cursor_scope:id() or nil

  local local_hit, page_hit, class_hit
  for _, e in ipairs(entries) do
    if e.name:lower() == wanted and e.decl_id ~= node:id() then
      if cursor_scope_id and e.scope_id == cursor_scope_id then
        local_hit = local_hit or e
      elseif not e.scope_id and not e.class_id then
        page_hit = page_hit or e
      elseif not e.scope_id and e.class_id then
        class_hit = class_hit or e
      end
    end
  end
  return local_hit or page_hit or class_hit
end

---Primera declaración de PÁGINA llamada `wanted` en los archivos de
---`order` (el orden DFS del grafo de includes ES la prioridad). Los locales
---y miembros de clase de otros archivos no son visibles como identificador
---suelto, así que no cuentan. Compartida por M.definition y M.references.
---@param order string[]
---@param wanted string ya en minúsculas
---@return table|nil entry
local function page_declaration_in(order, wanted)
  for _, file in ipairs(order) do
    for _, e in ipairs(M.collect_file(file)) do
      if e.name:lower() == wanted and not e.scope_id and not e.class_id then
        return e
      end
    end
  end
  return nil
end

---Declaración visible para hover y firmas, incluyendo el grafo transitivo.
function M.named(bufnr, position, name)
  local entries = M.help(bufnr).entries
  local scope = M.scope_at(entries, position)
  local local_hit, page_hit, class_hit
  for _, entry in ipairs(entries) do
    if entry.name:lower() == name:lower() then
      if scope and entry.scope_id == scope then
        local_hit = local_hit or entry
      elseif not entry.scope_id and not entry.class_id then
        page_hit = page_hit or entry
      elseif not entry.scope_id then
        class_hit = class_hit or entry
      end
    end
  end
  return local_hit or page_hit or class_hit
    or page_declaration_in(require('asp.includes').buffer_graph(bufnr).order, name:lower())
end

---Resuelve la definición del identificador bajo `position` (case-insensitive),
---con precedencia: scope local del cursor → página (Dim/Const de página,
---excluyendo miembros de clase) → miembro de clase homónimo.
---
---Refinamiento sobre el criterio "page_hit" del brief: tanto un `Dim` de
---página como una propiedad de clase (p.ej. `Total`) tienen scope_id nil —
---una property es miembro de clase pero no vive dentro de ningún
---sub/function/property, así que nearest_ancestor(SCOPE_TYPES) no la alcanza.
---Sin desambiguar por class_id, cuál de las dos gana dependería del orden de
---iteración de `entries` (no determinista para el propósito del spec). Aquí
---page_hit exige además `class_id == nil`; los miembros de clase con scope
---nil caen al tier `class_hit`.
---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return table|nil Location
function M.definition(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  -- vim.treesitter.get_node() sólo ve los árboles inyectados (vbscript) si
  -- el parser ya corrió con injections resueltas; sin un parse(true) previo
  -- devuelve nil para posiciones dentro del bloque <% %> aunque el parser
  -- exista. M.collect() hace lo mismo por la misma razón. identifier_at()
  -- se encarga de ese parse(true).
  --
  -- Deliberadamente NO usamos vim.treesitter.get_node({ignore_injections=
  -- false}). Esa API global resuelve root_lang_tree:named_node_for_range(),
  -- que —cuando ignore_injections es false— recorre TODOS los `_children`
  -- del árbol de inyecciones (html, javascript, la gramática REGEX inyectada
  -- dentro de <script>, vbscript, ...) vía `pairs()` sobre una tabla hash de
  -- Lua: el orden de iteración no es estable y decide cuál árbol "gana" la
  -- posición cuando hay solapes. plugin/asp.lua adjunta el highlighter
  -- incremental (`vim.treesitter.start`) al mismo buffer, que reconstruye
  -- ese árbol de _children en segundo plano (parses asíncronos programados
  -- vía vim.schedule); mientras ese ciclo corre, el orden de `pairs()` puede
  -- cambiar entre una llamada y la siguiente sobre la MISMA posición. En
  -- archivos .asp grandes con <script> que contienen regexes, eso es lo que
  -- produce el bug reportado: a veces se resuelve el `identifier` vbscript
  -- correcto, a veces gana primero un `pattern_character` de la gramática
  -- REGEX inyectada en una región del buffer completamente distinta →
  -- definition no encuentra `identifier` y devuelve nil de forma errática.
  --
  -- La resolución de definición sólo tiene sentido dentro de la capa
  -- vbscript, así que identifier_at() confina la búsqueda a ese único árbol
  -- (`parser:children().vbscript`) sin tocar los demás lenguajes inyectados.
  -- Esto es determinista: no depende del orden de _children ni de en qué
  -- punto esté el highlighter async. Si la posición no cae dentro de ningún
  -- árbol vbscript (cursor en HTML/JS/regex), es semánticamente correcto
  -- devolver nil — no hay definición VBScript ahí.
  --
  -- NO "simplificar" esto de vuelta a vim.treesitter.get_node: reintroduce
  -- la carrera de arriba.
  local node = M.identifier_at(bufnr, position)
  if not node then return nil end
  local wanted = vim.treesitter.get_node_text(node, bufnr):lower()

  local best = resolve_binding(M.collect(bufnr), node, wanted)

  if not best then
    -- Fase 4: nada in-file — el primer símbolo de página del grafo de
    -- includes, en orden DFS. Primer match gana.
    local e = page_declaration_in(require('asp.includes').buffer_graph(bufnr).order, wanted)
    if not e then return nil end
    return {
      uri = vim.uri_from_fname(e.file),
      range = {
        start = { line = e.selection[1], character = e.selection[2] },
        ['end'] = { line = e.selection[3], character = e.selection[4] },
      },
    }
  end

  return {
    uri = vim.uri_from_bufnr(bufnr),
    range = {
      start = { line = best.selection[1], character = best.selection[2] },
      ['end'] = { line = best.selection[3], character = best.selection[4] },
    },
  }
end

local IDENT_QUERY = [[ (identifier) @id ]]

-- Scopes e identificadores en una sola pasada. iter_captures los entrega
-- por posición de inicio, y en un empate primero el patrón anterior: cada
-- identificador cae en el último scope abierto que todavía no terminó.
-- Así no hace falta subir con node:parent() desde cada identificador, que
-- se llevaba la mayor parte del tiempo de un archivo con mucho código.
local OCCURRENCE_QUERY = [[
[(sub_statement) (function_statement) (property_statement)] @scope
(identifier) @id
]]

---¿El identificador que empieza en el byte `start` (0-indexed) de `text`
---es el miembro de un acceso (`obj.Total`, `Me.Total`, `.Total` de un
---With)? Lo es si lo precede un punto, con blancos en el medio o no.
---@param text string
---@param start integer
---@return boolean
local function after_dot(text, start)
  for i = start, 1, -1 do
    local ch = text:byte(i)
    if ch == 46 then return true end
    if ch ~= 32 and ch ~= 9 then return false end
  end
  return false
end

---Miembro de objeto, incluidas las continuaciones `obj. _\n nombre`.
---El punto en el texto también cubre `.nombre` de With si el parser no
---consigue armar un member_expression sin receptor explícito.
function M.is_member(node, source)
  local parent = node:parent()
  if parent and parent:type() == 'member_expression' then return true end
  local row, col, byte = node:start()
  if type(source) == 'number' then
    return after_dot(vim.api.nvim_buf_get_lines(source, row, row + 1, true)[1], col)
  end
  return after_dot(source, byte)
end

---Palabras distintas de un contenido en minúsculas, separadas por
---espacios. Un identificador VBScript solo tiene letras, dígitos y `_`, así
---que siempre queda dentro de una de ellas: buscarlo en este texto da lo
---mismo que buscarlo en el contenido, que es mucho más grande.
---@param lower string
---@return string
local function words_of(lower)
  local seen, list = {}, {}
  for word in lower:gmatch('[%w_]+') do
    if not seen[word] then
      seen[word] = true
      list[#list + 1] = word
    end
  end
  return table.concat(list, ' ')
end

---Ocurrencias de un contenido que se ven a nivel de página, agrupadas por
---nombre en minúsculas (ver page_occurrences). Llena también la caché de
---declaraciones e indicios de M.collect_file con el mismo parseo.
---@param abs_path string
---@param content string
---@param stamp string
---@return table<string, integer[]>
local function parse_occurrences(abs_path, content, stamp)
  local vroot = parse_content(content)
  if not vroot then return {} end
  local entries = collect_from_roots({ vroot }, content)
  local locals = {}
  for _, e in ipairs(entries) do
    e.file = abs_path
    if e.scope_id then
      locals[e.scope_id] = locals[e.scope_id] or {}
      locals[e.scope_id][e.name:lower()] = true
    end
  end
  local cached = file_cache[abs_path]
  if not cached or cached.stamp ~= stamp then
    file_cache[abs_path] = {
      stamp = stamp, entries = entries,
      facts = require('asp.vbscript_scan').facts(vroot, content),
      assignments = require('asp.types').scan({ vroot }, content),
    }
  end

  local out = {}
  local query = vim.treesitter.query.parse('vbscript', OCCURRENCE_QUERY)
  -- Pila de scopes abiertos: su id y el byte donde terminan.
  local scopes, stops = {}, {}
  for id, node in query:iter_captures(vroot, content) do
    local r0, c0, start = node:start()
    while stops[1] and stops[#stops] <= start do
      scopes[#scopes], stops[#stops] = nil, nil
    end
    if query.captures[id] == 'scope' then
      local _, _, stop = node:end_()
      scopes[#scopes + 1], stops[#stops + 1] = node:id(), stop
    else
      local name = vim.treesitter.get_node_text(node, content):lower()
      local shadowing = scopes[1] and locals[scopes[#scopes]]
      if not (shadowing and shadowing[name]) then
        local _, c1 = node:end_()
        local list = out[name]
        if not list then
          list = {}
          out[name] = list
        end
        list[#list + 1] = r0
        list[#list + 1] = c0
        list[#list + 1] = c1
        list[#list + 1] = M.is_member(node, content)
      end
    end
  end
  return out
end

---Ocurrencias de página de `wanted` en un archivo de disco: una lista
---plana {fila, col_inicio, col_fin, miembro, ...} (un identificador no
---cruza líneas; `miembro` marca el nombre de un acceso `obj.Total`, ver
---is_member), o nil. Deja afuera las que caen en un Sub/Function/Property que
---declara ese nombre como local o parámetro: ahí el nombre es otra
---variable, igual que con `shadowed` en el buffer.
---
---Solo parsea los archivos que mencionan `wanted` en su texto. Al
---parsear guarda TODOS los nombres del archivo, por mtime y tamaño: así,
---con la caché caliente, buscar cualquier otro símbolo en el sitio no
---vuelve a leer ni parsear nada. De un archivo que no lo menciona guarda
---solo sus palabras (ver words_of), para saber sin releerlo si más tarde
---hay que parsearlo por otro nombre.
---
---`contents` trae lo que la consulta ya leyó, empezando por el barrido
---del sitio: un archivo que está ahí no se vuelve a leer, y lo que se lee
---acá se agrega para contarlo.
---@param abs_path string normalizada
---@param wanted string ya en minúsculas
---@param contents table<string, string>
---@return integer[]|nil
local function page_occurrences(abs_path, wanted, contents)
  local stamp = stamp_of(abs_path)
  if not stamp then
    occurrence_cache[abs_path] = nil
    return nil
  end
  local hit = occurrence_cache[abs_path]
  if hit and hit.stamp == stamp then
    if hit.names then return hit.names[wanted] end
    if not hit.words:find(wanted, 1, true) then return nil end
  end

  local content = contents[abs_path]
  if not content then
    -- Un fallo de lectura no se cachea: la próxima consulta reintenta.
    content = require('asp.pages').read(abs_path)
    if not content then return nil end
    contents[abs_path] = content
  end
  local lower = content:lower()
  if not lower:find(wanted, 1, true) then
    occurrence_cache[abs_path] = { stamp = stamp, words = words_of(lower) }
    return nil
  end
  local ok, names = pcall(parse_occurrences, abs_path, content, stamp)
  if not ok then return nil end
  occurrence_cache[abs_path] = { stamp = stamp, names = names }
  return names[wanted]
end

---Ocurrencias de página de `wanted` en un archivo de disco (ver
---page_occurrences).
---@param abs_path string
---@param wanted string ya en minúsculas
---@param contents table<string, string>
---@param skip_members? boolean sin los nombres de un acceso `obj.Total`
---@return table[] Location[]
local function occurrences_in_file(abs_path, wanted, contents, skip_members)
  local hits = page_occurrences(vim.fs.normalize(abs_path), wanted, contents)
  if not hits then return {} end
  local uri = vim.uri_from_fname(abs_path)
  local out = {}
  for i = 1, #hits, 4 do
    if not (skip_members and hits[i + 3]) then
      table.insert(out, {
        uri = uri,
        range = {
          start = { line = hits[i], character = hits[i + 1] },
          ['end'] = { line = hits[i], character = hits[i + 2] },
        },
      })
    end
  end
  return out
end

---Archivos del sitio donde un símbolo de página del buffer es la misma
---variable global (ver asp.site.closure): el propio archivo y, si el nombre
---no se declara en el buffer, también el include que lo declara según el
---orden de M.definition. Así las referencias son las mismas desde la
---librería que desde cualquier página que la usa.
---
---Los includes del propio archivo son los del buffer, con lo que tenga sin
---guardar, igual que `graph`: el índice del sitio los conoce por el disco.
---@param bufnr integer
---@param binding table|nil
---@param wanted string
---@param graph string[] buffer_graph(bufnr).order
---@param contents table<string, string> ver asp.pages.sweep
---@return string[]|nil rutas reales del sitio
---@return string|nil ruta real del buffer
---@return integer|nil archivos recorridos por el barrido
local function site_files(bufnr, binding, wanted, graph, contents)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then return nil end
  local root = require('asp.pages').scan_root_for(name)
  if not root then return nil end
  local self = vim.uv.fs_realpath(name) or vim.fs.normalize(name)
  local starts = { self }
  if not binding then
    local e = page_declaration_in(graph, wanted)
    if e then table.insert(starts, vim.uv.fs_realpath(e.file) or e.file) end
  end
  local targets = {}
  for _, item in ipairs(require('asp.includes').includes_of(nil, bufnr)) do
    if item.resolved then table.insert(targets, vim.uv.fs_realpath(item.resolved) or item.resolved) end
  end
  local site = require('asp.site')
  local index = site.index(root, contents)
  return site.closure(index, starts, { [self] = targets }), self, index.count
end

---Todas las ocurrencias del identificador bajo `position`.
---
---Si el identificador se resuelve a una declaración LOCAL (scope_id ~= nil:
---vive dentro de un sub/function/property), los locales no son visibles
---fuera de ese scope ni fuera del buffer — un `contador` de una Function
---no debe conflating con el `contador` homónimo de otra. En ese caso las
---referencias se confinan a las ocurrencias del buffer actual cuyo
---sub/function/property ancestro más cercano coincide con ese scope_id, y
---el grafo de includes NI SIQUIERA se consulta (un local no puede
---aparecer en otro archivo).
---
---Si se resuelve a página/clase (scope_id nil) — o no se resuelve a nada
---in-file —, excluye los scopes que declaran ese nombre como local y,
---salvo con buffer_only, suma las ocurrencias de disco con alcance de
---sitio: el grafo de includes del buffer (con su contenido sin guardar),
---las páginas que incluyen el archivo directa o transitivamente y todo lo
---que incluye cada una (un include hermano de la librería también puede
---llamarla). En cada archivo de disco se omiten las ocurrencias dentro de
---un Sub/Function/Property que declara el nombre como local o parámetro.
---
---Una declaración de página homónima en otro archivo de ese conjunto se
---cuenta igual: al incluirse, Classic ASP junta todo en un único script y
---es la misma variable global (en runtime gana la última definición). Una
---página que no incluye la librería no está en el conjunto aunque use el
---mismo nombre. No se siguen Server.Execute, Server.Transfer ni includes
---armados en runtime.
---
---Los usos se buscan por nombre: el miembro de un acceso (`obj.Total`,
---`Me.Total`) cuenta como uso de un `Total` de página. Con skip_members
---se omiten (los usa asp.rename, que no toca miembros de objeto).
---@param bufnr integer
---@param position table {line, character}
---@param opts? table {buffer_only?: boolean, skip_members?: boolean}
---@return table[] Location[]
---@return table|nil binding declaración del buffer, si existe
---@return string[]|nil archivos de disco recorridos (el grafo y el sitio),
---  si la búsqueda salió del buffer
function M.references(bufnr, position, opts)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  opts = opts or {}
  local node = M.identifier_at(bufnr, position)
  if not node then return {} end
  local wanted = vim.treesitter.get_node_text(node, bufnr):lower()

  local entries = M.collect(bufnr)
  local binding = resolve_binding(entries, node, wanted)
  local scope_id = binding and binding.scope_id or nil
  local shadowed = {}
  if not scope_id then
    for _, entry in ipairs(entries) do
      if entry.scope_id and entry.name:lower() == wanted then
        shadowed[entry.scope_id] = true
      end
    end
  end

  local out = {}
  -- buffer actual: ocurrencias sobre sus árboles vbscript ya parseados
  local parser = vim.treesitter.get_parser(bufnr)
  parser:parse(true)
  local child = parser:children().vbscript
  if child then
    local iq = vim.treesitter.query.parse('vbscript', IDENT_QUERY)
    for _, tree in ipairs(child:trees()) do
      for _, n in iq:iter_captures(tree:root(), bufnr) do
        if vim.treesitter.get_node_text(n, bufnr):lower() == wanted then
          local n_scope = nearest_ancestor(n, SCOPE_TYPES)
          local n_scope_id = n_scope and n_scope:id() or nil
          local r0, c0, r1, c1 = n:range()
          local member = opts.skip_members and M.is_member(n, bufnr)
          if not member
            and ((scope_id and n_scope_id == scope_id) or (not scope_id and not shadowed[n_scope_id])) then
            table.insert(out, {
              uri = vim.uri_from_bufnr(bufnr),
              range = {
                start = { line = r0, character = c0 },
                ['end'] = { line = r1, character = c1 },
              },
            })
          end
        end
      end
    end
  end
  if not scope_id and not opts.buffer_only then
    local started = vim.uv.hrtime()
    local graph = require('asp.includes').buffer_graph(bufnr).order
    -- Primero el grafo del buffer, en su orden (como antes del alcance de
    -- sitio); después el resto del sitio, ordenado. Se deduplica por ruta
    -- real porque el grafo usa la ruta del buffer y el sitio, la real.
    local files = vim.list_extend({}, graph)
    -- Contenido leído en esta consulta, por ruta: el barrido lo deja para
    -- no volver a leer los archivos que hay que parsear (ver
    -- page_occurrences) y se suelta al terminar.
    local contents = {}
    -- Si el sitio falla, quedan el buffer y su grafo: el handler no lanza.
    local ok, site, self, swept = pcall(site_files, bufnr, binding, wanted, graph, contents)
    if ok and site then
      local taken = { [self] = true }
      for _, file in ipairs(graph) do
        taken[vim.uv.fs_realpath(file) or file] = true
      end
      for _, file in ipairs(site) do
        if not taken[file] then table.insert(files, file) end
      end
    end
    for _, file in ipairs(files) do
      vim.list_extend(out, occurrences_in_file(file, wanted, contents, opts.skip_members))
    end
    if ok and swept then
      require('asp.pages').notify_slow(swept, vim.tbl_count(contents), started)
    end
    return out, binding, files
  end
  return out, binding
end

---Ocurrencias de página de `name` (sin distinguir mayúsculas) en un
---archivo de disco, sin los miembros de objeto: las declaraciones y usos
---que se ven a nivel de página, como las cuenta references (ver
---page_occurrences). Con la caché de ocurrencias caliente no lee nada;
---solo parsea un archivo cuyo texto menciona `name` y que todavía no se
---parseó.
---@param abs_path string
---@param name string
---@return table[] Location[]
function M.page_uses(abs_path, name)
  return occurrences_in_file(abs_path, name:lower(), {}, true)
end

---Nodos `identifier` del árbol VBScript del buffer, en orden del
---documento: el mismo árbol que recorren collect y references.
---@param bufnr integer
---@return TSNode[]
function M.identifiers(bufnr)
  local out = {}
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return out end
  parser:parse(true)
  local child = parser:children().vbscript
  if not child then return out end
  local iq = vim.treesitter.query.parse('vbscript', IDENT_QUERY)
  for _, tree in ipairs(child:trees()) do
    for _, n in iq:iter_captures(tree:root(), bufnr) do
      out[#out + 1] = n
    end
  end
  return out
end

---Busca símbolos en todo el árbol de `root_dir` cuyo nombre contenga
---`query_str` (case-insensitive; string vacío matchea todo). Excluye
---build/, parser/ y grammars/ — directorios del propio plugin (clones de
---dependencias, artefactos compilados, fuentes de gramática) que no
---aportan símbolos ASP y sólo suman tiempo de escaneo.
---@param query_str string
---@param root_dir string
---@return table[] SymbolInformation[]
function M.workspace_symbols(query_str, root_dir)
  local q = (query_str or ''):lower()
  local files = vim.fs.find(function(name, path)
    if path:find('/build/') or path:find('/parser/') or path:find('/grammars/') then
      return false
    end
    return name:match('%.asp$') ~= nil or name:match('%.inc$') ~= nil
  end, { path = root_dir, type = 'file', limit = math.huge })

  local out = {}
  for _, file in ipairs(files) do
    for _, e in ipairs(M.collect_file(file)) do
      if q == '' or e.name:lower():find(q, 1, true) then
        table.insert(out, {
          name = e.name,
          kind = e.kind,
          location = {
            uri = vim.uri_from_fname(e.file),
            range = {
              start = { line = e.selection[1], character = e.selection[2] },
              ['end'] = { line = e.selection[3], character = e.selection[4] },
            },
          },
        })
      end
    end
  end
  return out
end

local function to_lsp_range(r)
  return {
    start = { line = r[1], character = r[2] },
    ['end'] = { line = r[3], character = r[4] },
  }
end

---@param bufnr integer
---@return table[] DocumentSymbol[]
function M.document_symbols(bufnr)
  local entries = M.collect(bufnr)
  local roots, by_decl = {}, {}

  for _, e in ipairs(entries) do
    local sym = {
      name = e.name,
      kind = e.kind,
      range = to_lsp_range(e.range),
      selectionRange = to_lsp_range(e.selection),
      children = {},
    }
    by_decl[e.decl_id] = sym
    e._sym = sym
  end

  for _, e in ipairs(entries) do
    if e.scope_id and not e.class_id then
      -- local de función: fuera del outline
    elseif e.class_id and by_decl[e.class_id] then
      if not e.scope_id then
        table.insert(by_decl[e.class_id].children, e._sym)
      end
      -- (con scope_id dentro de clase = local de método: fuera)
    else
      table.insert(roots, e._sym)
    end
  end
  return roots
end

return M
