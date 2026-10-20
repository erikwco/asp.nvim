vim.o.shadafile = 'NONE'
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root .. '/build/plenary.nvim')
vim.opt.runtimepath:prepend(root)
-- Varios specs abren el mismo fixture (tests/fixtures/basic.asp) en
-- sucesión rápida; sin esto, la creación/eliminación de swapfiles puede
-- colisionar (E303) de forma intermitente dentro de una misma sesión
-- headless de PlenaryBustedDirectory.
vim.opt.swapfile = false
vim.cmd('runtime! plugin/plenary.vim')
vim.cmd('runtime! ftdetect/asp.lua')
vim.cmd('runtime! plugin/asp.lua')
