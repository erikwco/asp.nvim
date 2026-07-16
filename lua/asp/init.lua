local M = {}

M.options = {}

--- Configura asp.nvim. Hoy no hay opciones; la tabla se reserva para
--- la configuración de la raíz virtual de includes (Fase 4).
---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.options, opts or {})
end

return M
