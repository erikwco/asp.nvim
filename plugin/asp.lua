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
