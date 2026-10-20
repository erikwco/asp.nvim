local FIX = vim.fn.fnamemodify('tests/fixtures/js/crossfile', ':p'):gsub('/$', '')

-- Posición de `word` dentro de la primera línea del buffer actual que
-- contiene `text` (por defecto, el comienzo de `text`).
local function pos_in(text, word)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = line:find(text, 1, true)
    if col then
      local wcol = line:find(word or text, col, true)
      assert(wcol, ('"%s" no aparece en la línea de "%s"'):format(word, text))
      return { line = i - 1, character = wcol - 1 }
    end
  end
  error('texto no encontrado: ' .. text)
end

-- Línea (0-indexed) de la primera aparición de `text` en un archivo de disco.
local function line_in_file(rel, text)
  local i = 0
  for line in io.lines(FIX .. '/' .. rel) do
    if line:find(text, 1, true) then return i end
    i = i + 1
  end
  error(('"%s" no aparece en %s'):format(text, rel))
end

-- Ruta relativa al fixture (o el nombre de archivo, fuera de él) de una uri.
local function rel(uri)
  local path = vim.uri_to_fname(uri)
  return path:match('crossfile/(.*)$') or path:match('[^/]+$')
end

-- Crea `files` (nombre → líneas) en un directorio temporal, abre su
-- pagina.asp y corre fn(dir); siempre borra el buffer y el directorio.
local function in_project(files, fn)
  vim.cmd('bwipeout!')
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  dir = vim.uv.fs_realpath(dir)
  for name, lines in pairs(files) do
    vim.fn.writefile(lines, dir .. '/' .. name)
  end
  vim.cmd.edit(dir .. '/pagina.asp')
  local ok, err = pcall(fn, dir)
  vim.cmd('bwipeout!')
  vim.fn.delete(dir, 'rf')
  assert(ok, err)
end

-- 'archivo:línea' de cada Location, en orden.
local function where(locs)
  local got = {}
  for _, r in ipairs(locs) do
    table.insert(got, ('%s:%d'):format(rel(r.uri), r.range.start.line))
  end
  return got
end

