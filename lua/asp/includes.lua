local M = {}

local INCLUDE_QUERY = [[
(include_directive
  kind: (include_kind) @kind
  path: (quoted_path) @path) @inc
]]

local function norm(path)
  return (vim.fs.normalize(path):gsub('//+', '/'))
end

local function virtual_root_for(abs_path)
  local opts = require('asp').options
  if opts.virtual_root and opts.virtual_root ~= '' then
    return norm(opts.virtual_root)
  end
  return vim.fs.root(abs_path, { 'web.config' })
    or vim.fs.root(abs_path, { '.git' })
end

-- Extrae los includes de UNA fuente ya parseada (top layer aspclassic;
-- las injections no se tocan: los include_directive viven en la plantilla).
local function extract(root_node, source)
  local query = vim.treesitter.query.parse('aspclassic', INCLUDE_QUERY)
  local out = {}
  for _, match in query:iter_matches(root_node, source) do
    local item = {}
    for id, nodes in pairs(match) do
      if type(nodes) ~= 'table' then nodes = { nodes } end
      local cap = query.captures[id]
      local node = nodes[#nodes]
      if cap == 'kind' then
        item.kind = vim.treesitter.get_node_text(node, source):lower()
      elseif cap == 'path' then
        local raw = vim.treesitter.get_node_text(node, source)
        item.path_text = raw:sub(2, -2):gsub('\\', '/')
      elseif cap == 'inc' then
        item.lnum, item.col, _, item.end_col = node:range()
      end
    end
    table.insert(out, item)
  end
  table.sort(out, function(a, b) return a.lnum < b.lnum end)
  return out
end

local function resolve_one(item, from_abs)
  local candidate
  if item.kind == 'virtual' then
    local root = virtual_root_for(from_abs)
    if not root then return nil end
    candidate = norm(root .. '/' .. item.path_text)
  else
    candidate = norm(vim.fs.dirname(from_abs) .. '/' .. item.path_text)
  end
  local stat = vim.uv.fs_stat(candidate)
  return (stat and stat.type == 'file') and candidate or nil
end

---@param abs_path string|nil ruta en disco (nil si se pasa bufnr)
---@param bufnr integer|nil buffer cuyo contenido usar en lugar del disco
---@return table[] lista {kind, path_text, resolved, lnum, col, end_col}
function M.includes_of(abs_path, bufnr)
  local ok, items = pcall(function()
    local root_node, source
    if bufnr then
      local parser = vim.treesitter.get_parser(bufnr, 'aspclassic')
      root_node = parser:parse()[1]:root()
      source = bufnr
      abs_path = norm(vim.api.nvim_buf_get_name(bufnr))
    else
      local f = io.open(abs_path, 'r')
      if not f then return {} end
      local content = f:read('*a')
      f:close()
      local parser = vim.treesitter.get_string_parser(content, 'aspclassic')
      root_node = parser:parse()[1]:root()
      source = content
    end
    local out = extract(root_node, source)
    for _, item in ipairs(out) do
      item.resolved = resolve_one(item, abs_path)
    end
    return out
  end)
  return ok and items or {}
end

-- Declaración adelantada: walk_from_disk y process_items se llaman entre sí
-- (mutua recursión al bajar por el árbol de includes).
local walk_from_disk
local process_items

-- Procesa la lista cruda de includes de UN archivo (`from_abs`), clasificando
-- cada uno en unresolved/cycle/order y, para los nuevos resueltos,
-- recorriendo su contenido en disco. Compartida por graph() y
-- buffer_graph(): ambas difieren solo en cómo obtienen los items del primer
-- nivel (disco vs. buffer); todo lo que sigue —clasificar, cortar ciclos,
-- bajar por los includes resueltos— es idéntico, así que vive aquí una
-- única vez en lugar de duplicarse en cada wrapper.
process_items = function(items, from_abs, visited, g)
  for _, item in ipairs(items) do
    if not item.resolved then
      table.insert(g.unresolved, {
        text = item.path_text,
        kind = item.kind,
        from = from_abs,
        lnum = item.lnum,
        col = item.col,
        end_col = item.end_col,
      })
    elseif visited[item.resolved] then
      table.insert(g.cycles, { from = from_abs, to = item.resolved })
    else
      table.insert(g.order, item.resolved)
      walk_from_disk(item.resolved, visited, g)
    end
  end
end

-- Recorre disco puro a partir de `abs`: siempre lee `abs` del disco (vía
-- includes_of(abs, nil)) y delega en process_items. Usada para todo nivel
-- de recursión posterior al primero, tanto desde graph() como desde
-- buffer_graph() — los archivos incluidos siempre se leen de disco, nunca
-- de un buffer abierto.
walk_from_disk = function(abs, visited, g)
  visited[abs] = true
  local items = M.includes_of(abs, nil)
  process_items(items, abs, visited, g)
end

---@param abs_path string
---@return table { order, unresolved, cycles }
function M.graph(abs_path)
  abs_path = norm(abs_path)
  local g = { order = {}, unresolved = {}, cycles = {} }
  local visited = { [abs_path] = true }
  local items = M.includes_of(abs_path, nil)
  process_items(items, abs_path, visited, g)
  return g
end

---@param bufnr integer
---@return table { order, unresolved, cycles }
function M.buffer_graph(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local abs = norm(vim.api.nvim_buf_get_name(bufnr))
  local g = { order = {}, unresolved = {}, cycles = {} }
  local visited = { [abs] = true }
  local items = M.includes_of(nil, bufnr)
  process_items(items, abs, visited, g)
  return g
end

return M
