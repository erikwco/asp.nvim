describe('treesitter en buffers asp', function()
  before_each(function()
    vim.cmd.edit('tests/fixtures/basic.asp')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  it('arranca el parser aspclassic para el filetype asp', function()
    local ok, parser = pcall(vim.treesitter.get_parser, 0)
    assert.is_true(ok)
    assert.are.equal('aspclassic', parser:lang())
  end)

  it('inyecta html y vbscript', function()
    local parser = vim.treesitter.get_parser(0)
    parser:parse(true)
    local langs = {}
    for lang in pairs(parser:children()) do
      langs[lang] = true
    end
    assert.is_true(langs.html, 'esperaba injection html')
    assert.is_true(langs.vbscript, 'esperaba injection vbscript')
  end)

  it('las queries de aspclassic compilan', function()
    assert.is_not_nil(vim.treesitter.query.get('aspclassic', 'highlights'))
    assert.is_not_nil(vim.treesitter.query.get('aspclassic', 'injections'))
  end)
end)

describe('queries de vbscript', function()
  it('las queries de vbscript compilan', function()
    assert.is_not_nil(vim.treesitter.query.get('vbscript', 'highlights'))
  end)
end)