describe('asp.js cross-file', function()
  local js = require('asp.js')

  before_each(function()
    vim.cmd.edit(FIX .. '/pagina.asp')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function def(text, word)
    return js.definition(0, pos_in(text, word))
  end

  it('definición de una función de un .js cargado por <script src>', function()
    local loc = def('desdeSrc();')
    assert.is_not_nil(loc)
    assert.are.equal('js/app.js', rel(loc.uri))
    assert.are.same({ line = line_in_file('js/app.js', 'function desdeSrc'), character = 9 },
      loc.range.start)
  end)

  it('definición de una función de un <script> de un include', function()
    local loc = def('desdeInclude();')
    assert.are.equal('inc/menu.inc', rel(loc.uri))
    assert.are.equal(line_in_file('inc/menu.inc', 'function desdeInclude'), loc.range.start.line)
    -- include virtual="/..."
    loc = def('desdePie();')
    assert.are.equal('inc/pie.asp', rel(loc.uri))
    assert.are.equal(line_in_file('inc/pie.asp', 'function desdePie'), loc.range.start.line)
  end)

  it('un <script src> dentro de un include se resuelve relativo al include', function()
    -- inc/lib/menu.js existe; lib/menu.js (relativo a la página) no.
    assert.is_nil(vim.uv.fs_stat(FIX .. '/lib/menu.js'))
    local loc = def('desdeMenuJs();')
    assert.are.equal('inc/lib/menu.js', rel(loc.uri))
  end)

  it('src virtual con querystring', function()
    assert.are.equal('js/virtual.js', rel(def('desdeVirtual();').uri))
  end)

  it('el local del buffer gana sobre el global externo homónimo', function()
    local loc = def('return desdeSrc', 'desdeSrc')
    assert.are.equal('pagina.asp', rel(loc.uri))
    assert.are.equal(pos_in('var desdeSrc = 1').line, loc.range.start.line)
  end)

  it('el global del buffer gana sobre el global externo homónimo', function()
    local loc = def('mostrar(deLaPagina', 'deLaPagina')
    assert.are.equal('pagina.asp', rel(loc.uri))
    assert.are.equal(pos_in('var deLaPagina').line, loc.range.start.line)
  end)

  it('prioridad: los <script src> del buffer antes que los includes', function()
    -- `duplicada` se declara en js/app.js y en inc/menu.inc.
    assert.are.equal('js/app.js', rel(def('duplicada();').uri))
  end)

  it('ignora en silencio un src externo, inexistente, dinámico o de servidor', function()
    -- Nombres sin declaración en ningún archivo (jQuery vendría del CDN).
    for _, text in ipairs({ 'jQuery();', 'soloServidor();' }) do
      local ok, loc = pcall(js.definition, 0, pos_in(text))
      assert.is_true(ok)
      assert.is_nil(loc)
      local rok, refs = pcall(js.references, 0, pos_in(text))
      assert.is_true(rok)
      -- Nombre JS sin binding: {} y no nil, para que asp.pages no responda
      -- con los usos de la página (ver asp.js.references).
      assert.are.same({}, refs)
    end
  end)

  it('un src armado con ASP no carga el archivo de su parte estática', function()
    -- a.js existe, pero esos src los arma el servidor: `soloDinamico` está
    -- sólo detrás de ellos. El parser html no ve el bloque ASP, así que el
    -- valor interior del atributo es sólo la parte estática (`a.js`).
    local srcs = {
      '"<%= base %>a.js"', -- prefijo
      '"a.js<%= sufijo %>"', -- sufijo
      '"a<%= medio %>.js"',
      "'<%= base %>a.js'",
      '<%= base %>a.js', -- sin comillas
      'a.js<%= sufijo %>',
    }
    local function check(page_line, inc_line)
      in_project({
        ['a.js'] = { 'function soloDinamico() {}' },
        ['a.inc'] = { inc_line or '' },
        ['pagina.asp'] = {
          '<!--#include file="a.inc" -->',
          page_line or '',
          '<script>',
          'soloDinamico();',
          '</script>',
        },
      }, function()
        local label = page_line or inc_line
        assert.is_nil(js.definition(0, pos_in('soloDinamico();')), label)
        assert.are.same({}, js.references(0, pos_in('soloDinamico();')), label)
      end)
    end
    for _, src in ipairs(srcs) do
      local tag = '<script src=' .. src .. '></script>'
      check(tag, nil)
      check(nil, tag)
    end

    -- Control: un bloque ASP fuera del valor no lo vuelve dinámico.
    for _, tag in ipairs({
      '<script src="a.js"></script>',
      '<script src="a.js"<%= atributos %>></script>',
      '<script src=a.js <%= atributos %>></script>',
    }) do
      in_project({
        ['a.js'] = { 'function soloDinamico() {}' },
        ['pagina.asp'] = { tag, '<script>', 'soloDinamico();', '</script>' },
      }, function()
        local loc = js.definition(0, pos_in('soloDinamico();'))
        assert.are.equal('a.js', loc and rel(loc.uri), tag)
      end)
    end
  end)

  it('los locales de un archivo externo no existen para la página', function()
    -- `function interno` es global en app.js; `var desdeInclude` de
    -- conLocal es local de app.js y no compite con el global del include.
    assert.are.equal('inc/menu.inc', rel(def('desdeInclude();').uri))
  end)

  it('references cross-file: buffer, .js e includes', function()
    local refs = js.references(0, pos_in('desdeSrc();'))
    local got = {}
    for _, r in ipairs(refs) do
      table.insert(got, ('%s:%d'):format(rel(r.uri), r.range.start.line))
    end
    assert.are.same({
      'pagina.asp:' .. pos_in('desdeSrc();').line,
      'js/app.js:' .. line_in_file('js/app.js', 'function desdeSrc'),
      'js/app.js:' .. line_in_file('js/app.js', 'desdeSrc();'),
      'inc/menu.inc:' .. line_in_file('inc/menu.inc', 'desdeSrc();'),
      'inc/pie.asp:' .. line_in_file('inc/pie.asp', 'desdeSrc();'),
    }, got)
    -- El `var desdeSrc` local de usarLocal no entra.
    local local_line = pos_in('var desdeSrc = 1').line
    for _, r in ipairs(refs) do
      assert.is_false(rel(r.uri) == 'pagina.asp' and r.range.start.line == local_line)
    end
  end)

  it('references respeta los locales de cada archivo externo', function()
    local refs = js.references(0, pos_in('desdeInclude();'))
    local files = {}
    for _, r in ipairs(refs) do files[rel(r.uri)] = (files[rel(r.uri)] or 0) + 1 end
    -- uso en la página + declaración en el include; el local homónimo de
    -- app.js (declaración y uso) no.
    assert.are.same({ ['pagina.asp'] = 1, ['inc/menu.inc'] = 1 }, files)
  end)

  it('references de un global homónimo en dos externos reúne ambos', function()
    -- En el navegador el global es uno solo: definition va al de mayor
    -- prioridad (app.js) y references incluye también el del include.
    assert.are.same({
      'pagina.asp:' .. pos_in('duplicada();').line,
      'js/app.js:' .. line_in_file('js/app.js', 'function duplicada'),
      'inc/menu.inc:' .. line_in_file('inc/menu.inc', 'function duplicada'),
    }, where(js.references(0, pos_in('duplicada();'))))
  end)

  it('references une los globales homónimos y respeta los locales de cada archivo', function()
    in_project({
      ['a.js'] = { 'var f = 1;', 'f;' },
      ['b.js'] = { 'var f = 2;', 'f;', 'function g(f) {', '  return f;', '}' },
      ['pagina.asp'] = {
        '<script src="a.js"></script>',
        '<script src="b.js"></script>',
        '<script>',
        'f;',
        'function h() { var f = 3; return f; }',
        '</script>',
      },
    }, function()
      local expected = { 'pagina.asp:3', 'a.js:0', 'a.js:1', 'b.js:0', 'b.js:1' }
      assert.are.same(expected, where(js.references(0, pos_in('f;'))))
      -- definition sigue yendo a la primera por prioridad.
      assert.are.equal('a.js', rel(js.definition(0, pos_in('f;')).uri))
      -- El local de h() sigue aparte.
      assert.are.same({ 'pagina.asp:4', 'pagina.asp:4' },
        where(js.references(0, pos_in('return f', 'f'))))
    end)

    -- Si el buffer también lo declara, su declaración entra junto con las
    -- de los externos.
    in_project({
      ['a.js'] = { 'function f() {}' },
      ['pagina.asp'] = {
        '<script src="a.js"></script>',
        '<script>',
        'var f = 1;',
        'f();',
        '</script>',
      },
    }, function()
      assert.are.equal('pagina.asp', rel(js.definition(0, pos_in('f();')).uri))
      assert.are.same({ 'pagina.asp:2', 'pagina.asp:3', 'a.js:0' },
        where(js.references(0, pos_in('f();'))))
    end)
  end)

  it('references de un global del buffer incluye sus usos en los externos', function()
    vim.cmd('bwipeout!')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function write(name, lines)
      vim.fn.writefile(lines, dir .. '/' .. name)
    end
    write('lib.js', { 'function usar() {', '  return compartida;', '}', 'function otra(compartida) { return compartida; }' })
    write('pagina.asp', {
      '<script src="lib.js"></script>',
      '<script>',
      'var compartida = 1;',
      '</script>',
    })
    vim.cmd.edit(dir .. '/pagina.asp')
    local ok, refs = pcall(js.references, 0, pos_in('var compartida', 'compartida'))
    vim.cmd('bwipeout!')
    vim.fn.delete(dir, 'rf')
    assert.is_true(ok, refs)
    local got = {}
    for _, r in ipairs(refs) do
      table.insert(got, ('%s:%d'):format(rel(r.uri), r.range.start.line))
    end
    -- el parámetro homónimo de otra() sombrea al global
    assert.are.same({ 'pagina.asp:2', 'lib.js:1' }, got)
  end)

  it('la caché por mtime se invalida al reescribir el archivo externo', function()
    vim.cmd('bwipeout!')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local lib = dir .. '/lib.js'
    vim.fn.writefile({ 'function hola() {}' }, lib)
    vim.fn.writefile({
      '<script src="lib.js"></script>',
      '<script>',
      'hola();',
      '</script>',
    }, dir .. '/pagina.asp')
    vim.cmd.edit(dir .. '/pagina.asp')

    local ok, err = pcall(function()
      local first = js.definition(0, pos_in('hola();'))
      assert.are.equal(0, first.range.start.line)
      -- Fuera de Neovim (sin BufWritePost): sólo el mtime avisa.
      vim.fn.writefile({ '// movida', '', 'function hola() {}' }, lib)
      local second = js.definition(0, pos_in('hola();'))
      assert.are.equal(2, second.range.start.line)
      vim.fn.writefile({ 'function chau() {}' }, lib)
      assert.is_nil(js.definition(0, pos_in('hola();')))
    end)
    vim.cmd('bwipeout!')
    vim.fn.delete(dir, 'rf')
    assert.is_true(ok, err)
  end)

  it('la caché de archivos de disco tiene tope LRU y olvida los borrados', function()
    local max = js._FILE_CACHE_MAX
    local files = { ['pagina.asp'] = { '', '<script>', 'nadie();', '</script>' } }
    for i = 1, max + 2 do
      files['f' .. i .. '.js'] = { 'function f' .. i .. '() {}' }
    end
    in_project(files, function(dir)
      -- Carga f<desde>..f<hasta> en ese orden: `nadie` no se declara en
      -- ningún archivo, así que definition los recorre todos.
      local function load(from, to)
        local tags = {}
        for i = from, to do
          table.insert(tags, '<script src="f' .. i .. '.js"></script>')
        end
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { table.concat(tags) })
        assert.is_nil(js.definition(0, pos_in('nadie();')))
      end
      local function cached(i)
        return vim.tbl_contains(js._cached_files(), dir .. '/f' .. i .. '.js')
      end

      load(1, max) -- llena la caché: lo de los tests anteriores sale
      assert.are.equal(max, #js._cached_files())
      load(1, 1) -- f1 pasa a ser la más reciente
      load(max + 1, max + 1) -- sale la usada hace más tiempo: f2, no f1
      assert.are.equal(max, #js._cached_files())
      assert.is_true(cached(1))
      assert.is_false(cached(2))
      assert.is_true(cached(max + 1))

      -- Un archivo borrado sale en la siguiente consulta, la cargue o no
      -- la página.
      os.remove(dir .. '/f1.js')
      load(1, 1)
      assert.is_false(cached(1))
      os.remove(dir .. '/f3.js')
      load(max + 2, max + 2)
      assert.is_false(cached(3))
      assert.is_true(cached(max + 2))
    end)
  end)

  it('la caché no expulsa los archivos de la consulta en curso', function()
    local max = js._FILE_CACHE_MAX
    -- Más externos que el tope: mitad .js de <script src>, mitad includes.
    local half = math.ceil((max + 6) / 2)
    local files, page = { ['otro.js'] = { 'function otro() {}' } }, {}
    for i = 1, half do
      files['s' .. i .. '.js'] = { 'function s' .. i .. '() {}' }
      files['i' .. i .. '.inc'] = { '<script>', 'function i' .. i .. '() {}', '</script>' }
      table.insert(page, '<script src="s' .. i .. '.js"></script>')
      table.insert(page, '<!--#include file="i' .. i .. '.inc" -->')
    end
    vim.list_extend(page, { '<script>', 'nadie();', '</script>' })
    files['pagina.asp'] = page
    in_project(files, function(dir)
      -- `nadie` no se declara en ningún archivo: definition los recorre todos.
      assert.is_nil(js.definition(0, pos_in('nadie();')))
      assert.are.equal(2 * half, #js._cached_files())

      local open, opens = io.open, 0
      io.open = function(...)
        opens = opens + 1
        return open(...)
      end
      local ok, res = pcall(js.definition, 0, pos_in('nadie();'))
      io.open = open
      assert.is_true(ok, res)
      assert.is_nil(res)
      assert.are.equal(0, opens)

      -- La consulta siguiente, de otro conjunto, vuelve al tope.
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        '<script src="otro.js"></script>', '<script>', 'nadie();', '</script>',
      })
      assert.is_nil(js.definition(0, pos_in('nadie();')))
      assert.are.equal(max, #js._cached_files())
      assert.is_true(vim.tbl_contains(js._cached_files(), dir .. '/otro.js'))
    end)
  end)

  it('escribir un .js desde Neovim llama a js.invalidate', function()
    vim.cmd('bwipeout!')
    local path = vim.fn.tempname() .. '.js'
    local seen
    local invalidate = js.invalidate
    js.invalidate = function(p)
      seen = p
      return invalidate(p)
    end
    local ok, err = pcall(function()
      vim.cmd.edit(path)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'function x() {}' })
      vim.cmd('silent write')
    end)
    js.invalidate = invalidate
    vim.cmd('bwipeout!')
    vim.fn.delete(path)
    assert.is_true(ok, err)
    assert.is_not_nil(seen)
    assert.are.equal(vim.fn.resolve(path), vim.fn.resolve(seen))
  end)

  it('desde disco sólo parsea html y javascript, y la segunda consulta usa la caché', function()
    vim.cmd('bwipeout!')
    vim.cmd.edit(FIX .. '/pagina.asp')
    for _, path in ipairs(vim.fn.globpath(FIX, '**/*.*', false, true)) do
      js.invalidate(path)
    end
    -- Consulta in-file previa: el parser propio del buffer queda fuera.
    assert.is_not_nil(js.definition(0, pos_in('return desdeSrc', 'desdeSrc')))

    local get_string_parser = vim.treesitter.get_string_parser
    local calls = {}
    vim.treesitter.get_string_parser = function(str, lang, opts)
      local tree = get_string_parser(str, lang, opts)
      table.insert(calls, { lang = lang, injections = opts and opts.injections, tree = tree })
      return tree
    end
    local ok, err = pcall(function()
      assert.are.equal('inc/pie.asp', rel(js.definition(0, pos_in('desdePie();')).uri))
      local langs = {}
      for _, c in ipairs(calls) do
        langs[c.lang] = true
        if c.lang == 'html' then
          -- sin las inyecciones html → javascript/css
          assert.are.same({ html = '' }, c.injections)
        end
        -- Las capas inyectadas (vbscript de la plantilla, css o js del
        -- html) las crea LanguageTree:parse por dentro, sin pasar por
        -- get_string_parser: sólo se ven como hijos del árbol que las
        -- inyecta.
        assert.are.same({}, vim.tbl_keys(c.tree:children()), c.lang)
      end
      assert.is_true(langs.html and langs.javascript)
      assert.is_nil(langs.vbscript)
      assert.is_nil(langs.css)

      calls = {}
      assert.are.equal('inc/pie.asp', rel(js.definition(0, pos_in('desdePie();')).uri))
      -- Nada: tampoco las plantillas de los includes, cuyas directivas
      -- para el grafo salen de la caché de asp.includes.
      assert.are.same({}, calls)
    end)
    vim.treesitter.get_string_parser = get_string_parser
    assert.is_true(ok, err)
  end)

  it('un include sin <script> o con JS roto no lanza', function()
    vim.cmd('bwipeout!')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ '<% Dim x %>' }, dir .. '/vb.inc')
    vim.fn.writefile({ '<script>', 'function (( {', '</script>' }, dir .. '/roto.inc')
    vim.fn.writefile({ '<script>', 'function sana() {}', '</script>' }, dir .. '/sano.inc')
    vim.fn.writefile({
      '<!--#include file="vb.inc" -->',
      '<!--#include file="roto.inc" -->',
      '<!--#include file="sano.inc" -->',
      '<script>',
      'sana(); nadie();',
      '</script>',
    }, dir .. '/pagina.asp')
    vim.cmd.edit(dir .. '/pagina.asp')
    local ok, err = pcall(function()
      assert.are.equal('sano.inc', rel(js.definition(0, pos_in('sana();')).uri))
      assert.is_nil(js.definition(0, pos_in('nadie();')))
    end)
    vim.cmd('bwipeout!')
    vim.fn.delete(dir, 'rf')
    assert.is_true(ok, err)
  end)
end)

describe('asp-ls JavaScript cross-file', function()
  before_each(function()
    vim.cmd.edit(FIX .. '/pagina.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 5000)
    for _, r in pairs(resp or {}) do return r.result end
  end

  it('textDocument/definition abre la declaración en el include', function()
    local loc = request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_in('desdeInclude();'),
    })
    assert.is_not_nil(loc)
    assert.are.equal('inc/menu.inc', rel(loc.uri))
    assert.are.equal(line_in_file('inc/menu.inc', 'function desdeInclude'), loc.range.start.line)
  end)

  it('textDocument/references reúne buffer, .js e includes', function()
    local refs = request('textDocument/references', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_in('desdeSrc();'),
      context = { includeDeclaration = true },
    })
    local files = {}
    for _, r in ipairs(refs) do files[rel(r.uri)] = (files[rel(r.uri)] or 0) + 1 end
    assert.are.same({
      ['pagina.asp'] = 1,
      ['js/app.js'] = 2,
      ['inc/menu.inc'] = 1,
      ['inc/pie.asp'] = 1,
    }, files)
  end)
end)
