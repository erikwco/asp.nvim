describe('doc/asp.txt', function()
  local text = nil
  before_each(function()
    local f = io.open('doc/asp.txt', 'r')
    text = f and f:read('*a') or nil
    if f then f:close() end
  end)

  it('existe y tiene el tag principal', function()
    assert.is_not_nil(text)
    assert.is_true(text:find('*asp.nvim*', 1, true) ~= nil)
  end)

  it('documenta setup y virtual_root', function()
    assert.is_true(text:find('*asp-setup*', 1, true) ~= nil)
    assert.is_true(text:find('virtual_root', 1, true) ~= nil)
  end)

  it('documenta las capacidades LSP', function()
    for _, cap in ipairs({ 'definition', 'references', 'hover', 'completion', 'signatureHelp' }) do
      assert.is_true(text:find(cap, 1, true) ~= nil, 'falta: ' .. cap)
    end
  end)

  it('cierra cada línea dentro de 78 columnas', function()
    for ln in text:gmatch('[^\n]*') do
      assert.is_true(vim.fn.strdisplaywidth(ln) <= 78,
        'línea > 78: ' .. ln)
    end
  end)
end)
