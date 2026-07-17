local M = {}

M.ns = vim.api.nvim_create_namespace('asp_includes')

---@param bufnr integer
function M.refresh(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local ok, g = pcall(require('asp.includes').buffer_graph, bufnr)
  if not ok then return end
  local diags = {}
  for _, u in ipairs(g.unresolved) do
    table.insert(diags, {
      lnum = u.lnum, col = u.col, end_col = u.end_col,
      severity = vim.diagnostic.severity.WARN,
      source = 'asp-ls',
      message = ('include %s="%s" no resuelve a ningún archivo'):format(u.kind, u.text),
    })
  end
  for _, c in ipairs(g.cycles) do
    table.insert(diags, {
      lnum = 0, col = 0,
      severity = vim.diagnostic.severity.WARN,
      source = 'asp-ls',
      message = ('ciclo de includes detectado: %s vuelve a incluir %s'):format(
        vim.fs.basename(c.from), vim.fs.basename(c.to)),
    })
  end
  vim.diagnostic.set(M.ns, bufnr, diags)
end

return M
