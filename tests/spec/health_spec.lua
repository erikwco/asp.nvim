describe('modulo asp', function()
  it('setup() no explota sin opciones', function()
    assert.is_true((pcall(require('asp').setup)))
  end)

  it('health.check existe', function()
    assert.is_function(require('asp.health').check)
  end)
end)
