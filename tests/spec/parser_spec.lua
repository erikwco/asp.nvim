describe('parsers', function()
  -- vim.treesitter.language.add() no lanza error si el parser falta: retorna
  -- nil + mensaje. Se envuelve en assert() para que pcall() sí detecte el
  -- fallo (pcall solo captura errores, no valores nil de retorno).
  it('carga el parser aspclassic', function()
    assert.is_true((pcall(function() return assert(vim.treesitter.language.add('aspclassic')) end)))
  end)

  it('carga el parser html', function()
    assert.is_true((pcall(function() return assert(vim.treesitter.language.add('html')) end)))
  end)

  it('carga el parser vbscript', function()
    local ok, added = pcall(vim.treesitter.language.add, 'vbscript')
    assert.is_true(ok and added == true)
  end)
end)
