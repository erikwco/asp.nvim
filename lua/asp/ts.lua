local M = {}

---Neovim 0.10 no devuelve nada al cargar y lanza si falta el parser;
---0.11+ devuelve true al cargar, o nil con un mensaje si falta.
---@param lang string
---@return boolean
---@return string? error
function M.add(lang)
  local ok, added, err = pcall(vim.treesitter.language.add, lang)
  if not ok then return false, added end
  if added == true or vim.fn.has('nvim-0.11') == 0 then return true end
  return false, err
end

return M
