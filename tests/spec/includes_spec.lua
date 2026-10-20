local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

-- Crea `files` (nombre → líneas) en un directorio temporal fuera del repo y
-- corre fn(dir); siempre borra el directorio.
local function in_temp(files, fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  dir = vim.uv.fs_realpath(dir)
  for name, lines in pairs(files) do
    vim.fn.mkdir(vim.fs.dirname(dir .. '/' .. name), 'p')
    vim.fn.writefile(lines, dir .. '/' .. name)
  end
  local ok, err = pcall(fn, dir)
  vim.fn.delete(dir, 'rf')
  assert(ok, err)
end

-- Corre fn() contando los io.open; devuelve el resultado y la cuenta.
local function counting_opens(fn)
  local open, opens = io.open, 0
  io.open = function(...)
    opens = opens + 1
    return open(...)
  end
  local ok, res = pcall(fn)
  io.open = open
  assert(ok, res)
  return res, opens
end

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

  it('dedupea en silencio un diamante (include compartido por dos ramas)', function()
    local g = includes.graph(FIX .. '/diamante.asp')
    assert.are.same({
      FIX .. '/includes/helpers.asp',
      FIX .. '/includes/constantes.inc',
    }, g.order)
    assert.are.same({}, g.unresolved)
    assert.are.same({}, g.cycles)
  end)

  it('con la caché caliente cada fixture da el mismo grafo que en frío, sin leer disco', function()
    local files = vim.fs.find(function() return true end, {
      path = FIX, type = 'file', limit = math.huge,
    })
    assert.is_true(#files > 0)
    local walked = false
    for _, file in ipairs(files) do
      for _, f in ipairs(files) do includes.invalidate(f) end
      local cold = includes.graph(file)
      includes.invalidate(file)
      local cold_items = includes.includes_of(file)
      local warm, opens = counting_opens(function() return includes.graph(file) end)
      assert.are.same(cold, warm, file)
      assert.are.equal(0, opens, file)
      assert.are.same(cold_items, includes.includes_of(file), file)
      walked = walked or #cold.order > 0
    end
    assert.is_true(walked)
  end)

  it('la caché se valida por mtime y tamaño, y invalidate la adelanta', function()
    in_temp({ ['b.inc'] = {}, ['c.inc'] = {}, ['cc.inc'] = {} }, function(dir)
      local page = dir .. '/a.asp'
      local function write(text, mtime)
        vim.fn.writefile({ text }, page)
        assert(vim.uv.fs_utime(page, mtime, mtime))
      end
      local function order()
        return vim.tbl_map(vim.fs.basename, includes.graph(page).order)
      end

      write('<!--#include file="b.inc" -->', 1e9)
      assert.are.same({ 'b.inc' }, order())
      -- Mismo mtime y mismo tamaño: la caché no ve el cambio. Para eso
      -- BufWritePost llama a invalidate.
      write('<!--#include file="c.inc" -->', 1e9)
      assert.are.same({ 'b.inc' }, order())
      includes.invalidate(page)
      assert.are.same({ 'c.inc' }, order())
      -- Otro mtime con el mismo tamaño.
      write('<!--#include file="b.inc" -->', 1e9 + 5)
      assert.are.same({ 'b.inc' }, order())
      -- Otro tamaño con el mismo mtime.
      write('<!--#include file="cc.inc" -->', 1e9 + 5)
      assert.are.same({ 'cc.inc' }, order())
    end)
  end)

  it('la resolución no se cachea: un destino o una raíz virtual nuevos resuelven sin invalidar', function()
    in_temp({
      ['a.asp'] = { '<!--#include file="nuevo.inc" -->' },
      ['sitio/sub/b.asp'] = { '<!--#include virtual="/inc/x.inc" -->' },
      ['sitio/inc/x.inc'] = {},
    }, function(dir)
      local g = includes.graph(dir .. '/a.asp')
      assert.are.same({}, g.order)
      assert.are.equal('nuevo.inc', g.unresolved[1].text)
      vim.fn.writefile({}, dir .. '/nuevo.inc')
      g = includes.graph(dir .. '/a.asp')
      assert.are.same({ dir .. '/nuevo.inc' }, g.order)
      assert.are.same({}, g.unresolved)

      -- Sin web.config ni .git hacia arriba, virtual= no resuelve; al
      -- aparecer el web.config, sí.
      local previous = require('asp').options.virtual_root
      require('asp').options.virtual_root = nil
      local ok, err = pcall(function()
        assert.are.same({}, includes.graph(dir .. '/sitio/sub/b.asp').order)
        vim.fn.writefile({}, dir .. '/sitio/web.config')
        assert.are.same({ dir .. '/sitio/inc/x.inc' }, includes.graph(dir .. '/sitio/sub/b.asp').order)
      end)
      require('asp').options.virtual_root = previous
      assert(ok, err)
    end)
  end)

  it('un archivo borrado sale del grafo y de la caché', function()
    in_temp({
      ['a.asp'] = { '<!--#include file="b.inc" -->' },
      ['b.inc'] = { '<!--#include file="c.inc" -->' },
      ['c.inc'] = {},
    }, function(dir)
      local function cached(name)
        return vim.tbl_contains(includes._cached_files(), dir .. '/' .. name)
      end
      assert.are.same({ dir .. '/b.inc', dir .. '/c.inc' }, includes.graph(dir .. '/a.asp').order)
      assert.is_true(cached('b.inc'))

      os.remove(dir .. '/b.inc')
      local g = includes.graph(dir .. '/a.asp')
      assert.are.same({}, g.order)
      assert.are.equal('b.inc', g.unresolved[1].text)
      assert.is_false(cached('b.inc'))

      -- También el archivo de partida de una consulta.
      assert.is_true(cached('a.asp'))
      os.remove(dir .. '/a.asp')
      assert.are.same({}, includes.graph(dir .. '/a.asp').order)
      assert.is_false(cached('a.asp'))
    end)
  end)

  it('la caché tiene tope LRU, salvo para la consulta en curso', function()
    local max = includes._FILE_CACHE_MAX
    local files, page = { ['otra.inc'] = {} }, {}
    for i = 1, max + 1 do
      files['f' .. i .. '.inc'] = {}
      table.insert(page, ('<!--#include file="f%d.inc" -->'):format(i))
    end
    files['grande.asp'] = page
    in_temp(files, function(dir)
      local function cached(name)
        return vim.tbl_contains(includes._cached_files(), dir .. '/' .. name)
      end
      local function touch(name) includes.includes_of(dir .. '/' .. name) end

      for i = 1, max do touch('f' .. i .. '.inc') end -- lo de antes sale
      assert.are.equal(max, #includes._cached_files())
      touch('f1.inc') -- f1 pasa a ser la más reciente
      touch(('f%d.inc'):format(max + 1)) -- sale la usada hace más tiempo: f2
      assert.are.equal(max, #includes._cached_files())
      assert.is_true(cached('f1.inc'))
      assert.is_false(cached('f2.inc'))
      assert.is_true(cached(('f%d.inc'):format(max + 1)))

      -- Un grafo de más de `max` archivos conserva todos los suyos: la
      -- consulta siguiente no lee nada.
      local g = includes.graph(dir .. '/grande.asp')
      assert.are.equal(max + 1, #g.order)
      assert.are.equal(max + 2, #includes._cached_files())
      local again, opens = counting_opens(function() return includes.graph(dir .. '/grande.asp') end)
      assert.are.same(g, again)
      assert.are.equal(0, opens)
      -- La consulta siguiente vuelve al tope.
      touch('otra.inc')
      assert.are.equal(max, #includes._cached_files())
      assert.is_true(cached('otra.inc'))
    end)
  end)

  it('escribir un include desde Neovim llama a includes.invalidate', function()
    local path = vim.fn.tempname() .. '.inc'
    local seen
    local invalidate = includes.invalidate
    includes.invalidate = function(p)
      seen = p
      return invalidate(p)
    end
    local ok, err = pcall(function()
      vim.cmd.edit(path)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '<% Dim x %>' })
      vim.cmd('silent write')
    end)
    includes.invalidate = invalidate
    vim.cmd('bwipeout!')
    vim.fn.delete(path)
    assert.is_true(ok, err)
    assert.is_not_nil(seen)
    assert.are.equal(vim.fn.resolve(path), vim.fn.resolve(seen))
  end)
end)
