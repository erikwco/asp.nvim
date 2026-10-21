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

  it('Const con varias constantes y procedimientos sin paréntesis', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      '<%', 'Const A = 1, B = "x"', 'Sub Foo', '  Dim local', 'End Sub', 'Function Bar', '  Bar = A', 'End Function',
      'Class Caja', '  Property Get Total', '    Total = B', '  End Property', 'End Class', '%>',
    })
    local symbols = require('asp.symbols')
    local entries = symbols.collect(0)
    assert.are.equal(14, by_name(entries, 'A')[1].kind)
    assert.are.equal(14, by_name(entries, 'B')[1].kind)
    local foo = by_name(entries, 'Foo')[1]
    assert.are.equal(12, foo.kind)
    assert.are.same({}, foo.params)
    assert.are.equal('Foo()', foo.signature)
    assert.are.equal(foo.decl_id, by_name(entries, 'local')[1].scope_id)
    assert.are.equal(12, by_name(entries, 'Bar')[1].kind)
    local total = by_name(entries, 'Total')[1]
    assert.are.equal(7, total.kind)
    assert.are.equal(by_name(entries, 'Caja')[1].decl_id, total.class_id)
    -- Las dos constantes y los procedimientos van al outline.
    local names = vim.tbl_map(function(s) return s.name end, symbols.document_symbols(0))
    assert.are.same({ 'A', 'B', 'Foo', 'Bar', 'Caja' }, names)
    local def = symbols.definition(0, { line = 10, character = 12 })
    assert.are.same({ line = 1, character = 13 }, def.range.start)
  end)

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
