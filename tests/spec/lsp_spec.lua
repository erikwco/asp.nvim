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

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do
      return r.result
    end
    return nil
  end

  it('documentSymbol devuelve outline jerárquico', function()
    local syms = request('textDocument/documentSymbol', {
      textDocument = vim.lsp.util.make_text_document_params(),
    })
    assert.is_not_nil(syms)
    local by_name = {}
    for _, s in ipairs(syms) do by_name[s.name] = s end
    assert.are.equal(5, by_name['Pedido'].kind)
    assert.are.equal(12, by_name['CalcularTotal'].kind)
    assert.are.equal(13, by_name['total'].kind)
    local children = {}
    for _, c in ipairs(by_name['Pedido'].children or {}) do children[c.name] = c end
    assert.is_not_nil(children['Agregar'])
    assert.is_not_nil(children['m_total'])
    -- Task-1 fix agregó Public Property Let Total(nuevoTotal) a la fixture:
    -- la property es miembro de la clase (kind 7); su parámetro nuevoTotal
    -- tiene scope_id ≠ nil y no debe aparecer en el outline.
    assert.is_not_nil(children['Total'])
    assert.are.equal(7, children['Total'].kind)
    -- locales de función fuera del outline:
    assert.is_nil(by_name['recargo'])
    assert.is_nil(by_name['monto'])
    assert.is_nil(by_name['nuevoTotal'])
  end)
end)
