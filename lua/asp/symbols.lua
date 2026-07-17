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
          table.insert(entries, {
            name = vim.treesitter.get_node_text(name_node, source),
            kind = PATTERN_KINDS[pattern],
            range = { r0, c0, r1, c1 },
            selection = { sr0, sc0, sr1, sc1 },
            decl_id = decl_node:id(),
            class_id = class_anc and class_anc:id() or nil,
            scope_id = scope_anc and scope_anc:id() or nil,
          })
        end
      end
    end
  end
  return entries
end

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

local CODE_QUERY = [[ (code) @code ]]

local file_cache = {}

local function mtime_of(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. ':' .. st.mtime.nsec) or nil
end

---@param abs_path string
function M.invalidate(abs_path)
  file_cache[vim.fs.normalize(abs_path)] = nil
end

---Extrae símbolos de un archivo en disco sin necesidad de un buffer abierto.
---Técnica clave (también el fix del backlog de parseo en frío de ~33s en la
---indexación): parsear el contenido con un parser STRING de aspclassic (solo
---capa top — barato), recolectar los nodos `(code)`, y crear un parser
---STRING de vbscript con set_included_regions({code_nodes}) (una única
---región combinada, igual que el injection "combined" normal) — así solo se
---parsea VBScript, sin injections de html/js/css/regex.
---@param abs_path string
---@return table[] entries (con campo file)
function M.collect_file(abs_path)
  abs_path = vim.fs.normalize(abs_path)
  local mt = mtime_of(abs_path)
  if not mt then return {} end
  local hit = file_cache[abs_path]
  if hit and hit.mtime == mt then return hit.entries end

  local ok, entries = pcall(function()
    local f = assert(io.open(abs_path, 'r'))
    local content = f:read('*a')
    f:close()

    -- Capa plantilla: solo top layer, sin injections (barato).
    local tpl = vim.treesitter.get_string_parser(content, 'aspclassic')
    local troot = tpl:parse()[1]:root()
    local cq = vim.treesitter.query.parse('aspclassic', CODE_QUERY)
    local code_nodes = {}
    for _, node in cq:iter_captures(troot, content) do
      table.insert(code_nodes, node)
    end
    if #code_nodes == 0 then return {} end

    -- Capa vbscript SOLO en los rangos de código: nada de html/js/regex.
    -- set_included_regions espera una lista de REGIONES (cada región es una
    -- lista de nodos/rangos parseados en un mismo contexto); envolvemos
    -- code_nodes en una región única para que, igual que el injection
    -- "combined" normal, todos los bloques <% %> del archivo formen un solo
    -- árbol vbscript.
    local vp = vim.treesitter.get_string_parser(content, 'vbscript')
    vp:set_included_regions({ code_nodes })
    local vroot = vp:parse(true)[1]:root()

    local out = collect_from_roots({ vroot }, content)
    for _, e in ipairs(out) do
      e.file = abs_path
    end
    return out
  end)
  entries = ok and entries or {}
  file_cache[abs_path] = { mtime = mt, entries = entries }
  return entries
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

---Localiza el TSNode `identifier` bajo `position`, confinado a la capa
---vbscript (`children().vbscript` + `named_descendant_for_range`). Compartido
---por M.definition y M.references — ver el comentario extenso en
---M.definition sobre por qué esto NUNCA debe volver a un `vim.treesitter.
---get_node()` genérico (race con el árbol de inyecciones bajo highlighter
---incremental async).
---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return TSNode|nil
local function identifier_at(bufnr, position)
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
  if not node or node:type() ~= 'identifier' then return nil end
  return node
end

