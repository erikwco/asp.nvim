describe('aceptación fase 2', function()
  it('el vbscript del fixture parsea sin errores', function()
    vim.cmd.edit('tests/fixtures/basic.asp')
    local parser = vim.treesitter.get_parser(0)
    parser:parse(true)
    local children = parser:children()
    assert.is_not_nil(children.vbscript, 'esperaba injection vbscript')
    for _, tree in ipairs(children.vbscript:trees()) do
      assert.is_false(tree:root():has_error(),
        'el VBScript inyectado tiene nodos ERROR')
    end
    vim.cmd('bwipeout!')
  end)
end)
