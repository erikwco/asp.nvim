local M = {}

M.options = {}

--- Configura asp.nvim: virtual_root, diagnostics, folds e indent (ver
--- :help asp-setup). folds e indent los lee el ftplugin al cargar cada
--- buffer.
---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.options, opts or {})
end

return M