---Resuelve la definición del identificador bajo `position` (case-insensitive),
---con precedencia: scope local del cursor → página (Dim/Const de página,
---excluyendo miembros de clase) → miembro de clase homónimo → cualquier
---coincidencia restante.
---
---Refinamiento sobre el criterio "page_hit" del brief: tanto un `Dim` de
---página como una propiedad de clase (p.ej. `Total`) tienen scope_id nil —
---una property es miembro de clase pero no vive dentro de ningún
---sub/function/property, así que nearest_ancestor(SCOPE_TYPES) no la alcanza.
---Sin desambiguar por class_id, cuál de las dos gana dependería del orden de
---iteración de `entries` (no determinista para el propósito del spec). Aquí
---page_hit exige además `class_id == nil`; los miembros de clase con scope
---nil caen a un tier `class_hit` intermedio, antes de `any_hit`.
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
  local node = identifier_at(bufnr, position)
  if not node then return nil end
  local wanted = vim.treesitter.get_node_text(node, bufnr):lower()

  local cursor_scope = nearest_ancestor(node, SCOPE_TYPES)
  local cursor_scope_id = cursor_scope and cursor_scope:id() or nil

  local entries = M.collect(bufnr)
  local local_hit, page_hit, class_hit, any_hit
  for _, e in ipairs(entries) do
    if e.name:lower() == wanted and e.decl_id ~= node:id() then
      any_hit = any_hit or e
      if cursor_scope_id and e.scope_id == cursor_scope_id then
        local_hit = local_hit or e
      elseif not e.scope_id and not e.class_id then
        page_hit = page_hit or e
      elseif not e.scope_id and e.class_id then
        class_hit = class_hit or e
      end
    end
  end
  local best = local_hit or page_hit or class_hit or any_hit

  if not best then
    -- Fase 4: nada in-file — recorrer el grafo de includes en orden DFS
    -- (esa orden ES la prioridad: "includes en orden") y devolver el primer
    -- símbolo de PÁGINA (scope_id == nil y class_id == nil: los locales y
    -- miembros de clase de otros archivos no son visibles como identificador
    -- suelto) cuyo nombre matchee. Primer match gana → return inmediato.
    local graph = require('asp.includes').buffer_graph(bufnr)
    for _, file in ipairs(graph.order) do
      for _, e in ipairs(M.collect_file(file)) do
        if e.name:lower() == wanted and not e.scope_id and not e.class_id then
          return {
            uri = vim.uri_from_fname(e.file),
            range = {
              start = { line = e.selection[1], character = e.selection[2] },
              ['end'] = { line = e.selection[3], character = e.selection[4] },
            },
          }
        end
      end
    end
    return nil
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

---Ocurrencias case-insensitive de `wanted` en un archivo de disco (misma
---técnica que M.collect_file: sólo capa vbscript, confinada a los rangos
---`(code)` de la plantilla).
---
---Ajuste sobre el brief (dos hechos de API confirmados en Task 2, aquí
---aplicados): LanguageTree no tiene `set_included_ranges` — el método real
---es `set_included_regions({code_nodes})` (una lista de REGIONES, cada una
---una lista de nodos) — y `parse()` sin argumentos NO reparsea regiones
---incluidas no vacías; hace falta `parse(true)`.
---@param abs_path string
---@param wanted string ya en minúsculas
---@return table[] Location[]
local function occurrences_in_file(abs_path, wanted)
  local out = {}
  local ok = pcall(function()
    local f = assert(io.open(abs_path, 'r'))
    local content = f:read('*a')
    f:close()
    local tpl = vim.treesitter.get_string_parser(content, 'aspclassic')
    local troot = tpl:parse()[1]:root()
    local cq = vim.treesitter.query.parse('aspclassic', CODE_QUERY)
    local code_nodes = {}
    for _, node in cq:iter_captures(troot, content) do
      table.insert(code_nodes, node)
    end
    if #code_nodes == 0 then return end
    local vp = vim.treesitter.get_string_parser(content, 'vbscript')
    vp:set_included_regions({ code_nodes })
    local vroot = vp:parse(true)[1]:root()
    local iq = vim.treesitter.query.parse('vbscript', IDENT_QUERY)
    for _, node in iq:iter_captures(vroot, content) do
      if vim.treesitter.get_node_text(node, content):lower() == wanted then
        local r0, c0, r1, c1 = node:range()
        table.insert(out, {
          uri = vim.uri_from_fname(abs_path),
          range = {
            start = { line = r0, character = c0 },
            ['end'] = { line = r1, character = c1 },
          },
        })
      end
    end
  end)
  return ok and out or {}
end

---Todas las ocurrencias del identificador bajo `position`: en el buffer
---actual (sobre sus árboles vbscript ya parseados) y en cada archivo del
---grafo de includes.
---@param bufnr integer
---@param position table {line, character}
---@return table[] Location[]
function M.references(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local node = identifier_at(bufnr, position)
  if not node then return {} end
  local wanted = vim.treesitter.get_node_text(node, bufnr):lower()

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
          local r0, c0, r1, c1 = n:range()
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
  for _, file in ipairs(require('asp.includes').buffer_graph(bufnr).order) do
    vim.list_extend(out, occurrences_in_file(file, wanted))
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
