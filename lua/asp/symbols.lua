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

return M
