local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')
local SOURCE = FIX .. '/paginas/inicio.asp'
local TARGET = FIX .. '/paginas/otra.asp'

local regression_cases = {
  { 'JS simple dentro de atributo doble', [[<a onclick="location.href='otra.asp'">]] },
  { 'JS doble dentro de atributo simple', [[<a onclick='window.open("otra.asp")'>]] },
  { 'HTML con comillas duplicadas en Response.Write', [[<% Response.Write "<a href=""otra.asp"">Ir</a>" %>]] },
  { 'HTML con comillas simples en Response.Write', [[<% Response.Write "<a href='otra.asp'>Ir</a>" %>]] },
  { 'Redirect después de una barra invertida', [[<% r = Replace(x, "/", "\") : Response.Redirect "otra.asp" %>]] },
  { 'href después de una ruta VBScript', [[<% base = "C:\sitio\" %><a href="otra.asp">x</a>]] },
  { 'href después de un apóstrofo HTML', [[<td>O'Brien</td><td><a href="otra.asp">ver</a></td>]] },
  { 'href después de un comentario VBScript', [[<% x = 1 ' comentario %><a href="otra.asp">x</a>]] },
}

local function pos_of(text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = line:find(text, 1, true)
    if col then return { line = i - 1, character = col - 1 } end
  end
  error('texto no encontrado en fixture: ' .. text)
end

local function location(path)
  return {
    uri = vim.uri_from_fname(path),
    range = {
      start = { line = 0, character = 0 },
      ['end'] = { line = 0, character = 0 },
    },
  }
end

describe('asp.pages', function()
  local pages

  before_each(function()
    vim.cmd.edit(SOURCE)
    pages = require('asp.pages')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local cases = {
    { 'Response.Redirect dentro de VBScript', 'otra.asp" %>', TARGET },
    { 'href relativo', 'otra.asp">Otra', TARGET },
    { 'action con querystring y fragmento', 'otra.asp?id=1', TARGET },
    { 'ruta virtual contra web.config', '/includes/helpers.asp', FIX .. '/includes/helpers.asp' },
    { 'string JS con comillas simples', "otra.asp';", TARGET },
    { 'string JS con comillas dobles', 'lib/app.js";', FIX .. '/paginas/lib/app.js' },
    { 'literal antes de una concatenación VBScript', 'otra.asp?id=" &', TARGET },
    { 'literal en bloques ASP adyacentes', 'lib/app.js" %>', FIX .. '/paginas/lib/app.js' },
  }
  for _, case in ipairs(cases) do
    it('resuelve ' .. case[1], function()
      assert.are.same(location(case[3]), pages.definition(0, pos_of(case[2])))
    end)
  end

  for _, case in ipairs(regression_cases) do
    it('resuelve ' .. case[1], function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { case[2] })
      local pos = pos_of('otra.asp')
      for offset = 0, #'otra.asp' - 1 do
        assert.are.same(location(TARGET), pages.definition(0, {
          line = pos.line, character = pos.character + offset,
        }))
      end
      for _, offset in ipairs({ -1, #'otra.asp' }) do
        assert.is_nil(pages.definition(0, {
          line = pos.line, character = pos.character + offset,
        }))
      end
    end)
  end

  it('descarta URLs externas y archivos inexistentes', function()
    assert.is_nil(pages.definition(0, pos_of('http://example.com')))
    assert.is_nil(pages.definition(0, pos_of('inexistente.asp')))
  end)

  it('devuelve nil fuera del contenido entre comillas', function()
    for _, text in ipairs({ 'Response.Redirect', 'href=', '">Otra' }) do
      assert.is_nil(pages.definition(0, pos_of(text)))
    end
    local opening = pos_of('otra.asp" %>')
    opening.character = opening.character - 1
    assert.is_nil(pages.definition(0, opening))
  end)

  it('distingue strings vecinos, comillas interiores y columnas UTF-8', function()
    local lines = {
      [[<a title="It's otra.asp" href='otra.asp'>Ir</a>]],
      [[<script>const texto = "dijo \"otra.asp\""; const url = 'otra.asp';</script>]],
      [[<% texto = "dijo ""otra.asp""" : Response.Redirect "otra.asp" %>]],
      [[<a title="á😀" href="otra.asp">Ir</a>]],
    }
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    for i, line in ipairs(lines) do
      local col = assert(line:match(".*()['\"]otra%.asp['\"]"))
      assert.are.same(location(TARGET), pages.definition(0, { line = i - 1, character = col }))
    end
    assert.is_nil(pages.definition(0, { line = 1, character = assert(lines[2]:find('otra.asp', 1, true)) }))
    assert.are.same(location(TARGET), pages.definition(0, {
      line = 2, character = assert(lines[3]:find('otra.asp', 1, true)),
    }))
  end)

  it('devuelve nil si las comillas más cercanas son distintas', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { [[<a href="otra.asp'>Ir</a>]] })
    assert.is_nil(pages.definition(0, pos_of('otra.asp')))
  end)

  it('tolera entradas inválidas y strings sin cerrar', function()
    assert.is_nil(pages.resolve(nil, SOURCE))
    assert.is_nil(pages.resolve('otra.asp', nil))
    assert.is_nil(pages.definition(-1, { line = 0, character = 1 }))
    assert.is_nil(pages.definition(0, nil))
    assert.is_nil(pages.definition(0, { line = 999, character = 1 }))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { [[<a href="otra.asp]] })
    assert.is_nil(pages.definition(0, { line = 0, character = 10 }))
  end)

  it('resolve normaliza separadores, espacios y sufijos', function()
    assert.are.equal(TARGET, pages.resolve(' ./otra.asp#detalle?id=1 ', SOURCE))
    assert.are.equal(FIX .. '/includes/helpers.asp', pages.resolve([[..\includes\helpers.asp]], SOURCE))
    assert.are.equal(FIX .. '/includes/helpers.asp', pages.resolve([[\includes\helpers.asp]], SOURCE))
  end)

  it('resolve descarta todos los prefijos externos, vacíos y extensiones ajenas', function()
    for _, text in ipairs({
      'http://example.com/otra.asp', 'HTTPS://example.com/otra.asp',
      '//example.com/otra.asp', [[\\example.com\otra.asp]],
      'mailto:otra.asp', 'JAVASCRIPT:otra.asp', '', '  ', '?otra.asp',
      '../web.config', 'inexistente.asp',
    }) do
      assert.is_nil(pages.resolve(text, SOURCE), text)
    end
  end)

  it('resolve honra virtual_root configurado', function()
    local asp = require('asp')
    local previous = asp.options.virtual_root
    asp.options.virtual_root = FIX .. '/paginas'
    local result = pages.resolve('/otra.asp', SOURCE)
    asp.options.virtual_root = previous
    assert.are.equal(TARGET, result)
  end)

  it('resolve acepta las seis extensiones sin distinguir mayúsculas', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local results, expected = {}, {}
    for _, ext in ipairs({ 'ASP', 'inc', 'htm', 'HTML', 'js', 'CSS' }) do
      local name = 'pagina.' .. ext
      vim.fn.writefile({}, dir .. '/' .. name)
      table.insert(expected, dir .. '/' .. name)
      table.insert(results, pages.resolve(name, dir .. '/inicio.asp'))
    end
    vim.fn.delete(dir, 'rf')
    assert.are.same(expected, results)
  end)

  it('resolve no devuelve directorios aunque terminen en .asp', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/carpeta.asp', 'p')
    local result = pages.resolve('carpeta.asp', dir .. '/inicio.asp')
    vim.fn.delete(dir, 'rf')
    assert.is_nil(result)
  end)

  it('includeexpr se carga con el filetype y resuelve rutas virtuales', function()
    assert.is_truthy(vim.bo.includeexpr:find('asp.pages', 1, true))
    assert.are.equal(FIX .. '/includes/helpers.asp', pages.includeexpr('/includes/helpers.asp'))
    assert.are.equal('inexistente.asp', pages.includeexpr('inexistente.asp'))
    local expr = vim.bo.includeexpr
    local undo = vim.b.undo_ftplugin
    vim.cmd('runtime! ftplugin/asp.lua')
    assert.are.equal(expr, vim.bo.includeexpr)
    assert.are.equal(undo, vim.b.undo_ftplugin)
  end)

  it('includeexpr conserva el texto si falla la resolución', function()
    local resolve = pages.resolve
    pages.resolve = function() error('fallo de resolución simulado') end
    local result = pages.includeexpr('otra.asp')
    pages.resolve = resolve
    assert.are.equal('otra.asp', result)
  end)

  it('undo_ftplugin restaura includeexpr', function()
    vim.cmd(vim.b.undo_ftplugin)
    assert.are.equal(vim.go.includeexpr, vim.bo.includeexpr)
  end)

  it('el ftplugin respeta un includeexpr del usuario', function()
    vim.bo.includeexpr = 'v:fname'
    vim.cmd('runtime! ftplugin/asp.lua')
    assert.are.equal('v:fname', vim.bo.includeexpr)
  end)

  it('gf abre la ruta virtual usando includeexpr', function()
    local pos = pos_of('/includes/helpers.asp')
    vim.api.nvim_win_set_cursor(0, { pos.line + 1, pos.character })
    vim.cmd('normal! gf')
    assert.are.equal(FIX .. '/includes/helpers.asp', vim.api.nvim_buf_get_name(0))
  end)

  it('gf abre rutas relativas con / como separador', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { [[<a href="../includes/helpers.asp">Ir</a>]] })
    vim.bo.modified = false
    local pos = pos_of('includes')
    vim.api.nvim_win_set_cursor(0, { pos.line + 1, pos.character })
    vim.cmd('normal! gf')
    assert.are.equal(FIX .. '/includes/helpers.asp', vim.api.nvim_buf_get_name(0))
  end)

  it('gf abre una página desde la comilla inicial', function()
    local pos = pos_of('otra.asp">Otra')
    vim.api.nvim_win_set_cursor(0, { pos.line + 1, pos.character - 1 })
    vim.cmd('normal! gf')
    assert.are.equal(TARGET, vim.api.nvim_buf_get_name(0))
  end)

  it('C-w f abre la ruta virtual en otra ventana', function()
    local pos = pos_of('/includes/helpers.asp')
    vim.api.nvim_win_set_cursor(0, { pos.line + 1, pos.character })
    local source_win = vim.api.nvim_get_current_win()
    vim.cmd('normal! \23f')
    local target_win = vim.api.nvim_get_current_win()
    local target = vim.api.nvim_buf_get_name(0)
    if target_win ~= source_win then vim.cmd.close() end
    assert.are_not.equal(source_win, target_win)
    assert.are.equal(FIX .. '/includes/helpers.asp', target)
  end)
end)

describe('asp-ls páginas', function()
  before_each(function()
    vim.cmd.edit(SOURCE)
    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end))
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function definition_at(text)
    local response = vim.lsp.buf_request_sync(0, 'textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_of(text),
    }, 3000)
    assert.is_not_nil(response)
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    assert.is_nil(response[client.id].err)
    return response[client.id].result, client
  end

  it('definition devuelve la página y permite abrirla desde LSP', function()
    local loc, client = definition_at('otra.asp" %>')
    assert.are.same(location(TARGET), loc)
    vim.lsp.util.show_document(loc, client.offset_encoding, { focus = true })
    assert.are.equal(TARGET, vim.api.nvim_buf_get_name(0))
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it('definition encadena páginas en HTML, JS y bloques ASP adyacentes', function()
    assert.are.same(location(TARGET), definition_at('otra.asp">Otra'))
    assert.are.same(location(TARGET), definition_at("otra.asp';"))
    assert.are.same(location(FIX .. '/paginas/lib/app.js'), definition_at('lib/app.js" %>'))
  end)

  it('definition resuelve los ocho casos de comillas anidadas y desbalanceadas', function()
    for _, case in ipairs(regression_cases) do
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { case[2] })
      assert.are.same(location(TARGET), definition_at('otra.asp'))
    end
  end)

  it('definition devuelve nil sobre las comillas del literal', function()
    for _, line in ipairs({ [[<a href="otra.asp">Ir</a>]], [[<a href='otra.asp'>Ir</a>]] }) do
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
      local quote = line:match('["\']')
      assert.is_nil(definition_at(quote .. 'otra.asp'))
      assert.is_nil(definition_at(quote .. '>Ir'))
    end
  end)
end)
