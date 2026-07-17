describe('asp.symbols', function()
  before_each(function()
    vim.cmd.edit('tests/fixtures/symbols.asp')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function by_name(entries, name)
    local hits = {}
    for _, e in ipairs(entries) do
      if e.name:lower() == name:lower() then table.insert(hits, e) end
    end
    return hits
  end

  it('extrae subs, functions, class, dims y consts con su kind', function()
    local entries = require('asp.symbols').collect(0)
    assert.are.equal(5, by_name(entries, 'Pedido')[1].kind)          -- Class
    assert.are.equal(12, by_name(entries, 'CalcularTotal')[1].kind)  -- Function
    assert.are.equal(12, by_name(entries, 'Mostrar')[1].kind)        -- Function
    assert.are.equal(13, by_name(entries, 'total')[1].kind)          -- Variable
    assert.are.equal(14, by_name(entries, 'IVA')[1].kind)            -- Constant
  end)

  it('registra scopes: recargo es local a CalcularTotal, total es de página', function()
    local entries = require('asp.symbols').collect(0)
    local recargo = by_name(entries, 'recargo')[1]
    local total = by_name(entries, 'total')[1]
    local fn = by_name(entries, 'CalcularTotal')[1]
    assert.is_not_nil(recargo.scope_id)
    assert.are.equal(fn.decl_id, recargo.scope_id)
    assert.is_nil(total.scope_id)
  end)

  it('registra membresía de clase y parámetros', function()
    local entries = require('asp.symbols').collect(0)
    local agregar = by_name(entries, 'Agregar')[1]
    local pedido = by_name(entries, 'Pedido')[1]
    local monto = by_name(entries, 'monto')[1]
    assert.are.equal(pedido.decl_id, agregar.class_id)
    assert.are.equal(agregar.decl_id, monto.scope_id)
    assert.are.equal(13, monto.kind)
  end)
end)
