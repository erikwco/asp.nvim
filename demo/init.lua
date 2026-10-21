-- Config mínima y autocontenida para grabar las demos con vhs.
-- Carga asp.nvim desde este repo (no desde tu instalación) para que los
-- GIFs sean reproducibles. Los parsers html/javascript/css se toman de tu
-- nvim-treesitter si están instalados.
--
-- Uso (lo hacen los .tape):  nvim -u demo/init.lua demo/app/default.asp

local repo = vim.fn.fnamemodify(vim.fn.expand('<sfile>:p'), ':h:h')
vim.opt.runtimepath:prepend(repo)
vim.o.shadafile = 'NONE'

-- Añadir el directorio con los parsers html/javascript/css del usuario.
local data = vim.fn.stdpath('data')
for _, so in ipairs(vim.fn.globpath(data, '**/parser/html.so', false, true)) do
  vim.opt.runtimepath:append(vim.fn.fnamemodify(so, ':h:h'))
  break
end

-- Colorscheme: catppuccin si está instalado; si no, un tema oscuro nativo.
for _, dir in ipairs(vim.fn.globpath(data, '**/catppuccin*', false, true)) do
  if vim.fn.isdirectory(dir) == 1 then
    vim.opt.runtimepath:append(dir)
    break
  end
end
pcall(function()
  vim.o.background = 'dark'
  if not pcall(vim.cmd.colorscheme, 'catppuccin-mocha') then
    vim.cmd.colorscheme('habamax')
  end
end)

vim.o.swapfile = false -- sin prompt de swap que se coma los keystrokes en las demos
vim.o.number = true
vim.o.signcolumn = 'yes'
vim.o.laststatus = 0
vim.o.statusline = "%{fnamemodify(bufname('%'), ':.')}%m%=%l:%c"
vim.o.cmdheight = 1
vim.o.mouse = ''
if vim.fn.exists('+winborder') == 1 then
  vim.o.winborder = 'rounded'
else
  vim.lsp.handlers['textDocument/hover'] = vim.lsp.with(
    vim.lsp.handlers['textDocument/hover'], { border = 'rounded' }
  )
end

require('asp').setup({ virtual_root = repo .. '/demo/app' })

-- Neovim 0.11+ no muestra el texto virtual de los diagnósticos por defecto.
vim.diagnostic.config({
  virtual_text = { spacing = 2 },
  severity_sort = true,
  float = { border = 'rounded', source = true },
})

-- Atajos LSP para las demos (equivalentes a los de LazyVim).
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local o = { buffer = args.buf, silent = true }
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, o)
    vim.keymap.set('n', 'K', vim.lsp.buf.hover, o)
    vim.keymap.set('n', 'grr', vim.lsp.buf.references, o)
  end,
})

vim.o.completeopt = 'menu,menuone,noselect'
