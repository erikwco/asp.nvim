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

vim.b.undo_ftplugin = (vim.b.undo_ftplugin and (vim.b.undo_ftplugin .. ' | ') or '')
  .. table.concat(undo, ' | ')
