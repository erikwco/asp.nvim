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

vim.api.nvim_create_autocmd('BufWritePost', {
  pattern = { '*.asp', '*.inc' },
  group = vim.api.nvim_create_augroup('asp_nvim_writes', { clear = true }),
  callback = function(args)
    pcall(function()
      require('asp.symbols').invalidate(vim.api.nvim_buf_get_name(args.buf))
      if vim.bo[args.buf].filetype == 'asp' then
        require('asp.diagnostics').refresh(args.buf)
      end
    end)
  end,
})
