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

  it('da kind Property a la property y kind Variable a su parámetro', function()
    local entries = require('asp.symbols').collect(0)
    local pedido = by_name(entries, 'Pedido')[1]

    -- 'total' colisiona case-insensitively con la property 'Total' de la
    -- clase; el Dim de página sigue siendo distinguible por class_id nil.
    local page_total = by_name(entries, 'total')[1]
    assert.is_nil(page_total.class_id)
    assert.are.equal(13, page_total.kind)

    local property
    for _, e in ipairs(by_name(entries, 'Total')) do
      if e.class_id == pedido.decl_id then property = e end
    end
    assert.is_not_nil(property)
    assert.are.equal(7, property.kind) -- Property, no Variable
    assert.are.equal(pedido.decl_id, property.class_id)

    local nuevo_total = by_name(entries, 'nuevoTotal')[1]
    assert.is_not_nil(nuevo_total)
    assert.are.equal(13, nuevo_total.kind) -- Variable, no Property
    assert.are.equal(property.decl_id, nuevo_total.scope_id)
  end)

  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

  it('collect_file extrae símbolos de un archivo en disco', function()
    local entries = require('asp.symbols').collect_file(FIX .. '/includes/helpers.asp')
    local names = {}
    for _, e in ipairs(entries) do names[e.name] = e end
    assert.are.equal(12, names['FormatearMoneda'].kind)
    assert.are.equal(12, names['RespuestaRapida'].kind)
    assert.are.equal(FIX .. '/includes/helpers.asp', names['FormatearMoneda'].file)
    assert.is_nil(names['FormatearMoneda'].scope_id)
  end)

  it('collect_file extrae consts y dims de un .inc', function()
    local entries = require('asp.symbols').collect_file(FIX .. '/includes/constantes.inc')
    local names = {}
    for _, e in ipairs(entries) do names[e.name] = e end
    assert.are.equal(14, names['IVA'].kind)
    assert.are.equal(13, names['gConexion'].kind)
  end)

  it('collect_file cachea por mtime', function()
    local symbols = require('asp.symbols')
    local path = FIX .. '/lib/db.inc'
    local a = symbols.collect_file(path)
    local b = symbols.collect_file(path)
    assert.are.equal(a, b) -- misma tabla = cache hit
    symbols.invalidate(path)
    local c = symbols.collect_file(path)
    assert.are_not.equal(a, c)
    assert.are.equal(#a, #c)
  end)
end)
