local M = {}

---Neovim 0.10 no devuelve nada al cargar y lanza si falta el parser;
---0.11+ devuelve true al cargar, o nil con un mensaje si falta.
---@param lang string
---@return boolean
function M.add(lang)
  local ok, added = pcall(vim.treesitter.language.add, lang)
  return ok and (added == true or vim.fn.has('nvim-0.11') == 0)
end

return M
