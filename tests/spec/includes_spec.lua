local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

describe('asp.includes', function()
  local includes = nil

  before_each(function()
    includes = require('asp.includes')
  end)

  it('resuelve el grafo completo de default.asp en orden DFS', function()
    local g = includes.graph(FIX .. '/default.asp')
    assert.are.same({
      FIX .. '/includes/helpers.asp',
      FIX .. '/includes/constantes.inc',
      FIX .. '/lib/db.inc',
    }, g.order)
    assert.are.same({}, g.unresolved)
    assert.are.same({}, g.cycles)
  end)

  it('reporta includes irresolubles con posición', function()
    local g = includes.graph(FIX .. '/roto.asp')
    assert.are.same({}, g.order)
    assert.are.equal(2, #g.unresolved)
    assert.are.equal('no_existe.inc', g.unresolved[1].text)
    assert.are.equal('file', g.unresolved[1].kind)
    assert.are.equal(0, g.unresolved[1].lnum)
    assert.are.equal('virtual', g.unresolved[2].kind)
    assert.are.equal(1, g.unresolved[2].lnum)
  end)

  it('corta y reporta ciclos sin colgarse', function()
    local g = includes.graph(FIX .. '/ciclo_a.asp')
    assert.are.same({ FIX .. '/ciclo_b.asp' }, g.order)
    assert.are.equal(1, #g.cycles)
    assert.are.equal(FIX .. '/ciclo_b.asp', g.cycles[1].from)
    assert.are.equal(FIX .. '/ciclo_a.asp', g.cycles[1].to)
  end)

  it('buffer_graph usa el contenido del buffer para el archivo inicial', function()
    vim.cmd.edit(FIX .. '/default.asp')
    local g = includes.buffer_graph(0)
    assert.are.equal(3, #g.order)
    vim.cmd('bwipeout!')
  end)
end)
