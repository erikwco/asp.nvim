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

---Parser del buffer con la plantilla y la capa vbscript al día. Un
---parseo por rango procesa las inyecciones de la plantilla pero sólo
---parsea las capas que tocan ese rango; la vbscript, combinada en un solo
---árbol, se completa con `parse(true)`. Así no se parsean los <script> y
---<style> de toda la página.
---@param bufnr integer
---@return vim.treesitter.LanguageTree|nil parser
---@return vim.treesitter.LanguageTree|nil vbscript
function M.parse_vbscript(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'aspclassic')
  if not ok or not parser then return nil end
  parser:parse({ 0, 1 })
  local vbscript = parser:children().vbscript
  if vbscript then vbscript:parse(true) end
  return parser, vbscript
end

return M
