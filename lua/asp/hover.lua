local M = {}

local intrinsics = require('asp.intrinsics')
local symbols = require('asp.symbols')
local com = require('asp.com')
local signature_info = require('asp.signature_info')

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
  if not require('asp.call_context').line(bufnr, position) then return nil end
  local node = symbols.node_at(bufnr, position)
  if not node then return nil end
  local literals = { boolean_literal = true, nothing_literal = true, null_literal = true, empty_literal = true }
  if node:type() ~= 'identifier' and not literals[node:type()] then return nil end
  local text = vim.treesitter.get_node_text(node, bufnr)

  -- 1. ¿miembro de un objeto intrínseco?
  local obj_text = object_of_member(node, bufnr)
  if obj_text then
    local m = intrinsics.member(obj_text, text)
    if m then
      return md(('```vbscript\n%s\n```\n\n%s'):format(m.signature, m.doc))
    end
    local obj = require('asp.types').infer(bufnr, position, obj_text)
    m = obj and com.member(obj.id, text)
    if m then
      return md(signature_info.markdown(m) .. '\n\nTipo: `' .. obj.name .. '`.')
    end
    return nil
  end
  if node:parent() and node:parent():type() == 'member_expression' then return nil end

  local inferred = require('asp.types').infer(bufnr, position, text)
  if inferred then
    return md(('**%s** (`%s`)\n\n%s'):format(text, inferred.name, inferred.doc))
  end

  local obj = intrinsics.object(text)
  if obj then
    return md(('**%s** (objeto intrínseco ASP)\n\n%s'):format(obj.name, obj.doc))
  end

  local native = require('asp.vbscript_builtins').lookup(text)
  if native and native.group == 'functions' then
    return md(signature_info.markdown(native))
  elseif native and native.group == 'constants' then
    return md(('```vbscript\n%s = %s\n```\n\n%s'):format(native.name, native.value, native.doc))
  end

  local entry = symbols.named(bufnr, position, text)
  if entry then
    local value = ('```vbscript\n%s\n```'):format(entry.declaration)
    if entry.file then value = value .. '\n\nArchivo: `' .. vim.fn.fnamemodify(entry.file, ':t') .. '`.' end
    return md(value)
  end
  return nil
end

return M
