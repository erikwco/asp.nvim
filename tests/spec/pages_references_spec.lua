local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')
local SOURCE = FIX .. '/paginas/inicio.asp'
local TARGET = FIX .. '/paginas/otra.asp'
local pages = require('asp.pages')

local function location(path, row, col, end_row, end_col)
  return {
    uri = vim.uri_from_fname(path),
    range = {
      start = { line = row, character = col },
      ['end'] = { line = end_row, character = end_col },
    },
  }
end

local function on_line(path, row, text)
  local line = vim.fn.readfile(path)[row + 1]
  local col = assert(line:find(text, 1, true)) - 1
  return location(path, row, col, row, col + #text)
end

local function refs_to(path)
  vim.cmd.edit(path)
  return pages.references(0, { line = 0, character = 0 })
end

local function from_file(refs, path)
  local out = {}
  for _, ref in ipairs(refs or {}) do
    if ref.uri == vim.uri_from_fname(path) then table.insert(out, ref) end
  end
  return out
end

describe('asp.pages references', function()
  local temp, buffers, original_root, original_open, original_parser
  local serial = 0

  before_each(function()
    serial = serial + 1
    temp = FIX .. '/paginas/refs-' .. vim.uv.os_getpid() .. '-' .. serial
    buffers = vim.api.nvim_list_bufs()
    original_root = require('asp').options.virtual_root
    original_open = io.open
    original_parser = vim.treesitter.get_string_parser
  end)

  after_each(function()
    io.open = original_open
    vim.treesitter.get_string_parser = original_parser
    require('asp').options.virtual_root = original_root
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not vim.tbl_contains(buffers, buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.fn.delete(temp, 'rf')
  end)

  local function write(name, lines)
    local path = temp .. '/' .. name
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile(lines, path)
    return path
  end

  local function site()
    write('web.config', {})
    return write('destino.asp', { '<p>Destino</p>' })
  end

  it('encuentra literales, sufijos y comillas duplicadas con rangos UTF-8', function()
    local refs = refs_to(TARGET)
    assert.are.same({
      on_line(SOURCE, 0, 'otra.asp'),
      on_line(SOURCE, 1, 'otra.asp'),
      on_line(SOURCE, 2, 'otra.asp?id=1#detalle'),
      on_line(SOURCE, 5, 'otra.asp'),
      on_line(SOURCE, 8, 'otra.asp?id='),
      on_line(SOURCE, 11, 'otra.asp'),
    }, from_file(refs, SOURCE))
    local written = FIX .. '/paginas/escrita.asp'
    assert.are.same({ on_line(written, 0, 'otra.asp') }, from_file(refs, written))

    local target = site()
    local source = write('origen.asp', { [[<a title="á😀" onclick="location.href='destino.asp'">Ir</a>]] })
    assert.are.same({ on_line(source, 0, 'destino.asp') }, refs_to(target))
  end)

  it('elige el literal bajo el cursor o el archivo propio en asp e inc', function()
    local expected = refs_to(TARGET)
    vim.cmd.edit(SOURCE)
    assert.are.same(expected, pages.references(0, on_line(SOURCE, 0, 'otra.asp').range.start))

    local target = site()
    local source = write('origen.inc', { [[<a href="destino.asp">Ir</a>]] })
    local caller = write('llamada.html', { [[<a href="origen.inc">Ir</a>]] })
    assert.are.same({ on_line(source, 0, 'destino.asp') }, refs_to(target))
    assert.are.same({ on_line(caller, 0, 'origen.inc') }, refs_to(source))
    assert.are.same({ on_line(source, 0, 'destino.asp') },
      pages.references(0, on_line(source, 0, 'destino.asp').range.start))
  end)

  it('devuelve nil sin usos, sin raíz, con literal irresoluble o entrada inválida', function()
    local target = site()
    assert.is_nil(refs_to(target))
    assert.is_nil(refs_to(write('pagina.html', { '<p>Sin literal</p>' })))
    local source = write('origen.asp', { [[<a href="ausente.asp">Ir</a>]] })
    write('llamada.js', { [[const url = 'origen.asp';]] })
    vim.cmd.edit(source)
    assert.is_nil(pages.references(0, on_line(source, 0, 'ausente.asp').range.start))
    assert.is_nil(pages.references(-1, { line = 0, character = 0 }))
    assert.is_nil(pages.references(0, nil))
    assert.is_nil(pages.references(0, { line = 999, character = 0 }))
    vim.cmd.enew()
    assert.is_nil(pages.references(0, { line = 0, character = 0 }))
  end)

  it('coincide con los includes invertidos del fixture y conserva sus rangos', function()
    local target = FIX .. '/includes/helpers.asp'
    local refs = refs_to(target)
    for _, name in ipairs({ 'default.asp', 'diamante.asp', 'roto.asp', 'includes/helpers.asp' }) do
      local source, expected = FIX .. '/' .. name, {}
      for _, inc in ipairs(require('asp.includes').includes_of(source)) do
        if inc.resolved == target then
          table.insert(expected, location(source, inc.lnum, inc.col, inc.lnum, inc.end_col))
        end
      end
      assert.are.same(expected, from_file(refs, source), name)
    end
    assert.are.same({ on_line(SOURCE, 3, '/includes/helpers.asp') }, from_file(refs, SOURCE))
  end)

  it('resuelve file y virtual sin barra, con espacios y en varias líneas sin parsers', function()
    local target = site()
    local source = write('sub/includes.asp', {
      [[<!--#include file="../destino.asp" -->]],
      [[<!--#include virtual='destino.asp' -->]],
      [[<!--#include virtual = "/destino.asp" -->]],
      '<!--#include', [[ virtual="destino.asp" -->]],
      [[<% Response.Write "<!--#include virtual='destino.asp' -->" %>]],
    })
    local expected = {}
    for _, inc in ipairs(require('asp.includes').includes_of(source)) do
      assert.are.equal(target, inc.resolved)
      local end_row = inc.lnum == 3 and 4 or inc.lnum
      table.insert(expected, location(source, inc.lnum, inc.col, end_row, inc.end_col))
    end
    assert.are.equal(4, #expected)
    vim.treesitter.get_string_parser = function() error('no debe parsear') end
    assert.are.same(expected, refs_to(target))
  end)

  it('recorre las cinco extensiones y omite directorios ocultos, build y node_modules', function()
    local target = site()
    local expected = {}
    for _, name in ipairs({ 'a.asp', 'b.inc', 'c.htm', 'd.HTML', 'sub/e.js' }) do
      local source = write(name, { [[<a href="/destino.asp">Ir</a>]] })
      table.insert(expected, on_line(source, 0, '/destino.asp'))
    end
    for _, dir in ipairs({ '.git', '.oculto', 'node_modules', 'build', 'sub/.cache', 'sub/build' }) do
      write(dir .. '/ignorado.asp', { [[<a href="/destino.asp">Ir</a>]] })
    end
    write('ignorado.css', { [[url('/destino.asp')]] })
    write('ignorado.txt', { [["/destino.asp"]] })
    assert.are.same(expected, refs_to(target))
  end)

  it('descarta URLs externas y usa el directorio de cada fuente para rutas relativas', function()
    local target = site()
    write('sub/destino.asp', { '<p>Otro destino</p>' })
    write('sub/local.js', { [[const url = 'destino.asp';]] })
    local source = write('sub/enlace.js', {
      [[const a = '../destino.asp?q=1#x';]],
      [[const b = '/destino.asp';]],
      [[const c = "http://example.com/destino.asp"; const d = '//example.com/destino.asp';]],
      [[const e = "https://example.com/destino.asp"; const f = 'mailto:destino.asp';]],
      [[const g = 'javascript:destino.asp'; const h = 'pagina_' + id + '.asp';]],
    })
    assert.are.same({
      on_line(source, 0, '../destino.asp?q=1#x'), on_line(source, 1, '/destino.asp'),
    }, refs_to(target))
  end)

  it('relee solo el archivo cuyo mtime cambió y detecta altas y bajas', function()
    local target = site()
    local source = write('origen.htm', { [[<a href="destino.asp">Ir</a>]] })
    local reads = {}
    io.open = function(path, mode)
      if path:sub(1, #temp + 1) == temp .. '/' and mode == 'r' then
        reads[path] = (reads[path] or 0) + 1
      end
      return original_open(path, mode)
    end
    local expected = { on_line(source, 0, 'destino.asp') }
    assert.are.same(expected, refs_to(target))
    assert.are.same(expected, pages.references(0, { line = 0, character = 0 }))
    assert.are.equal(1, reads[source])
    assert.are.equal(1, reads[target])
    local stat = assert(vim.uv.fs_stat(source))
    write('origen.htm', { '<p>Enlace quitado</p>' })
    assert(vim.uv.fs_utime(source, stat.atime.sec, stat.mtime.sec + 2))
    assert.is_nil(pages.references(0, { line = 0, character = 0 }))
    assert.are.equal(2, reads[source])
    assert.are.equal(1, reads[target])
    local added = write('nuevo.html', { [[<a href="destino.asp">Ir</a>]] })
    assert.are.same({ on_line(added, 0, 'destino.asp') }, pages.references(0, { line = 0, character = 0 }))
    vim.fn.delete(added)
    assert.is_nil(pages.references(0, { line = 0, character = 0 }))
  end)

  it('BufWritePost invalida también html y js aunque se conserve el mtime', function()
    local target = site()
    local sources = {}
    for i, ext in ipairs({ 'asp', 'inc', 'htm', 'html', 'js', 'HTML' }) do
      local source = write('origen-' .. i .. '.' .. ext, { [["destino.asp"]] })
      assert(vim.uv.fs_utime(source, 1700000000, 1700000000))
      table.insert(sources, source)
    end
    local initial = refs_to(target)
    for _, source in ipairs(sources) do
      assert.are.same({ on_line(source, 0, 'destino.asp') }, from_file(initial, source))
    end
    for _, source in ipairs(sources) do
      local stat = assert(vim.uv.fs_stat(source))
      vim.cmd.edit(source)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '<p>Sin enlace</p>' })
      vim.cmd.write()
      assert(vim.uv.fs_utime(source, stat.atime.sec, stat.mtime.sec + stat.mtime.nsec / 1e9))
      assert.are.same(stat.mtime, vim.uv.fs_stat(source).mtime)
      assert.are.same({}, from_file(refs_to(target), source))
    end
  end)

  it('recalcula las rutas virtuales al cambiar virtual_root', function()
    local target = site()
    local source = write('otro/enlace.asp', { [[<a href="/destino.asp">Ir</a>]] })
    assert.are.same({ on_line(source, 0, '/destino.asp') }, refs_to(target))
    local new_root = temp .. '/otro'
    write('otro/destino.asp', { '<p>Otro destino</p>' })
    require('asp').options.virtual_root = new_root
    assert.is_nil(pages.references(0, { line = 0, character = 0 }))
    require('asp').options.virtual_root = temp
    assert.are.same({ on_line(source, 0, '/destino.asp') }, pages.references(0, { line = 0, character = 0 }))
  end)

  it('el handler LSP devuelve referencias de página y una lista vacía sin usos', function()
    local expected = refs_to(TARGET)
    vim.cmd.edit(SOURCE)
    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end))
    local function request(pos)
      local response = vim.lsp.buf_request_sync(0, 'textDocument/references', {
        textDocument = vim.lsp.util.make_text_document_params(),
        position = pos,
        context = { includeDeclaration = false },
      }, 3000)
      local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
      assert.is_not_nil(response)
      assert.is_nil(response[client.id].err)
      return response[client.id].result
    end
    assert.are.same(expected, request(on_line(SOURCE, 0, 'otra.asp').range.start))
    vim.cmd.edit(TARGET)
    assert.are.same(expected, request({ line = 0, character = 0 }))
    vim.cmd.edit(SOURCE)
    assert.are.same({}, request(on_line(SOURCE, 10, 'inexistente.asp').range.start))
  end)
end)
