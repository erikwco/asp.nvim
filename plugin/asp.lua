if vim.g.loaded_asp_nvim then
  return
end
vim.g.loaded_asp_nvim = true

vim.treesitter.language.register('aspclassic', 'asp')

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'asp',
  group = vim.api.nvim_create_augroup('asp_nvim', { clear = true }),
  callback = function(args)
    -- pcall: si el parser no está compilado aún, no romper la apertura
    -- del buffer; :checkhealth asp (Task 6) diagnostica el motivo.
    pcall(vim.treesitter.start, args.buf, 'aspclassic')

    pcall(function()
      require('asp.lsp').start(args.buf)
    end)

    vim.schedule(function()
      pcall(function()
        require('asp.diagnostics').refresh(args.buf)
      end)
    end)
  end,
})

-- Patrones case-insensitive (IIS no distingue mayúsculas). *.js: los `.js`
-- de <script src> que lee asp.js desde disco; .htm/.html: fuentes del
-- barrido de usos de página (asp.pages).
vim.api.nvim_create_autocmd('BufWritePost', {
  pattern = {
    '*.[aA][sS][pP]', '*.[iI][nN][cC]', '*.[hH][tT][mM]',
    '*.[hH][tT][mM][lL]', '*.[jJ][sS]',
  },
  group = vim.api.nvim_create_augroup('asp_nvim_writes', { clear = true }),
  callback = function(args)
    pcall(function()
      local path = vim.api.nvim_buf_get_name(args.buf)
      require('asp.pages').invalidate(path)
      require('asp.symbols').invalidate(path)
      require('asp.js').invalidate(path)
      if vim.bo[args.buf].filetype == 'asp' then
        require('asp.diagnostics').refresh(args.buf)
      end
    end)
  end,
})
