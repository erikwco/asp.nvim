describe('asp-ls', function()
  before_each(function()
    vim.cmd.edit('tests/fixtures/symbols.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  it('se adjunta automáticamente a buffers asp', function()
    local clients = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })
    assert.are.equal(1, #clients)
  end)

  it('negocia utf-8 y anuncia sus capacidades', function()
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    assert.are.equal('utf-8', client.offset_encoding)
    assert.is_true(client.server_capabilities.documentSymbolProvider)
    assert.is_true(client.server_capabilities.definitionProvider)
  end)
end)
