local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')
local symbols = require('asp.symbols')

-- Posición de la ocurrencia `nth` de `text` en el buffer actual.
local function pos_of(text, nth)
  local n = 0
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = line:find(text, 1, true)
    if col then
      n = n + 1
      if n == (nth or 1) then return { line = i - 1, character = col - 1 } end
    end
  end
  error('texto no encontrado: ' .. text)
end

-- "ruta:línea:columna" relativa a `base`. El buffer usa su ruta y los
-- archivos del sitio, la real: se acepta cualquiera de las dos.
local function short(refs, base)
  local real = vim.uv.fs_realpath(base) or base
  local out = {}
  for _, ref in ipairs(refs) do
    local path = vim.uri_to_fname(ref.uri)
    for _, prefix in ipairs({ base .. '/', real .. '/' }) do
      if path:sub(1, #prefix) == prefix then path = path:sub(#prefix + 1) end
    end
    table.insert(out, ('%s:%d:%d'):format(path, ref.range.start.line, ref.range.start.character))
  end
  return out
end

local function refs_at(path, text, nth)
  vim.cmd.edit(path)
  return symbols.references(0, pos_of(text, nth))
end

describe('asp.symbols references con alcance de sitio', function()
  local buffers

  before_each(function()
    buffers = vim.api.nvim_list_bufs()
  end)

  after_each(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not vim.tbl_contains(buffers, buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it('desde la librería reúne las páginas que la incluyen, directa o transitivamente, y sus includes hermanos', function()
    -- catalogo.asp incluye helpers.asp; reportes.asp la incluye a través de
    -- includes/layout.inc; lib/log.inc no incluye helpers.asp, pero catalogo
    -- incluye a ambos y desde ahí llama a RespuestaRapida. sin_include.asp
    -- declara y usa otro RespuestaRapida sin incluir la librería.
    assert.are.same({
      'includes/helpers.asp:6:4',
      'catalogo.asp:7:0',
      'default.asp:12:0',
      'lib/log.inc:4:2',
      'reportes.asp:2:0',
    }, short(refs_at(FIX .. '/includes/helpers.asp', 'RespuestaRapida'), FIX))
  end)

  it('omite los locales y parámetros homónimos de las páginas incluidoras', function()
    -- catalogo.asp tiene un parámetro FormatearMoneda: es otra variable.
    assert.are.same({
      'includes/helpers.asp:2:9',
      'includes/helpers.asp:3:2',
      'default.asp:9:14',
    }, short(refs_at(FIX .. '/includes/helpers.asp', 'FormatearMoneda'), FIX))
    -- Dentro de su Function, el parámetro sigue siendo local al buffer.
    assert.are.same({ 'catalogo.asp:10:17', 'catalogo.asp:11:12' },
      short(refs_at(FIX .. '/catalogo.asp', 'FormatearMoneda', 2), FIX))
  end)

  it('desde lib/db.inc lista las dos páginas que la incluyen sin el Dim local homónimo', function()
    assert.are.same({
      'lib/db.inc:1:9',
      'lib/db.inc:2:6',
      'catalogo.asp:6:9',
      'default.asp:8:11',
    }, short(refs_at(FIX .. '/lib/db.inc', 'AbrirConexion'), FIX))
  end)

  it('desde una página que usa la función da los mismos usos que desde la librería', function()
    local from_lib = short(refs_at(FIX .. '/lib/db.inc', 'AbrirConexion'), FIX)
    local from_page = short(refs_at(FIX .. '/default.asp', 'AbrirConexion'), FIX)
    table.sort(from_lib)
    table.sort(from_page)
    assert.are.same(from_lib, from_page)
  end)

  it('una página que no incluye la librería no se cuenta aunque use el nombre', function()
    for _, ref in ipairs(refs_at(FIX .. '/includes/helpers.asp', 'RespuestaRapida')) do
      assert.is_nil(ref.uri:find('sin_include%.asp$'), ref.uri)
    end
    -- Y al revés: su RespuestaRapida no ve los de la librería.
    assert.are.same({ 'sin_include.asp:2:4', 'sin_include.asp:5:0' },
      short(refs_at(FIX .. '/sin_include.asp', 'RespuestaRapida', 2), FIX))
  end)

  it('buffer_only no recorre el sitio ni lee disco', function()
    local site = require('asp.site')
    local original_index, original_open = site.index, io.open
    local reads = {}
    site.index = function() error('no debe recorrer el sitio') end
    vim.cmd.edit(FIX .. '/includes/helpers.asp')
    local pos = pos_of('RespuestaRapida')
    io.open = function(path, ...)
      if path:sub(1, #FIX) == FIX then table.insert(reads, path) end
      return original_open(path, ...)
    end
    local ok, refs = pcall(symbols.references, 0, pos, { buffer_only = true })
    io.open, site.index = original_open, original_index
    assert.is_true(ok, tostring(refs))
    assert.are.same({ 'includes/helpers.asp:6:4' }, short(refs, FIX))
    assert.are.same({}, reads)
  end)

  it('si el sitio falla conserva el buffer y su grafo de includes', function()
    local site = require('asp.site')
    local original = site.index
    site.index = function() error('sitio roto') end
    local ok, refs = pcall(refs_at, FIX .. '/default.asp', 'FormatearMoneda')
    site.index = original
    assert.is_true(ok, tostring(refs))
    assert.are.same({
      'default.asp:9:14',
      'includes/helpers.asp:2:9',
      'includes/helpers.asp:3:2',
    }, short(refs, FIX))
  end)
end)

describe('asp.symbols references en un sitio temporal', function()
  local temp, buffers, original_open, original_notify, original_hrtime, reads

  before_each(function()
    temp = vim.fn.tempname()
    vim.fn.mkdir(temp, 'p')
    temp = assert(vim.uv.fs_realpath(temp))
    buffers = vim.api.nvim_list_bufs()
    original_open = io.open
    original_notify = vim.notify
    original_hrtime = vim.uv.hrtime
    reads = {}
    io.open = function(path, mode)
      if type(path) == 'string' and path:sub(1, #temp + 1) == temp .. '/' and mode == 'r' then
        reads[path:sub(#temp + 2)] = (reads[path:sub(#temp + 2)] or 0) + 1
      end
      return original_open(path, mode)
    end
  end)

  after_each(function()
    io.open = original_open
    vim.notify = original_notify
    vim.uv.hrtime = original_hrtime
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

  local LIB = { '<%', 'Function Calcular(x)', '  Calcular = x * 2', 'End Function', '%>' }

  local function page(name, include)
    return write(name, { ('<!--#include file="%s" -->'):format(include or 'lib.inc'),
      '<% Response.Write Calcular(1) %>' })
  end

  -- Archivos leídos desde la última llamada, sin repetir.
  local function read_files()
    local files = vim.tbl_keys(reads)
    table.sort(files)
    reads = {}
    return files
  end

  it('lee solo los archivos nuevos o cambiados y nota altas, cambios y bajas', function()
    write('web.config', {})
    local lib = write('lib.inc', LIB)
    page('a.asp')
    write('otra.asp', { '<p>Sin include</p>' })
    vim.cmd.edit(lib)
    local pos = pos_of('Calcular')
    local function query() return short(symbols.references(0, pos), temp) end

    local expected = { 'lib.inc:1:9', 'lib.inc:2:2', 'a.asp:1:18' }
    assert.are.same(expected, query())
    assert.are.same({ 'a.asp', 'lib.inc', 'otra.asp' }, read_files())
    assert.are.same(expected, query())
    assert.are.same({}, read_files())

    -- Una página nueva que incluye la librería entra sin invalidar nada.
    page('nueva.asp')
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2', 'a.asp:1:18', 'nueva.asp:1:18' }, query())
    assert.are.same({ 'nueva.asp' }, read_files())

    -- Quitar la llamada (otro tamaño y otro mtime) relee solo esa página.
    local stat = assert(vim.uv.fs_stat(temp .. '/a.asp'))
    write('a.asp', { '<!--#include file="lib.inc" -->', '<p>Sin llamada</p>' })
    assert(vim.uv.fs_utime(temp .. '/a.asp', stat.atime.sec, stat.mtime.sec + 2))
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2', 'nueva.asp:1:18' }, query())
    assert.are.same({ 'a.asp' }, read_files())

    -- Una página que deja de incluir la librería sale del conjunto: el
    -- barrido la relee, pero ya no hace falta parsearla.
    write('nueva.asp', { '<% Response.Write Calcular(1) %>' })
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2' }, query())
    assert.are.same({ 'nueva.asp' }, read_files())

    page('nueva.asp')
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2', 'nueva.asp:1:18' }, query())
    assert.are.same({ 'nueva.asp' }, read_files())
    vim.fn.delete(temp .. '/nueva.asp')
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2' }, query())
    assert.are.same({}, read_files())
  end)

  it('BufWritePost invalida la página aunque se conserve mtime y tamaño', function()
    write('web.config', {})
    local lib = write('lib.inc', LIB)
    local a = page('a.asp')
    assert(vim.uv.fs_utime(a, 1700000000, 1700000000))
    vim.cmd.edit(lib)
    local pos = pos_of('Calcular')
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2', 'a.asp:1:18' }, short(symbols.references(0, pos), temp))

    -- Mismo tamaño: Calcular(1) → Calcula_(1) ya no es el mismo nombre.
    vim.cmd.edit(a)
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { '<% Response.Write Calcula_(1) %>' })
    vim.cmd.write()
    assert(vim.uv.fs_utime(a, 1700000000, 1700000000))
    vim.cmd.edit(lib)
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2' }, short(symbols.references(0, pos), temp))
  end)

  it('sigue los includes transitivos y sus hermanos, también fuera de la raíz', function()
    -- sitio/ es la raíz del barrido. comun/ queda afuera: sus archivos no
    -- se barren, pero a los que incluye una página del sitio se llega con
    -- el grafo de includes.
    write('sitio/web.config', {})
    local lib = write('comun/lib.inc', LIB)
    write('sitio/a.asp', { '<!--#include file="../comun/lib.inc" -->', '<% x = Calcular(1) %>' })
    write('sitio/b.asp', {
      '<!--#include file="../comun/lib.inc" -->', '<!--#include file="../comun/extra.inc" -->',
    })
    write('comun/extra.inc', { '<!--#include file="extra2.inc" -->' })
    write('comun/extra2.inc', { '<% y = Calcular(2) %>' })
    vim.cmd.edit(temp .. '/sitio/a.asp')
    assert.are.same({
      'sitio/a.asp:1:7',
      'comun/lib.inc:1:9',
      'comun/lib.inc:2:2',
      'comun/extra2.inc:0:7',
    }, short(symbols.references(0, pos_of('Calcular')), temp))
  end)

  it('avisa una sola vez si la consulta tarda más de un segundo', function()
    write('web.config', {})
    local lib = write('lib.inc', LIB)
    page('a.asp')
    vim.cmd.edit(lib)
    local pos = pos_of('Calcular')
    local notices, time = {}, 0
    vim.notify = function(message, level) table.insert(notices, { message, level }) end
    vim.uv.hrtime = function() time = time + 2e9; return time end
    local refs = symbols.references(0, pos)
    vim.uv.hrtime = original_hrtime
    assert.are.equal(3, #refs)
    assert.are.same({ {
      'asp: se recorrieron 2 archivos; las siguientes consultas usan la caché.', vim.log.levels.INFO,
    } }, notices)
  end)

  it('usa los includes del buffer sin guardar, no los del disco', function()
    write('web.config', {})
    write('Old.inc', { '<% Dim Hit : Hit = 1 %>' })
    write('New.inc', { '<% Dim Hit : Hit = 3 %>' })
    write('B.asp', { '<!--#include file="New.inc" -->', '<% Hit = 4 %>' })
    vim.cmd.edit(write('A.asp', { '<!--#include file="Old.inc" -->', '<% Hit = 2 %>' }))
    local pos = pos_of('Hit')
    local function query() return short(symbols.references(0, pos), temp) end
    assert.are.same({ 'A.asp:1:3', 'Old.inc:0:7', 'Old.inc:0:13' }, query())

    -- Sin guardar, el buffer deja de incluir Old.inc: el sitio sigue
    -- teniendo esa arista en disco, pero no vale para este archivo.
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { '<!-- sin include -->' })
    assert.are.same({}, require('asp.includes').buffer_graph(0).order)
    assert.are.same({ 'A.asp:1:3' }, query())

    -- Y pasa a incluir New.inc: entra su declaración y B.asp, que también
    -- lo incluye.
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { '<!--#include file="New.inc" -->' })
    assert.are.same({ 'A.asp:1:3', 'New.inc:0:7', 'New.inc:0:13', 'B.asp:1:3' }, query())
  end)

  it('nota un include fuera de la raíz que aparece o desaparece sin cambiar las páginas', function()
    write('sitio/web.config', {})
    vim.cmd.edit(write('sitio/A.asp', { '<!--#include file="../comun/L.inc" -->', '<% Hit = 1 %>' }))
    write('sitio/B.asp', { '<!--#include file="../comun/L.inc" -->', '<% Hit = 2 %>' })
    local pos = pos_of('Hit')
    local function query() return short(symbols.references(0, pos), temp) end
    assert.are.same({ 'sitio/A.asp:1:3' }, query())
    assert.are.same({ 'sitio/A.asp', 'sitio/B.asp' }, read_files())

    -- B.asp no cambió: entra porque su include ahora resuelve, y recién
    -- entonces hace falta parsearla.
    write('comun/L.inc', { '<% Dim Hit %>' })
    assert.are.same({ 'sitio/A.asp:1:3', 'comun/L.inc:0:7', 'sitio/B.asp:1:3' }, query())
    assert.are.same({ 'comun/L.inc', 'sitio/B.asp' }, read_files())

    vim.fn.delete(temp .. '/comun/L.inc')
    assert.are.same({ 'sitio/A.asp:1:3' }, query())
    assert.are.same({}, read_files())
  end)

  it('parsea solo los archivos que mencionan el nombre y no relee lo que leyó el barrido', function()
    write('web.config', {})
    local lib = write('lib.inc', { '<%', 'Function Calcular(x)', '  Calcular = x * 2', 'End Function',
      'Sub Otra()', 'End Sub', '%>' })
    local a = { '<!--#include file="lib.inc" -->', '<% Response.Write Calcular(1) %>' }
    local b = { '<!--#include file="lib.inc" -->', '<% Otra %>' }
    write('a.asp', a)
    write('b.asp', b)
    local names = {
      [table.concat(a, '\n') .. '\n'] = 'a.asp',
      [table.concat(b, '\n') .. '\n'] = 'b.asp',
    }
    vim.cmd.edit(lib)
    local calcular, otra = pos_of('Calcular'), pos_of('Otra')
    local parsed, original_parser = {}, vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function(source, lang, ...)
      if lang == 'vbscript' then table.insert(parsed, names[source] or source) end
      return original_parser(source, lang, ...)
    end
    local function query(pos)
      parsed = {}
      local refs = short(symbols.references(0, pos), temp)
      local counts = reads
      reads = {}
      return refs, parsed, counts
    end

    local ok, err = pcall(function()
      -- El barrido lee cada archivo una vez y b.asp, que no menciona
      -- Calcular, no se parsea.
      local refs, files, counts = query(calcular)
      assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2', 'a.asp:1:18' }, refs)
      assert.are.same({ 'a.asp' }, files)
      assert.are.same({ ['a.asp'] = 1, ['b.asp'] = 1, ['lib.inc'] = 1 }, counts)

      -- Otro nombre: solo b.asp lo menciona. Se relee y se parsea solo esa.
      refs, files, counts = query(otra)
      assert.are.same({ 'lib.inc:4:4', 'b.asp:1:3' }, refs)
      assert.are.same({ 'b.asp' }, files)
      assert.are.same({ ['b.asp'] = 1 }, counts)

      -- En caliente, ninguno de los dos lee ni parsea.
      for _, pos in ipairs({ calcular, otra }) do
        refs, files, counts = query(pos)
        assert.are.same({}, files)
        assert.are.same({}, counts)
      end
    end)
    vim.treesitter.get_string_parser = original_parser
    assert(ok, err)
  end)

  it('desde disco parsea solo la plantilla, sin inyecciones, y la capa VBScript', function()
    write('web.config', {})
    local lib = write('lib.inc', LIB)
    write('a.asp', {
      '<!--#include file="lib.inc" -->',
      '<html><head><style>p { color: red }</style>',
      '<script>function Calcular() { return 1 }</script></head>',
      '<body onclick="Calcular()"><%= Calcular(1) %></body></html>',
    })
    vim.cmd.edit(lib)
    local pos = pos_of('Calcular')
    local parsers, original_parser = {}, vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function(source, lang, ...)
      local parser = original_parser(source, lang, ...)
      table.insert(parsers, { lang = lang, parser = parser })
      return parser
    end
    local ok, refs = pcall(symbols.references, 0, pos)
    vim.treesitter.get_string_parser = original_parser
    assert.is_true(ok, tostring(refs))
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2', 'a.asp:3:31' }, short(refs, temp))
    local langs = {}
    for _, p in ipairs(parsers) do
      langs[p.lang] = true
      assert.are.same({}, p.parser:children(), p.lang)
    end
    assert.are.same({ aspclassic = true, vbscript = true }, langs)
  end)

  it('sin raíz de sitio se queda en el buffer y su grafo', function()
    local lib = write('lib.inc', LIB)
    page('a.asp')
    vim.cmd.edit(lib)
    assert.is_nil(require('asp.pages').scan_root_for(lib))
    assert.are.same({ 'lib.inc:1:9', 'lib.inc:2:2' }, short(symbols.references(0, pos_of('Calcular')), temp))
  end)
end)

describe('asp-ls references y documentHighlight con alcance de sitio', function()
  after_each(function() vim.cmd('bwipeout!') end)

  local function open(path)
    vim.cmd.edit(path)
    assert.is_true(vim.wait(2000, function()
      local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
      return client and client.initialized
    end))
  end

  local function request(method, pos)
    local resp = vim.lsp.buf_request_sync(0, 'textDocument/' .. method, {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos,
      context = { includeDeclaration = true },
    }, 5000)
    assert.is_not_nil(resp)
    for _, r in pairs(resp) do
      assert.is_nil(r.err)
      return r.result
    end
  end

  it('textDocument/references desde la librería lista las páginas que la incluyen', function()
    open(FIX .. '/includes/helpers.asp')
    assert.are.same({
      'includes/helpers.asp:6:4',
      'catalogo.asp:7:0',
      'default.asp:12:0',
      'lib/log.inc:4:2',
      'reportes.asp:2:0',
    }, short(request('references', pos_of('RespuestaRapida')), FIX))
  end)

  it('documentHighlight sigue limitado al buffer y no recorre el sitio', function()
    open(FIX .. '/includes/helpers.asp')
    local site = require('asp.site')
    local original = site.index
    site.index = function() error('no debe recorrer el sitio') end
    local ok, result = pcall(request, 'documentHighlight', pos_of('RespuestaRapida'))
    site.index = original
    assert.is_true(ok, tostring(result))
    assert.are.same({ {
      range = {
        start = { line = 6, character = 4 },
        ['end'] = { line = 6, character = 4 + #'RespuestaRapida' },
      },
      kind = vim.lsp.protocol.DocumentHighlightKind.Write,
    } }, result)
  end)
end)
