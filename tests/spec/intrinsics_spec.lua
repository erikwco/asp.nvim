describe('asp.intrinsics', function()
  local I = nil
  before_each(function() I = require('asp.intrinsics') end)

  it('resuelve objetos case-insensitive', function()
    assert.are.equal('Response', I.object('response').name)
    assert.are.equal('Server', I.object('SERVER').name)
    assert.is_nil(I.object('NoExiste'))
  end)

  it('cada objeto tiene doc no vacío', function()
    for _, name in ipairs(I.object_names()) do
      assert.is_true(#I.object(name).doc > 0, 'sin doc: ' .. name)
    end
  end)

  it('resuelve miembros case-insensitive con firma y doc', function()
    local m = I.member('Response', 'write')
    assert.are.equal('Write', m.name)
    assert.is_true(m.signature:find('Write') ~= nil)
    assert.is_true(#m.doc > 0)
    assert.is_nil(I.member('Response', 'NoExiste'))
  end)

  it('expone los 5 objetos del spec', function()
    local names = I.object_names()
    table.sort(names)
    assert.are.same(
      { 'Application', 'Request', 'Response', 'Server', 'Session' }, names)
  end)

  it('members_of devuelve la lista o vacío', function()
    assert.is_true(#I.members_of('Server') >= 3)
    assert.are.same({}, I.members_of('NoExiste'))
  end)
end)
