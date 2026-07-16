if vim.g.loaded_asp_nvim then
  return
end
vim.g.loaded_asp_nvim = true

vim.filetype.add({
  extension = {
    asp = 'asp',
    inc = 'asp',
  },
})

vim.treesitter.language.register('aspclassic', 'asp')

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'asp',
  group = vim.api.nvim_create_augroup('asp_nvim', { clear = true }),
  callback = function(args)
    -- pcall: si el parser no está compilado aún, no romper la apertura
    -- del buffer; :checkhealth asp (Task 6) diagnostica el motivo.
    pcall(vim.treesitter.start, args.buf, 'aspclassic')
  end,
})
