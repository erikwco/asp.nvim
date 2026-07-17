local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

describe('diagnósticos de includes', function()
  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function diags_for(file)
    vim.cmd.edit(FIX .. '/' .. file)
    require('asp.diagnostics').refresh(0)
    return vim.diagnostic.get(0, { namespace = require('asp.diagnostics').ns })
  end

  it('marca includes irresolubles con WARN en su línea', function()
    local ds = diags_for('roto.asp')
    assert.are.equal(2, #ds)
    assert.are.equal(vim.diagnostic.severity.WARN, ds[1].severity)
    assert.are.equal(0, ds[1].lnum)
    assert.are.equal(1, ds[2].lnum)
    assert.is_truthy(ds[1].message:find('no_existe%.inc'))
  end)

  it('reporta ciclos con un WARN', function()
    local ds = diags_for('ciclo_a.asp')
    assert.are.equal(1, #ds)
    assert.is_truthy(ds[1].message:lower():find('ciclo'))
  end)

  it('un grafo sano no produce diagnósticos', function()
    local ds = diags_for('default.asp')
    assert.are.same({}, ds)
  end)
end)
