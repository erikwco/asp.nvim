local M = {}

local intrinsics = require('asp.intrinsics')

-- CompletionItemKind (LSP): Method=2, Field=5, Function=3, Variable=6,
-- Class=7, Constant=21, Module=9.
local KIND_METHOD = 2
local KIND_MODULE = 9

-- Mapa de SymbolKind (documentSymbol) → CompletionItemKind.
local SYM_TO_COMPL = {
  [5] = 7,   -- Class → Class
  [7] = 3,   -- Property → Function
  [12] = 3,  -- Function → Function
  [13] = 6,  -- Variable → Variable
  [14] = 21, -- Constant → Constant
}

local function item(label, kind, detail, doc)
  return {
    label = label, kind = kind, detail = detail,
    documentation = doc and { kind = 'markdown', value = doc } or nil,
  }
end

---@param bufnr integer
---@param position table {line, character}
---@return table[] CompletionItem[]
function M.complete(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1] or ''
  local before = line:sub(1, position.character)

  -- ¿contexto miembro? Objeto . prefijo
  local obj_name, prefix = before:match('([%w_]+)%.([%w_]*)$')
  if obj_name and intrinsics.object(obj_name) then
    local out = {}
    local pfx = prefix:lower()
    for _, m in ipairs(intrinsics.members_of(obj_name)) do
      if pfx == '' or m.name:lower():sub(1, #pfx) == pfx then
        table.insert(out, item(m.name, KIND_METHOD, m.signature, m.doc))
      end
    end
    return out
  end

  -- contexto general: objetos intrínsecos + símbolos del buffer y del grafo.
  local word = before:match('([%w_]*)$') or ''
  local pfx = word:lower()
  local seen = {}
  local out = {}
  local function add(label, kind, detail)
    local key = label:lower() .. ':' .. kind
    if seen[key] then return end
    if pfx ~= '' and label:lower():sub(1, #pfx) ~= pfx then return end
    seen[key] = true
    table.insert(out, item(label, kind, detail))
  end

  for _, name in ipairs(intrinsics.object_names()) do
    add(name, KIND_MODULE, 'objeto intrínseco ASP')
  end
  for _, e in ipairs(require('asp.symbols').collect(bufnr)) do
    add(e.name, SYM_TO_COMPL[e.kind] or 6, nil)
  end
  local ok, graph = pcall(require('asp.includes').buffer_graph, bufnr)
  if ok then
    for _, file in ipairs(graph.order) do
      for _, e in ipairs(require('asp.symbols').collect_file(file)) do
        if not e.scope_id and not e.class_id then
          add(e.name, SYM_TO_COMPL[e.kind] or 6, nil)
        end
      end
    end
  end
  return out
end

return M
