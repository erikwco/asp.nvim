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
  local original_scandir_next, original_root_for, original_notify, original_hrtime

  before_each(function()
    temp = vim.fn.tempname()
    vim.fn.mkdir(temp, 'p')
    temp = assert(vim.uv.fs_realpath(temp))
    buffers = vim.api.nvim_list_bufs()
    original_root = require('asp').options.virtual_root
    original_open = io.open
    original_parser = vim.treesitter.get_string_parser
    original_scandir_next = vim.uv.fs_scandir_next
    original_root_for = require('asp.includes').virtual_root_for
    original_notify = vim.notify
    original_hrtime = vim.uv.hrtime
  end)

  after_each(function()
    vim.uv.fs_scandir_next = original_scandir_next
    require('asp.includes').virtual_root_for = original_root_for
    vim.notify = original_notify
    vim.uv.hrtime = original_hrtime
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

  it('devuelve nil sin usos, con literal irresoluble o entrada inválida', function()
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

  it('devuelve nil para un asp sin raíz de sitio ni repositorio', function()
    local target = write('destino.asp', { '<p>Destino</p>' })
    write('origen.asp', { [["destino.asp"]] })
    assert.is_nil(pages.scan_root_for(target))
    assert.is_nil(refs_to(target))
  end)

  it('encuentra destinos creados después de cachear las fuentes', function()
    local target = site()
    local source = write('origen.asp', { [["nuevo.asp"]], [[<!--#include file="nuevo.inc"-->]] })
    assert.is_nil(refs_to(target))
    local page = write('nuevo.asp', { '<p>Nueva página</p>' })
    local include = write('nuevo.inc', { '<p>Nuevo include</p>' })
    assert.are.same({ on_line(source, 0, 'nuevo.asp') }, refs_to(page))
    assert.are.same({ on_line(source, 1, [[<!--#include file="nuevo.inc"-->]]) }, refs_to(include))
  end)

  it('respeta la sensibilidad a mayúsculas del filesystem al comparar destinos', function()
    local target = site()
    local source = write('origen.asp', {
      [[<!--#include file="Destino.asp"-->]], [["DESTINO.ASP"]], [["destino.asp"]],
    })
    local expected = { on_line(source, 2, 'destino.asp') }
    if vim.uv.fs_stat(temp .. '/DESTINO.ASP') then
      expected = {
        on_line(source, 0, [[<!--#include file="Destino.asp"-->]]),
        on_line(source, 1, 'DESTINO.ASP'), on_line(source, 2, 'destino.asp'),
      }
      vim.cmd.edit(source)
      assert.are.same(expected, pages.references(0, on_line(source, 1, 'DESTINO.ASP').range.start))
    end
    assert.are.same(expected, refs_to(target))
  end)

  it('usa rutas reales con virtual_root por symlink e invalida al guardar', function()
    local target = site()
    local source = write('origen.asp', { [["/destino.asp"]], [["destino.asp"]] })
    assert(vim.uv.fs_symlink(temp, temp .. '/alias'))
    require('asp').options.virtual_root = temp .. '/alias'
    assert(vim.uv.fs_utime(source, 1700000000, 1700000000))
    assert.are.same({ on_line(source, 0, '/destino.asp'), on_line(source, 1, 'destino.asp') }, refs_to(target))
    vim.cmd.edit(source)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { [["/ausente.asp"]], [["ausente.asp"]] })
    vim.cmd.write()
    assert(vim.uv.fs_utime(source, 1700000000, 1700000000))
    assert.is_nil(refs_to(target))
  end)

  it('recorre el web.config exterior y conserva la raíz virtual más cercana', function()
    site()
    write('admin/web.config', {})
    local panel = write('admin/panel.asp', { '<p>Panel</p>', [["/destino.asp"]] })
    local admin_target = write('admin/destino.asp', { '<p>Destino admin</p>' })
    local source = write('menu.asp', { [["admin/panel.asp"]] })
    assert.are.equal(temp .. '/admin', require('asp.includes').virtual_root_for(panel))
    assert.are.same({ on_line(source, 0, 'admin/panel.asp') }, refs_to(panel))
    assert.are.same({ on_line(panel, 1, '/destino.asp') }, refs_to(admin_target))
    require('asp').options.virtual_root = temp .. '/admin'
    assert.is_nil(refs_to(panel))
  end)

  it('usa el git más cercano cuando no hay web.config', function()
    vim.fn.mkdir(temp .. '/.git', 'p')
    local target = write('sub/destino.asp', { '<p>Destino</p>' })
    local source = write('origen.asp', { [["sub/destino.asp"]] })
    assert.are.equal(temp, pages.scan_root_for(target))
    assert.are.same({ on_line(source, 0, 'sub/destino.asp') }, refs_to(target))
  end)

  it('purga fuentes borradas aunque reaparezcan con igual mtime y tamaño', function()
    local target = site()
    local source = write('sub/origen.asp', { [["destino.asp"]] })
    write('sub/destino.asp', { '<p>Destino local</p>' })
    assert(vim.uv.fs_utime(source, 1700000000, 1700000000))
    assert.is_nil(refs_to(target))
    vim.fn.delete(temp .. '/sub', 'rf')
    assert.is_nil(refs_to(target))
    write('sub/origen.asp', { [["../dest.asp"]] })
    local renamed = write('dest.asp', { '<p>Destino</p>' })
    assert(vim.uv.fs_utime(source, 1700000000, 1700000000))
    assert.are.same({ on_line(source, 0, '../dest.asp') }, refs_to(renamed))
  end)

  it('relee al cambiar el tamaño aunque el mtime sea idéntico', function()
    local target = site()
    local source = write('origen.asp', { [["destino.asp"]] })
    assert(vim.uv.fs_utime(source, 1700000000, 1700000000))
    assert.are.same({ on_line(source, 0, 'destino.asp') }, refs_to(target))
    write('origen.asp', { '<p>Sin enlace, cambio externo</p>' })
    assert(vim.uv.fs_utime(source, 1700000000, 1700000000))
    assert.is_nil(refs_to(target))
  end)

  it('ajusta BOM y latin1 a las columnas UTF-8 del buffer', function()
    local target = site()
    local sources = {
      { 'bom.asp', '\239\187\191<a href="destino.asp">x</a>\n' },
      { 'latin1.asp', '<a title="P\225gina \241and\250" href="destino.asp">x</a>\n' },
    }
    for _, item in ipairs(sources) do
      local f = assert(io.open(temp .. '/' .. item[1], 'wb'))
      f:write(item[2])
      f:close()
    end
    local refs, expected = refs_to(target), {}
    for _, item in ipairs(sources) do
      local path = temp .. '/' .. item[1]
      vim.cmd.edit(path)
      local line = vim.api.nvim_buf_get_lines(0, 0, 1, true)[1]
      local col = assert(line:find('destino.asp', 1, true)) - 1
      table.insert(expected, location(path, 0, col, 0, col + #'destino.asp'))
    end
    assert.are.same(expected, refs)
  end)

  it('recorre entradas sin tipo de scandir y no sigue symlinks interiores', function()
    local target = site()
    local source = write('sub/origen.asp', { [["../destino.asp"]] })
    local linked = write('sub/enlazado.asp', { [["destino.asp"]] })
    write('build/omitido.asp', { [["/destino.asp"]] })
    assert(vim.uv.fs_symlink(temp .. '/sub', temp .. '/alias'))
    assert(vim.uv.fs_symlink(linked, temp .. '/enlace.asp'))
    vim.uv.fs_scandir_next = function(handle)
      local name = original_scandir_next(handle)
      return name
    end
    assert.are.same({ on_line(source, 0, '../destino.asp') }, refs_to(target))
  end)

  it('calcula la raíz virtual una vez por directorio en cada consulta', function()
    local target = site()
    write('a.asp', { [["destino.asp"]] })
    write('b.asp', { [["destino.asp"]] })
    write('sub/c.asp', { [["/destino.asp"]] })
    write('sub/d.asp', { [["/destino.asp"]] })
    vim.cmd.edit(target)
    local calls = 0
    require('asp.includes').virtual_root_for = function(path)
      calls = calls + 1
      return original_root_for(path)
    end
    assert.are.equal(4, #pages.references(0, { line = 0, character = 0 }))
    assert.are.equal(2, calls)
    calls = 0
    assert.are.equal(4, #pages.references(0, { line = 0, character = 0 }))
    assert.are.equal(2, calls)
  end)

  it('avisa una sola vez si la consulta tarda más de un segundo', function()
    local target = site()
    write('origen.asp', { [["destino.asp"]] })
    local notices, time = {}, 0
    vim.notify = function(message, level) table.insert(notices, { message, level }) end
    vim.cmd.edit(target)
    vim.uv.hrtime = function() time = time + 2e9; return time end
    assert.are.equal(1, #pages.references(0, { line = 0, character = 0 }))
    assert.are.same({ {
      'asp: se recorrieron 2 archivos; las siguientes consultas usan la caché.', vim.log.levels.INFO,
    } }, notices)
  end)

  it('el aviso depende de lo que leyó y tardó la consulta, no del tamaño del sitio', function()
    local notices = {}
    vim.notify = function(message, level) table.insert(notices, { message, level }) end
    local now = vim.uv.hrtime()
    pages.notify_slow(5000, 0, now)
    pages.notify_slow(5000, 1999, now)
    assert.are.same({}, notices)
    pages.notify_slow(5000, 2000, now)
    pages.notify_slow(3, 0, now - 1e9)
    local function notice(count)
      return { ('asp: se recorrieron %d archivos; las siguientes consultas usan la caché.'):format(count),
        vim.log.levels.INFO }
    end
    assert.are.same({ notice(5000), notice(3) }, notices)
  end)

  it('busca quién usa la página desde el hueco entre literales que no son rutas', function()
    site()
    local source = write('pagina.asp', { [[<% Response.Write "a" & x & "b" %>]] })
    local caller = write('usa.asp', { [["pagina.asp"]] })
    vim.cmd.edit(source)
    for _, token in ipairs({ 'Write', '&' }) do
      assert.are.same({ on_line(caller, 0, 'pagina.asp') },
        pages.references(0, on_line(source, 0, token).range.start))
    end
  end)

  it('el handler prioriza nombres VBScript y JS sobre los usos de la página', function()
    local target = site()
    local source = write('pagina.asp', {
      '<%', 'Dim total', 'total = 1', '%>', '<script>',
      'document.title = "t"; alert(total); foo();',
      'const obj = { unknown };', 'location.href = "destino.asp";', '</script>',
    })
    write('usa.asp', { [["pagina.asp"]] })
    local page_refs = refs_to(target)
    assert.are.equal(1, #refs_to(source))
    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end))
    local vb_refs = request(on_line(source, 2, 'total').range.start)
    assert.are.equal(2, #vb_refs)
    assert.are.same({ on_line(source, 1, 'total'), on_line(source, 2, 'total') }, vb_refs)
    for _, name in ipairs({ 'document', 'title', 'alert', 'foo' }) do
      assert.are.same({}, request(on_line(source, 5, name).range.start), name)
    end
    assert.are.same({}, request(on_line(source, 6, 'unknown').range.start))
    assert.are.same(page_refs, request(on_line(source, 7, 'destino.asp').range.start))
  end)

  it('el handler LSP devuelve referencias de página y una lista vacía sin usos', function()
    local expected = refs_to(TARGET)
    vim.cmd.edit(SOURCE)
    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end))
    assert.are.same(expected, request(on_line(SOURCE, 0, 'otra.asp').range.start))
    vim.cmd.edit(TARGET)
    assert.are.same(expected, request({ line = 0, character = 0 }))
    vim.cmd.edit(SOURCE)
    assert.are.same({}, request(on_line(SOURCE, 10, 'inexistente.asp').range.start))
  end)
end)
