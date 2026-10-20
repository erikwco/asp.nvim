if vim.bo.includeexpr ~= '' then return end

vim.bo.includeexpr = "v:lua.require'asp.pages'.includeexpr(v:fname)"
vim.b.undo_ftplugin = (vim.b.undo_ftplugin and (vim.b.undo_ftplugin .. ' | ') or '')
  .. 'setlocal includeexpr<'
