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

---@param bufnr integer
---@return table[] entries
function M.collect(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return {} end
  parser:parse(true)
  local child = parser:children().vbscript
  if not child then return {} end

  local query = vim.treesitter.query.parse('vbscript', QUERY)
  local entries = {}
  local seen = {}

  for _, tree in ipairs(child:trees()) do
    for pattern, match in query:iter_matches(tree:root(), bufnr) do
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
            name = vim.treesitter.get_node_text(name_node, bufnr),
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
  -- el parser ya corrió con injections resueltas; sin este parse(true)
  -- previo devuelve nil para posiciones dentro del bloque <% %> aunque el
  -- parser exista. M.collect() hace lo mismo por la misma razón.
  local pok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not pok or not parser then return nil end
  parser:parse(true)

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
  -- vbscript, así que confinamos la búsqueda a ese único árbol
  -- (`parser:children().vbscript`) sin tocar los demás lenguajes inyectados.
  -- Esto es determinista: no depende del orden de _children ni de en qué
  -- punto esté el highlighter async. Si la posición no cae dentro de ningún
  -- árbol vbscript (cursor en HTML/JS/regex), es semánticamente correcto
  -- devolver nil — no hay definición VBScript ahí.
  --
  -- NO "simplificar" esto de vuelta a vim.treesitter.get_node: reintroduce
  -- la carrera de arriba.
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
  if not best then return nil end
  return {
    uri = vim.uri_from_bufnr(bufnr),
    range = {
      start = { line = best.selection[1], character = best.selection[2] },
      ['end'] = { line = best.selection[3], character = best.selection[4] },
    },
  }
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
