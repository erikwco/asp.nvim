describe('catálogos de ayuda VBScript y COM', function()
  local native = require('asp.vbscript_builtins')
  local com = require('asp.com')

  it('conserva los grupos y expone firmas, parámetros y retornos', function()
    for _, entry in ipairs(native.groups.functions) do
      local info = native.lookup(entry[1]:upper())
      assert.are.equal('functions', info.group)
      assert.is_true(#info.signature > 0)
      assert.is_true(#info.doc > 0)
      assert.is_true(#info.returns > 0)
      for _, param in ipairs(info.params) do
        assert.is_true(#param.name > 0)
        assert.are.equal('boolean', type(param.optional))
        assert.is_true(#param.doc > 0, info.name .. '.' .. param.name)
      end
    end
    assert.is_true(native.is_class('regexp'))
    assert.are.equal('keywords', native.lookup('SUB').group)
    assert.are.equal('objects', native.lookup('Err').group)
  end)

  it('describe parámetros opcionales al principio y al final', function()
    local mid = native.lookup('Mid')
    assert.are.equal('Mid(string, start[, length])', mid.signature)
    assert.is_false(mid.params[2].optional)
    assert.is_true(mid.params[3].optional)
    local instr = native.lookup('InStr')
    assert.is_true(instr.params[1].optional)
    assert.is_false(instr.params[2].optional)
    assert.is_false(instr.params[3].optional)
    assert.is_true(instr.params[4].optional)
    assert.are.equal(0, #native.lookup('Now').params)
  end)

  it('expone valores y documentación de todas las constantes', function()
    for _, entry in ipairs(native.groups.constants) do
      local info = native.lookup(entry[1])
      assert.are.equal('constants', info.group)
      assert.is_true(#info.value > 0)
      assert.is_true(#info.doc > 0)
    end
    assert.are.equal('Chr(13) & Chr(10)', native.lookup('vbcrlf').value)
    assert.are.equal('1', native.lookup('vbTextCompare').value)
  end)

  it('resuelve ProgIDs y variantes de versión sin distinguir mayúsculas', function()
    assert.are.equal('Recordset', com.from_progid('aDoDb.Recordset.6.0').id)
    assert.are.equal('FileSystemObject', com.from_progid('Scripting.FileSystemObject').id)
    assert.are.equal('DOMDocument', com.from_progid('MSXML2.DOMDocument.6.0').id)
    assert.are.equal('XMLHTTP', com.from_progid('Microsoft.XMLHTTP').id)
    assert.is_nil(com.from_progid('Recordset'))
    assert.is_nil(com.from_progid('No.Existe'))
  end)

  it('documenta miembros y conserva los retornos de objetos derivados', function()
    for _, obj in pairs(com.types) do
      assert.is_true(#obj.doc > 0)
      for _, member in ipairs(obj.members) do
        assert.is_true(#member.signature > 0)
        assert.is_true(#member.doc > 0)
        assert.is_true(member.kind == 'method' or member.kind == 'property')
      end
    end
    assert.are.equal('Recordset', com.member('Connection', 'EXECUTE').returns)
    assert.are.equal('TextStream', com.member('FileSystemObject', 'OpenTextFile').returns)
    assert.are.equal('Matches', com.member('RegExp', 'Execute').returns)
    assert.are.equal('Match', com.member('Matches', 'Item').returns)
  end)
end)
