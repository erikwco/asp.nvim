if vim.b.did_asp_ftplugin then return end
vim.b.did_asp_ftplugin = true

local undo = { 'unlet! b:did_asp_ftplugin' }

if vim.bo.includeexpr == '' then
  vim.bo.includeexpr = "v:lua.require'asp.pages'.includeexpr(v:fname)"
  undo[#undo + 1] = 'setlocal includeexpr<'
end

local options = require('asp').options

-- Plegado por tree-sitter. foldmethod y foldlevel los decide el usuario
-- (`setlocal foldmethod=expr`).
if options.folds ~= false then
  vim.wo[0][0].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
  undo[#undo + 1] = 'setlocal foldexpr<'
end

-- VBScript es insensible a mayúsculas: `=~` reindenta sin distinguirlas.
-- `<>>` reindenta al cerrar una etiqueta, como indent/html.vim: con `0=</`
-- se reindentaría antes de escribir el nombre de la etiqueta.
if options.indent ~= false then
  vim.bo.indentexpr = "v:lua.require'asp.indent'.indentexpr()"
  vim.bo.indentkeys = '!^F,o,O,<>>,0=~end,0=~else,0=~elseif,0=~case,0=~next,0=~loop,0=~wend,0=%>'
  undo[#undo + 1] = 'setlocal indentexpr< indentkeys<'
end

vim.b.undo_ftplugin = (vim.b.undo_ftplugin and (vim.b.undo_ftplugin .. ' | ') or '')
  .. table.concat(undo, ' | ')
