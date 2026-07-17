local M = {}

local intrinsics = require('asp.intrinsics')
local symbols = require('asp.symbols')

local function md(value)
  return { contents = { kind = 'markdown', value = value } }
end

-- ¿El nodo es el MIEMBRO de un member_expression? Devuelve el texto del
-- objeto (primary_expression.identifier) si lo es.
local function object_of_member(node, bufnr)
  local parent = node:parent()
  if not parent or parent:type() ~= 'member_expression' then return nil end
  -- primer hijo con nombre: primary_expression que envuelve el objeto
  local obj = parent:named_child(0)
  if not obj then return nil end
  if obj:type() == 'primary_expression' then obj = obj:named_child(0) end
  if not obj or obj:type() ~= 'identifier' then return nil end
  -- el node debe ser el segundo identifier (miembro), no el objeto
  if obj:id() == node:id() then return nil end
  return vim.treesitter.get_node_text(obj, bufnr)
end

---@param bufnr integer
---@param position table {line, character}
---@return table|nil hover
function M.hover(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  -- identifier_at() ya confina el lookup a la capa vbscript y filtra por
  -- tipo identifier (ver asp/symbols.lua) — reusar en vez de duplicar
  -- (Global Constraint del plan). La comprobación de tipo queda como guard
  -- redundante pero inofensivo.
  local node = symbols.identifier_at(bufnr, position)
  if not node or node:type() ~= 'identifier' then return nil end
  local text = vim.treesitter.get_node_text(node, bufnr)

  -- 1. ¿miembro de un objeto intrínseco?
  local obj_text = object_of_member(node, bufnr)
  if obj_text then
    local m = intrinsics.member(obj_text, text)
    if m then
      return md(('```vbscript\n%s\n```\n\n%s'):format(m.signature, m.doc))
    end
  end

  -- 2. ¿objeto intrínseco?
  local obj = intrinsics.object(text)
  if obj then
    return md(('**%s** (objeto intrínseco ASP)\n\n%s'):format(obj.name, obj.doc))
  end

  -- 3. símbolo de usuario del buffer: mostrar la primera línea de su
  -- declaración.
  local wanted = text:lower()
  for _, e in ipairs(symbols.collect(bufnr)) do
    if e.name:lower() == wanted then
      local line = vim.api.nvim_buf_get_lines(bufnr, e.range[1], e.range[1] + 1, false)[1] or ''
      return md(('```vbscript\n%s\n```'):format(vim.trim(line)))
    end
  end
  return nil
end

return M
