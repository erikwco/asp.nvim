describe('parsers', function()
  it('carga el parser aspclassic', function()
    assert.is_true(require('asp.ts').add('aspclassic'))
  end)

  it('carga el parser html', function()
    assert.is_true(require('asp.ts').add('html'))
  end)

  it('carga el parser vbscript', function()
    assert.is_true(require('asp.ts').add('vbscript'))
  end)
end)
