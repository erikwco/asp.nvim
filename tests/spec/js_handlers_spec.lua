local FIX = vim.fn.fnamemodify('tests/fixtures/js/handlers', ':p'):gsub('/$', '')

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
  return path:match('handlers/(.*)$') or path:match('[^/]+$')
end

-- 'archivo:línea' de cada Location, en orden.
local function where(locs)
  local got = {}
  for _, r in ipairs(locs) do
    table.insert(got, ('%s:%d'):format(rel(r.uri), r.range.start.line))
  end
  return got
end

-- 'pagina.asp:línea' de la primera línea del buffer que contiene `text`.
local function here(text)
  return ('pagina.asp:%d'):format(pos_in(text).line)
end

-- 'pagina.asp:línea' de la línea del buffer que es exactamente `text`.
local function exact(text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line == text then return ('pagina.asp:%d'):format(i - 1) end
  end
  error('no hay una línea igual a: ' .. text)
end

describe('asp.js manejadores de evento', function()
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

  -- 'archivo:línea' de la definición, o nil.
  local function def_at(text, word)
    local loc = def(text, word)
    return loc and ('%s:%d'):format(rel(loc.uri), loc.range.start.line)
  end

  it('definición desde onclick a una función de un <script> de la página', function()
    local loc = def('onclick="reinitAsk();"', 'reinitAsk')
    assert.are.equal('pagina.asp', rel(loc.uri))
    assert.are.same(pos_in('function reinitAsk', 'reinitAsk'), loc.range.start)
    assert.are.equal(here('function reinitAsk'), def_at('<body onload=', 'reinitAsk'))
  end)

  it('definición desde onchange a una función de un <script src>', function()
    local loc = def('onchange="validarCampo', 'validarCampo')
    assert.are.equal('js/validar.js', rel(loc.uri))
    assert.are.same({ line = line_in_file('js/validar.js', 'function validarCampo'), character = 9 },
      loc.range.start)
  end)

  it('definición desde onsubmit a una función declarada en un include', function()
    local loc = def('onsubmit="return enviarFormulario', 'enviarFormulario')
    assert.are.equal('inc/form.inc', rel(loc.uri))
    assert.are.same({ line = line_in_file('inc/form.inc', 'function enviarFormulario'), character = 9 },
      loc.range.start)
  end)

  it('references de una función de un include reúne los manejadores del buffer y de los includes', function()
    local refs = js.references(0, pos_in('onsubmit="return enviarFormulario', 'enviarFormulario'))
    assert.are.same({
      here('onsubmit='),
      'inc/form.inc:' .. line_in_file('inc/form.inc', 'function enviarFormulario'),
      'inc/form.inc:' .. line_in_file('inc/form.inc', 'onclick='),
      -- botones.inc no tiene <script>: sólo manejadores.
      'inc/botones.inc:' .. line_in_file('inc/botones.inc', 'onclick="enviarFormulario'),
    }, where(refs))
  end)

  it('references de una función de la página incluye sus usos en manejadores y en includes', function()
    local refs = js.references(0, pos_in('function reinitAsk', 'reinitAsk'))
    assert.are.same({
      here('function reinitAsk'),
      here('<body onload='),
      here('onclick="reinitAsk();"'),
      here('onclick=reinitAsk()'),
      here('ONCLICK='),
      here('onblur='),
      here('JavaScript: reinitAsk'),
      exact('reinitAsk();'),
      'inc/botones.inc:' .. line_in_file('inc/botones.inc', 'onclick="reinitAsk'),
      -- enlaces.inc no tiene <script> ni atributos on*: sólo una URL javascript:.
      'inc/enlaces.inc:' .. line_in_file('inc/enlaces.inc', 'javascript:reinitAsk'),
    }, where(refs))
  end)

  it('un <%= %> dentro del manejador: el identificador de afuera resuelve y el de adentro no', function()
    assert.are.equal(here('function borrar'), def_at('borrar(<%= id', 'borrar'))
    for _, pos in ipairs({
      pos_in('borrar(<%= id', 'id %>'),
      pos_in('borrar(<%= id', 'handler'),
    }) do
      assert.is_nil(js.definition(0, pos))
      assert.is_nil(js.references(0, pos))
    end
    -- El `id` del bloque sigue siendo de la capa VBScript.
    local loc = require('asp.symbols').definition(0, pos_in('borrar(<%= id', 'id %>'))
    assert.are.equal(pos_in('Dim id').line, loc.range.start.line)
  end)

  it('un bloque ASP pegado al borde del valor se cuenta como parte del manejador', function()
    -- `<%= prefijo %>reinitAsk` es un solo identificador armado en el
    -- servidor: no es la función `reinitAsk`.
    assert.is_nil(def('onkeyup=', 'reinitAsk'))
    assert.is_nil(js.references(0, pos_in('onkeyup=', 'reinitAsk')))
    -- Separado por un blanco, el identificador es propio y resuelve.
    assert.are.equal(here('function borrar'), def_at('onkeydown=', 'borrar'))
    -- Un valor que es entero un bloque ASP no es una región JS.
    assert.is_nil(def('onclick="<%= manejador', 'manejador'))
  end)

  it('atributo sin comillas', function()
    assert.are.equal(here('function reinitAsk'), def_at('onclick=reinitAsk()', 'reinitAsk'))
  end)

  it('el nombre del atributo no distingue mayúsculas (ONCLICK)', function()
    assert.are.equal(here('function reinitAsk'), def_at('ONCLICK=', 'reinitAsk'))
  end)

  it('un atributo que no es on* no se parsea como JS', function()
    for _, pos in ipairs({
      pos_in('value="reinitAsk"', 'reinitAsk'),
      pos_in('value="reinitAsk"', 'borrar'),
      pos_in('href="reinitAsk.asp"', 'reinitAsk'),
    }) do
      assert.is_nil(js.definition(0, pos))
      assert.is_nil(js.references(0, pos))
    end
  end)

  it('un nombre sin declaración en un manejador: definition nil y references {}', function()
    for _, word in ipairs({ 'sinDeclarar', 'location', 'href' }) do
      local pos = pos_in('onclick="sinDeclarar', word)
      assert.is_nil(js.definition(0, pos), word)
      assert.are.same({}, js.references(0, pos), word)
    end
  end)

  it('href="javascript:..." es JS desde después del prefijo, sin distinguir mayúsculas', function()
    assert.are.equal(here('function borrar'), def_at('href="javascript:borrar', 'borrar'))
    assert.are.equal(here('function reinitAsk'), def_at('JavaScript: reinitAsk', 'reinitAsk'))
    -- El prefijo no es JS.
    assert.is_nil(js.references(0, pos_in('JavaScript: reinitAsk', 'JavaScript')))
    -- Con un bloque ASP delante el prefijo no es estático: no es una región.
    assert.is_nil(def('url %>javascript', 'reinitAsk'))
  end)

  it('las entidades HTML del valor no impiden resolver el resto', function()
    assert.are.equal(here('function reinitAsk'), def_at('onblur=', 'reinitAsk'))
  end)

  it('un var de un manejador es local a él', function()
    -- El manejador es el cuerpo de una función: su `var contador` no es el
    -- global homónimo.
    assert.are.equal(here('var contador = 5'), def_at('var contador = 5', 'contador++'))
    assert.are.same({ here('var contador = 5'), here('var contador = 5') },
      where(js.references(0, pos_in('var contador = 5', 'contador'))))
    assert.are.same({ here('var contador = 0'), exact('contador++;') },
      where(js.references(0, pos_in('var contador = 0', 'contador'))))
  end)

  it('document_symbols no lista lo declarado en un manejador', function()
    local names = {}
    for _, s in ipairs(js.document_symbols(0)) do table.insert(names, s.name) end
    assert.are.same({ 'reinitAsk', 'borrar' }, names)
    -- La función del manejador resuelve dentro de él.
    assert.are.equal(here('function delManejador'), def_at('delManejador();', 'delManejador();'))
  end)
end)

describe('asp.js manejadores de evento, casos borde', function()
  local js = require('asp.js')

  local function setup(lines)
    vim.cmd('enew!')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.filetype = 'asp'
  end

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  -- Posición de la n-ésima aparición de `word` en la línea que contiene `text`.
  local function nth(text, word, n)
    local p = pos_in(text)
    local line = vim.api.nvim_buf_get_lines(0, p.line, p.line + 1, false)[1]
    local col = 0
    for _ = 1, n do
      col = assert(line:find(word, col + 1, true), word .. ' no aparece ' .. n .. ' veces')
    end
    return { line = p.line, character = col - 1 }
  end

  local function def_pos(pos)
    local loc = js.definition(0, pos)
    return loc and loc.range.start
  end

  it('regiones chicas intercaladas con <script> resuelven cada una en su scope', function()
    setup({
      '<input onclick="var x = 1; usar(x)">',
      '<script>',
      'function usar(y) { var x = 2; return x + y; }',
      'var x = 3;',
      '</script>',
      '<input onclick="usar(x)"><input onclick="e => usar(e)">',
      '<script>usar(x);</script>',
    })
    -- El local del primer manejador, el local de usar y el global.
    assert.are.same(nth('onclick="var x', 'x', 1), def_pos(nth('onclick="var x', 'x', 2)))
    assert.are.same(nth('function usar', 'x', 1), def_pos(nth('function usar', 'x', 2)))
    assert.are.same(pos_in('var x = 3', 'x'), def_pos(pos_in('onclick="usar(x)"', 'x')))
    assert.are.same(nth('e => usar(e)', 'e', 1), def_pos(nth('e => usar(e)', 'e', 2)))
    -- references del global: declaración, el segundo manejador y el último
    -- <script>; no los locales.
    local lines = {}
    for _, r in ipairs(js.references(0, pos_in('var x = 3', 'x'))) do
      table.insert(lines, r.range.start.line)
    end
    assert.are.same({ 3, 5, 6 }, lines)
    -- usar: su declaración y sus cuatro usos, en orden del documento.
    assert.are.equal(5, #js.references(0, pos_in('function usar', 'usar')))
  end)

  it('un manejador con JS roto no contamina a los demás', function()
    setup({
      '<script>function ok() {}</script>',
      '<input onclick="if ((( {">',
      '<input onclick="ok()">',
    })
    assert.are.same(pos_in('function ok', 'ok'), def_pos(pos_in('onclick="ok()"', 'ok')))
  end)

  it('un manejador de varias líneas', function()
    setup({
      '<script>function a() {} function b() {}</script>',
      '<input type="button" onclick="',
      '  a();',
      '  b();',
      '">',
    })
    assert.are.same(pos_in('function a', 'a'), def_pos(pos_in('  a();', 'a')))
    assert.are.same(pos_in('function b', 'b'), def_pos(pos_in('  b();', 'b')))
  end)

  it('regresión: el onclick del reproductor resuelve a la función del <script>', function()
    vim.cmd('bwipeout!')
    -- El reproductor del reporte, tal cual.
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({
      '<html><head><script>', 'function reinitAsk() { return 1; }', '</script></head><body>',
      '<input type="button" onclick="reinitAsk();" value="Cancelar">',
      '<script>reinitAsk();</script>', '</body></html>',
    }, dir .. '/p.asp')
    vim.cmd.edit(dir .. '/p.asp')
    local ok, loc = pcall(js.definition, 0, pos_in('onclick=', 'reinitAsk'))
    vim.fn.delete(dir, 'rf')
    assert.is_true(ok)
    assert.is_not_nil(loc)
    assert.are.equal(1, loc.range.start.line)
  end)
end)

describe('asp-ls JavaScript en manejadores de evento', function()
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
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do
      return r.result
    end
    return nil
  end

  it('textDocument/definition y references desde un onclick', function()
    local params = {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_in('onclick="reinitAsk();"', 'reinitAsk'),
    }
    local loc = request('textDocument/definition', params)
    assert.is_not_nil(loc)
    assert.are.equal(pos_in('function reinitAsk').line, loc.range.start.line)
    params.context = { includeDeclaration = true }
    local refs = request('textDocument/references', params)
    assert.are.equal(10, #refs)
  end)

  it('un literal de página dentro de un manejador sigue abriendo la página', function()
    -- La capa JS no responde sobre un string: la consulta pasa a asp.pages.
    local loc = request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_in("location.href = 'otra.asp'", 'otra.asp'),
    })
    assert.is_not_nil(loc)
    assert.are.equal('otra.asp', rel(loc.uri))
  end)
end)
