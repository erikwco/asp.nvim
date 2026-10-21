local FIX = vim.fn.fnamemodify('tests/fixtures/js_ayuda', ':p')
local help = require('asp.js_help')
local js = require('asp.js')
local handlers = require('asp.lsp').handlers

local function pos(text, shift)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = line:find(text, 1, true)
    if col then return { line = i - 1, character = col - 1 + (shift or 0) } end
  end
  error('texto no encontrado: ' .. text)
end

local function query(text, marker)
  local p = pos(marker or '// consulta global')
  vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, vim.split(text, '\n', { plain = true }))
  local lines = vim.split(text, '\n', { plain = true })
  return { line = p.line + #lines - 1, character = #lines[#lines] }
end

local function items(position, complete)
  local out = {}
  for _, e in ipairs((complete or help.complete)(0, position) or {}) do out[e.label] = e end
  return out
end

local function params(position)
  return { textDocument = vim.lsp.util.make_text_document_params(), position = position }
end

local function labels(result)
  local sig = result.signatures[1]
  return vim.tbl_map(function(p)
    return type(p.label) == 'table' and sig.label:sub(p.label[1] + 1, p.label[2]) or p.label
  end, sig.parameters)
end

describe('asp.js ayuda de cliente', function()
  before_each(function() vim.cmd.edit(FIX .. 'pagina.asp') end)
  after_each(function() vim.cmd('bwipeout!') end)

  it('hover de una función de otro script de la página', function()
    assert.are.equal('```javascript\nfunction buscarGlobal(primero, segundo = 2, ...resto)\n```',
      help.hover(0, pos('buscarGlobal(1, 2);')).contents.value)
  end)

  it('hover de una función externa conserva la firma y el archivo', function()
    local value = help.hover(0, pos('buscarExterna(1)')).contents.value
    assert.is_truthy(value:find('function buscarExterna(valor, opciones = {}, ...resto)', 1, true))
    assert.is_truthy(value:find('Archivo: `util.js`.', 1, true))
  end)

  it('hover de una función de include', function()
    local value = help.hover(0, pos("buscarIncluida('a')")).contents.value
    assert.is_truthy(value:find('function buscarIncluida(texto, limite = 10)', 1, true))
    assert.is_truthy(value:find('Archivo: `funciones.inc`.', 1, true))
  end)

  it('hover del let local muestra su declaración', function()
    assert.are.equal('```javascript\nlet total = 5\n```', help.hover(0, pos('return total', 7)).contents.value)
  end)

  it('hover de un parámetro indica que lo es, con su default o su rest', function()
    local function hover(text, shift) return help.hover(0, pos(text, shift)).contents.value end
    assert.are.equal('```javascript\n(parámetro) primero\n```', hover('return primero', 7))
    assert.are.equal('```javascript\n(parámetro) segundo = 2\n```', hover('segundo = 2'))
    assert.are.equal('```javascript\n(parámetro) ...resto\n```', hover('resto)'))
    assert.are.equal("```javascript\n(parámetro) color = 'azul'\n```", hover('return color', 7))
    query('function patrones({ a, b } = {}, c = {\n  d: 1 }) { return a + c; }')
    assert.are.equal('```javascript\n(parámetro) a\n```', hover('return a', 7))
    assert.are.equal('```javascript\n(parámetro) c = { d: 1 }\n```', hover('a + c', 4))
    local entry = items(pos('return a', #'return a')).a
    assert.are.equal('(parámetro) a', entry.detail)
  end)

  it('hover de la declaración de un método y una clase', function()
    assert.are.equal("```javascript\npintar(color = 'azul')\n```", help.hover(0, pos('pintar(')).contents.value)
    assert.are.equal('```javascript\nclass Vista\n```', help.hover(0, pos('class Vista', 6)).contents.value)
  end)

  it('hover de funciones asignadas a variables y arrows', function()
    assert.are.equal('```javascript\nlet expresion = function(nombre)\n```',
      help.hover(0, pos('expresion =')).contents.value)
    assert.are.equal('```javascript\nconst flecha = (valor, extra = 1) => ...\n```',
      help.hover(0, pos('flecha =')).contents.value)
  end)

  it('hover de document.getElementById documenta el miembro', function()
    local value = help.hover(0, pos('document.getElementById', 9)).contents.value
    assert.is_truthy(value:find('document.getElementById(id)', 1, true))
    assert.is_truthy(value:find('Busca un elemento', 1, true))
  end)

  it('hover de globales, miembros y rutas explícitas del catálogo', function()
    query('window.location.href; document.location.reload(); console.log(1); parseInt("1");')
    for _, text in ipairs({ 'href', 'reload', 'log(1)', 'parseInt' }) do
      assert.is_not_nil(help.hover(0, pos(text)), text)
    end
  end)

  it('hover nil fuera de JS, en strings y en comentarios', function()
    for _, p in ipairs({ pos('Len('), pos('<h1>', 4), pos('"buscarGlobal"', 2),
      pos('// buscarGlobal', 4), pos('runat="server">', 15), pos('type="text/template">', 21) }) do
      assert.is_nil(help.hover(0, p))
    end
    assert.is_nil(require('asp.hover').hover(0, pos('buscarGlobal(1, 2);')))
  end)

  it('hover VBScript conserva exactamente la respuesta de su capa', function()
    local p = pos('Len(')
    local old = require('asp.hover').hover(0, p)
    assert.is_truthy(old.contents.value:find('```vbscript\nLen(string)', 1, true))
    assert.are.same(old, handlers['textDocument/hover'](params(p)))
  end)

  it('completion lista globales y locales envolventes, sin locales ajenos', function()
    local entries = items(query('bus', '// consulta local'))
    for _, name in ipairs({ 'buscarLocal', 'buscarGlobal', 'buscarExterna', 'buscarIncluida' }) do
      assert.are.equal(3, entries[name].kind, name)
    end
    assert.is_nil(entries.buscarOculta)
    assert.is_truthy(entries.buscarExterna.documentation.value:find('Archivo: `util.js`', 1, true))
  end)

  it('completion distingue mayúsculas', function()
    assert.are.same({}, items(query('Bus', '// consulta local')))
  end)

  it('completion entrega los kinds de función, variable y clase', function()
    local entries = items(query('', '// consulta local'))
    assert.are.equal(6, entries.total.kind)
    assert.are.equal('let total = 5', entries.total.detail)
    assert.are.equal(7, entries.Vista.kind)
    assert.are.equal(3, entries.flecha.kind)
    assert.are.equal(3, entries.expresion.kind)
    assert.is_nil(entries.soloAjena)
    assert.is_nil(entries.soloExterno)
    assert.is_nil(entries.Response)
    assert.is_nil(entries.Replace)
  end)

  it('completion respeta el sombreado y la prioridad de los locales', function()
    local p = query('let buscarGlobal = 3;\nbus', '// consulta local')
    local entries = help.complete(0, p)
    assert.are.equal('buscarGlobal', entries[1].label)
    assert.are.equal('let buscarGlobal = 3', items(p).buscarGlobal.detail)
  end)

  it('completion en defaults no expone las declaraciones del cuerpo', function()
    query('function prueba(a = buscarGlobal, b = 1) { let buscarGlobal = 9; }')
    local entry = items(pos('a = buscarGlobal', #'a = bus')).buscarGlobal
    assert.are.equal(3, entry.kind)
  end)

  it('completion document. lista solamente sus miembros', function()
    local entries = items(query('document.'))
    assert.are.equal(2, entries.getElementById.kind)
    assert.are.equal(10, entries.forms.kind)
    assert.is_nil(entries.buscarGlobal)
    assert.is_nil(entries.Response)
  end)

  it('completion filtra miembros con prefijo sensible a mayúsculas', function()
    local entries = items(query('document.getE'))
    assert.is_not_nil(entries.getElementById)
    assert.is_nil(entries.querySelector)
  end)

  it('completion funciona en onclick y javascript:', function()
    for _, text in ipairs({ 'onclick="buscarGlobal', 'javascript:buscarGlobal' }) do
      assert.is_not_nil(items(pos(text, #text - #'carGlobal')).buscarGlobal)
    end
  end)

  it('completion funciona en regiones vacías y espacios antes del primer token', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      '<script>function buscarGlobal() {}</script>',
      '<script></script><button onclick=""></button><a href="javascript:">x</a>',
      '<script>   buscarGlobal();</script>',
    })
    for _, p in ipairs({ pos('<script></script>', 8), pos('onclick="', 9), pos('javascript:', 11),
      pos('<script>   ', 9) }) do
      assert.is_not_nil(items(p).buscarGlobal)
    end
  end)

  it('completion no pierde el scope de una función vacía', function()
    query('const anonima = () => {  };')
    assert.is_not_nil(items(pos('=> {', 5)).buscarGlobal)
    assert.is_nil(items(pos('=> {', 5)).buscarLocal)
  end)

  it('completion ve los parámetros al final de una arrow y de una función sin cerrar', function()
    query('[1].map(elemento => elem);', '// consulta local')
    assert.is_not_nil(items(pos('elem)', #'elem')).elemento)
    local p = query('function abierta(parametro) {\n  var interno = 1;\n  par')
    assert.is_not_nil(items(p).parametro)
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { '  int' })
    assert.is_not_nil(items({ line = p.line, character = 5 }).interno)
  end)

  it('completion obj. desconocido no inventa miembros', function()
    assert.are.same({}, help.complete(0, query('obj.')))
  end)

  it('completion no confunde receptores encadenados o devueltos con globales', function()
    for _, text in ipairs({ 'obj.document.', 'obtener().document.', 'lista[0].document.' }) do
      local p = query(text)
      assert.are.same({}, help.complete(0, p))
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { '// consulta global' })
    end
  end)

  it('un binding document sombrea el catálogo en las tres ayudas', function()
    query('function propia(document) { document.getElementById(1); }')
    local p = pos('document.getElementById', 9)
    assert.is_nil(help.hover(0, p))
    assert.are.same({}, help.complete(0, p))
    assert.is_nil(help.signature(0, pos('getElementById(', #'getElementById(')))
  end)

  it('completion ofrece event sólo dentro de los manejadores on*', function()
    local p = pos('onclick="buscarGlobal')
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { '<button onclick="buscarGlobal(ev)">Buscar</button>' })
    local entry = items(pos('(ev)', 3)).event
    assert.are.equal(6, entry.kind)
    assert.is_truthy(entry.documentation.value:find('parámetro implícito', 1, true))
    assert.is_nil(items(query('ev')).event)
    assert.is_nil(items(pos('javascript:buscarGlobal', #'javascript:')).event)
  end)

  it('completion ofrece todas las palabras clave de JavaScript', function()
    local p = query('fi')
    for _, word in ipairs({ 'switch', 'case', 'break', 'continue', 'default', 'do', 'try', 'catch',
      'finally', 'throw', 'instanceof', 'delete', 'in', 'of', 'class', 'extends', 'super', 'static',
      'import', 'export', 'yield' }) do
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { word })
      local entry = items({ line = p.line, character = #word })[word]
      assert.are.equal(14, entry and entry.kind, word)
    end
  end)

  it('completion, hover y firmas de los globales de ECMAScript, Storage y fetch', function()
    local p = query('Dat')
    assert.are.equal(3, items(p).Date.kind)
    for object, member in pairs({ Object = 'keys', Date = 'now', Number = 'isInteger', Promise = 'all',
      sessionStorage = 'getItem', String = 'fromCharCode' }) do
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { object .. '.' })
      assert.is_not_nil(items({ line = p.line, character = #object + 1 })[member], object .. '.' .. member)
    end
    for _, name in ipairs({ 'escape', 'unescape', 'eval', 'fetch', 'Boolean', 'RegExp', 'Error' }) do
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { name .. '(' })
      assert.is_not_nil(help.signature(0, { line = p.line, character = #name + 1 }), name)
    end
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'fetch(url, ' })
    local result = help.signature(0, { line = p.line, character = #'fetch(url, ' })
    assert.are.same({ 'resource', 'options' }, labels(result))
    assert.are.equal(1, result.activeParameter)
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'Array.from(x);' })
    local value = help.hover(0, { line = p.line, character = #'Array.f' }).contents.value
    assert.is_truthy(value:find('objeto tipo array', 1, true))
  end)

  it('un binding new XMLHttpRequest() ofrece los miembros de su instancia', function()
    query('var xhr = new XMLHttpRequest();\nvar otro = {};\nxhr.open(\'GET\', url, ')
    local row = pos('xhr.open(').line
    local result = help.signature(0, { line = row, character = #"xhr.open('GET', url, " })
    assert.are.same({ 'method', 'url', 'async', 'user', 'password' }, labels(result))
    assert.are.equal(2, result.activeParameter)
    assert.is_truthy(help.hover(0, { line = row, character = 5 }).contents.value:find('async es true', 1, true))
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, { 'xhr.' })
    local entries = items({ line = row, character = 4 })
    assert.are.equal(2, entries.send.kind)
    assert.are.equal(10, entries.readyState.kind)
    assert.are.equal(10, entries.onreadystatechange.kind)
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, { 'otro.' })
    assert.are.same({}, help.complete(0, { line = row, character = 5 }))
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, { 'XMLHttpRequest.' })
    assert.is_nil(items({ line = row, character = #'XMLHttpRequest.' }).send)
  end)

  it('infiere XHR solo en un inicializador directo y con constructor nativo', function()
    local cases = {
      { 'var xhr = new XMLHttpRequest.Custom();\nxhr.', false },
      { 'var xhr = new XMLHttpRequest().response;\nxhr.', false },
      { 'var { xhr } = new XMLHttpRequest();\nxhr.', false },
      { 'function usar(xhr = new XMLHttpRequest()) { xhr.', false },
      { 'function XMLHttpRequest() {}\nvar xhr = new XMLHttpRequest();\nxhr.', false },
      { 'function usar(XMLHttpRequest) { var xhr = new XMLHttpRequest(); xhr.', false },
      { 'var xhr = new Date();\nxhr.', false },
      { 'var xhr = new\nXMLHttpRequest();\nxhr.', true },
      { 'var xhr = new XMLHttpRequest();\nfunction usar(XMLHttpRequest) { xhr.', true },
    }
    for _, case in ipairs(cases) do
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '<script>', '// consulta global', '</script>' })
      local p = query(case[1])
      local line = vim.api.nvim_buf_get_lines(0, p.line, p.line + 1, false)[1]
      local close = case[1]:find('function usar', 1, true) and ' }' or ''
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { line .. 'send();' .. close })
      assert.are.equal(case[2], items(p).send ~= nil, case[1])
    end
  end)

  it('keywords sólo desde dos letras', function()
    local p = query('f')
    assert.is_nil(items(p)['function'])
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'fu' })
    assert.are.equal(14, items({ line = p.line, character = 2 })['function'].kind)
  end)

  it('completion VBScript conserva el snapshot de Replace', function()
    local p = query('<% rEp %>')
    p.character = 6
    local old = require('asp.completion').complete(0, p)
    assert.are.same(old, handlers['textDocument/completion'](params(p)))
    assert.are.equal(1, #old)
    assert.are.equal('Replace', old[1].label)
    assert.are.equal(3, old[1].kind)
    assert.are.equal('Replace(expression, find, replacewith[, start[, count[, compare]]])', old[1].detail)
    assert.is_nil(help.complete(0, p))
  end)

  it('la posición ASP dentro de JS pertenece a VBScript', function()
    query('const valor = <%= Len("x") %>;')
    assert.is_nil(js.region_at(0, pos('Len(')))
    assert.is_nil(help.hover(0, pos('Len(')))
    assert.is_not_nil(handlers['textDocument/hover'](params(pos('Len('))))
  end)

  it('las consultas de VBScript y de HTML no construyen el índice JS', function()
    local old_parser = vim.treesitter.get_string_parser
    local parsed = 0
    vim.treesitter.get_string_parser = function(source, lang, ...)
      if lang == 'javascript' then parsed = parsed + 1 end
      return old_parser(source, lang, ...)
    end
    local ok, err = pcall(function()
      for i, method in ipairs({ 'textDocument/completion', 'textDocument/hover', 'textDocument/signatureHelp' }) do
        local p = pos('Len(')
        vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'total = Len("' .. ('a'):rep(i) .. '")' })
        handlers[method](params({ line = p.line, character = #'total = Len(' }))
        handlers[method](params({ line = p.line, character = #'total = ' }))
        p = pos('<h1')
        local h1 = '<h1 class="x' .. ('y'):rep(i) .. '">buscar</h1>'
        vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { h1 })
        handlers[method](params({ line = p.line, character = #h1 - #'</h1>' }))
        handlers[method](params({ line = p.line, character = #'<h1 class="x' }))
        handlers[method](params(pos('>Buscar<', 3)))
      end
      assert.are.equal(0, parsed)
      assert.is_not_nil(items(pos('onclick="buscarGlobal', #'onclick="bus')).buscarGlobal)
      assert.is_true(parsed > 0)
      -- Control: el borde de un bloque que termina es del JS que sigue.
      local p = query('const valor = <%= 1 %>;')
      assert.is_not_nil(js.region_at(0, { line = p.line, character = #'const valor = <%= 1 %>' }))
      assert.is_nil(js.region_at(0, { line = p.line, character = #'const valor = ' }))
    end)
    vim.treesitter.get_string_parser = old_parser
    assert.is_true(ok, err)
  end)

  it('signatureHelp de función del usuario cuenta parámetros y conserva default/rest', function()
    local result = help.signature(0, query('buscarGlobal(1, '))
    assert.are.equal(1, result.activeParameter)
    assert.are.same({ 'primero', 'segundo = 2', '...resto' }, labels(result))
  end)

  it('signatureHelp deja activo el rest con argumentos de más', function()
    local p = query('buscarGlobal(1, 2, 3, 4, ')
    assert.are.equal(2, help.signature(0, p).activeParameter)
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'console.log(1, 2, ' })
    assert.are.equal(0, help.signature(0, { line = p.line, character = #'console.log(1, 2, ' }).activeParameter)
    -- Sin rest no hay parámetro activo que elegir.
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'buscarIncluida(1, 2, ' })
    assert.are.equal(2, help.signature(0, { line = p.line, character = #'buscarIncluida(1, 2, ' }).activeParameter)
  end)

  it('signatureHelp desde un archivo externo conserva patrones y el archivo', function()
    local result = help.signature(0, query('externaFlecha({ nombre: "a" }, '))
    assert.are.same({ '{ nombre }', '...otros' }, labels(result))
    assert.are.equal(1, result.activeParameter)
    assert.is_truthy(result.signatures[1].documentation.value:find('Archivo: `util.js`', 1, true))
  end)

  it('signatureHelp de include', function()
    local result = help.signature(0, query('buscarIncluida('))
    assert.are.same({ 'texto', 'limite = 10' }, labels(result))
    assert.is_truthy(result.signatures[1].documentation.value:find('funciones.inc', 1, true))
  end)

  it('signatureHelp de setTimeout y document.getElementById', function()
    local p = query('setTimeout(')
    local result = help.signature(0, p)
    assert.are.equal(0, result.activeParameter)
    assert.are.same({ 'fn', 'ms', '...args' }, labels(result))
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'document.getElementById(' })
    result = help.signature(0, { line = p.line, character = #'document.getElementById(' })
    assert.are.same({ 'id' }, labels(result))
  end)

  it('signatureHelp elige la llamada anidada activa', function()
    local result = help.signature(0, query('buscarGlobal(1, buscarExterna(2, '))
    assert.are.equal(1, result.activeParameter)
    assert.are.same({ 'valor', 'opciones = {}', '...resto' }, labels(result))
  end)

  it('signatureHelp cuenta sólo comas a profundidad cero, también en varias líneas', function()
    -- Sin rest: el índice de más no se recorta al último parámetro.
    local result = help.signature(0, query('buscarIncluida(\n  [1, 2], { a: 1, b: 2 },\n  `a,b`, "c,d", /e,f/, buscarExterna(1, 2), '))
    assert.are.equal(6, result.activeParameter)
  end)

  it('signatureHelp reconoce llamadas con function dentro del nombre', function()
    local p = query('function functionName(a, b) {}\nfunction myfunction(c, d) {}\nfunctionName(1, ')
    assert.are.same({ 'a', 'b' }, labels(help.signature(0, p)))
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'myfunction(1, ' })
    local result = help.signature(0, { line = p.line, character = #'myfunction(1, ' })
    assert.are.same({ 'c', 'd' }, labels(result))
    assert.are.equal(1, result.activeParameter)
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'var g = function* gen(' })
    assert.is_nil(help.signature(0, { line = p.line, character = #'var g = function* gen(' }))
  end)

  it('signatureHelp atraviesa agrupaciones sin confundirlas con llamadas', function()
    assert.are.equal(1, help.signature(0, query('buscarGlobal(1, (2 + ')).activeParameter)
  end)

  it('signatureHelp resuelve el callee fuera del scope de sus callbacks', function()
    local result = help.signature(0, query('buscarGlobal(buscarGlobal => buscarGlobal + '))
    assert.are.same({ 'primero', 'segundo = 2', '...resto' }, labels(result))
  end)

  it('signatureHelp no responde dentro del cuerpo de un callback', function()
    local function restore(p, text)
      vim.api.nvim_buf_set_lines(0, p.line - select(2, text:gsub('\n', '')), p.line + 1, false,
        { '// consulta global' })
    end
    local closed = 'buscarGlobal(function () {\n  var x = 1;\n  \n});'
    local p = query(closed)
    assert.is_nil(help.signature(0, { line = p.line - 1, character = 2 }))
    restore(p, closed)
    for _, text in ipairs({ 'buscarGlobal(() => { let buscarGlobal = 1; ', 'buscarGlobal(1, { m() { ',
      'buscarGlobal(async function* () {\n  ', 'buscarGlobal(class extends Vista { ' }) do
      p = query(text)
      assert.is_nil(help.signature(0, p), text)
      restore(p, text)
    end
  end)

  it('signatureHelp sigue dentro de un objeto literal y de una llamada en el callback', function()
    local p = query('buscarGlobal({ clave: 1,  });')
    local result = help.signature(0, { line = p.line, character = #'buscarGlobal({ clave: 1, ' })
    assert.are.equal(0, result.activeParameter)
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'buscarGlobal(2, { clave: [1, ' })
    assert.are.equal(1, help.signature(0, { line = p.line, character = #'buscarGlobal(2, { clave: [1, ' })
      .activeParameter)
    local text = 'buscarGlobal(function () { buscarGlobal(1, '
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { text })
    assert.are.equal(1, help.signature(0, { line = p.line, character = #text }).activeParameter)
  end)

  it('las sustituciones ${...} de un template son código', function()
    local text = 'var t = `Total: ${buscarGlobal(1, )}`;'
    local p = query(text)
    local cursor = { line = p.line, character = #'var t = `Total: ${buscarGlobal(1, ' }
    assert.are.equal(1, help.signature(0, cursor).activeParameter)
    vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'var t = `Total: ${bus}`;' })
    assert.is_not_nil(items({ line = p.line, character = #'var t = `Total: ${bus' }).buscarGlobal)
    for _, unclosed in ipairs({ '`a ${buscarGlobal(1, ', '`a ${ `b ${x}` + buscarGlobal(1, ',
      "`a ${ { k: '}' }.k + buscarGlobal(1, " }) do
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { unclosed })
      local result = help.signature(0, { line = p.line, character = #unclosed })
      assert.are.equal(1, result and result.activeParameter, unclosed)
    end
    for _, text_only in ipairs({ '`Total ${x} buscarGlobal(1, ', '`Total $', '`Total ${x}`.length + `$' }) do
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { text_only })
      assert.is_nil(help.signature(0, { line = p.line, character = #text_only }), text_only)
    end
  end)

  it('las comas de una sustitución no avanzan el argumento de la llamada exterior', function()
    local p = query('buscarGlobal(`${1, 2}`, ')
    for _, text in ipairs({ 'buscarGlobal(`${1, 2}`, ',
      'buscarGlobal(`a ${`b ${1, 2}`} ${3, 4}`, ',
      'buscarGlobal(`${/}/.test("}"), 2}`, ' }) do
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { text })
      assert.are.equal(1, help.signature(0, { line = p.line, character = #text }).activeParameter, text)
    end
  end)

  it('desestructurar una función no convierte sus propiedades en funciones', function()
    query('const { length } = (a, b) => a;\nlength(')
    local p = pos('length(', #'length(')
    assert.is_nil(help.signature(0, p))
    assert.are.equal(6, items(pos('length(', #'leng')).length.kind)
  end)

  it('signatureHelp admite parámetros multilínea y arrows sin paréntesis', function()
    query('function varias(\n  { a, b } = {},\n  ...otros\n) {}\nconst una = valor => valor;\nvarias(')
    local row = pos('const una').line + 1
    local result = help.signature(0, { line = row, character = #'varias(' })
    assert.are.same({ '{ a, b } = {}', '...otros' }, labels(result))
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, { 'una(' })
    assert.are.same({ 'valor' }, labels(help.signature(0, { line = row, character = 4 })))
  end)

  it('signatureHelp ignora escapes, templates anidados y comentarios cerrados', function()
    local result = help.signature(0, query([[buscarGlobal('a\',b', `a,${`b,c`}`, /* a,b */ ]]))
    assert.are.equal(2, result.activeParameter)
  end)

  it('un nombre de función sombrea al global del catálogo', function()
    query('function propia(setTimeout) { setTimeout(1, 2); }')
    assert.is_nil(help.signature(0, pos('setTimeout(1', #'setTimeout(')))
  end)

  it('nombres y offsets UTF-8 coinciden en hover, completion y firmas', function()
    query('const función = (año, límite = 1) => año;\nfunción(')
    local p = pos('función(', #'función(')
    assert.are.same({ 'año', 'límite = 1' }, labels(help.signature(0, p)))
    assert.is_not_nil(help.hover(0, pos('función(')))
    assert.is_not_nil(items(pos('función(', #'funció'))['función'])
  end)

  it('ayuda vacía dentro de strings simples, dobles, templates y comentarios', function()
    for _, text in ipairs({ "buscarGlobal('hola,", 'buscarGlobal("hola,', 'buscarGlobal(`hola,',
      'buscarGlobal(1, // hola', 'buscarGlobal(1, /* hola', 'buscarGlobal(/hola,/) // comentario' }) do
      local p = query(text)
      assert.is_nil(help.signature(0, p), text)
      assert.are.same({}, help.complete(0, p), text)
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { '// consulta global' })
    end
  end)

  it('un comentario <!-- o un string sin cerrar no apagan la ayuda de las líneas siguientes', function()
    for _, text in ipairs({ "<!-- don't hide", "var roto = 'sin cierre;" }) do
      local p = query(text .. '\nbuscarGlobal(1, ')
      assert.are.equal(1, help.signature(0, p).activeParameter, text)
      vim.api.nvim_buf_set_lines(0, p.line, p.line + 1, false, { 'bus' })
      assert.is_not_nil(items({ line = p.line, character = 3 }).buscarGlobal, text)
      vim.api.nvim_buf_set_lines(0, p.line - 1, p.line + 1, false, { '// consulta global' })
    end
    local p = query('<!-- buscarGlobal(1, ')
    assert.are.same({}, help.complete(0, p))
    assert.is_nil(help.signature(0, p))
  end)

  it('no muestra ayuda en HTML ni scripts de servidor o de otro type', function()
    for _, p in ipairs({ pos('<h1>', 4), pos('runat="server">', 15), pos('type="text/template">', 21) }) do
      assert.is_nil(help.complete(0, p))
      assert.is_nil(help.signature(0, p))
    end
  end)

  it('definition y references no arman la ayuda ni los opacos de la ayuda', function()
    local info = require('asp.js_info')
    -- Externos ya cacheados: su ayuda se extrae al cargarlos.
    assert.is_true(#js.references(0, pos('buscarExterna(1)')) > 0)
    local old_declaration, old_parse = info.declaration, vim.treesitter.query.parse
    local declared, opaque = 0, 0
    info.declaration = function(...)
      declared = declared + 1
      return old_declaration(...)
    end
    vim.treesitter.query.parse = function(lang, text, ...)
      if text:find('@opaque', 1, true) then opaque = opaque + 1 end
      return old_parse(lang, text, ...)
    end
    local ok, err = pcall(function()
      query('var cambio = 1;')
      local p = pos('buscarGlobal(1, 2);')
      assert.is_not_nil(js.definition(0, p))
      assert.is_true(#js.references(0, p) > 0)
      assert.are.equal(0, declared)
      assert.is_not_nil(help.hover(0, p))
      assert.is_true(declared > 0)
      assert.are.equal(0, opaque)
      assert.are.equal(1, help.signature(0, pos('buscarGlobal(1, 2);', #'buscarGlobal(1, ')).activeParameter)
      assert.is_not_nil(items(pos('buscarGlobal(1, 2);', #'busc')).buscarGlobal)
      assert.are.equal(1, opaque)
    end)
    info.declaration, vim.treesitter.query.parse = old_declaration, old_parse
    assert.is_true(ok, err)
  end)

  it('en caliente hover, completion y signatureHelp no releen ni reparsean externos', function()
    local p = pos('onclick="buscarGlobal', #'onclick="bus')
    assert.is_not_nil(items(p).buscarExterna)
    local old_open, old_parser = io.open, vim.treesitter.get_string_parser
    local reads, parses = 0, 0
    io.open = function(...)
      reads = reads + 1
      return old_open(...)
    end
    vim.treesitter.get_string_parser = function(...)
      parses = parses + 1
      return old_parser(...)
    end
    local ok, err = pcall(function()
      for _ = 1, 3 do
        assert.is_not_nil(help.hover(0, pos('buscarExterna(1)')))
        assert.is_not_nil(items(p).buscarIncluida)
        assert.is_not_nil(help.signature(0, pos('buscarExterna(1)', #'buscarExterna(')))
      end
    end)
    io.open, vim.treesitter.get_string_parser = old_open, old_parser
    assert.is_true(ok, err)
    assert.are.equal(0, reads)
    assert.are.equal(0, parses)
  end)
end)

describe('catálogo DOM parcial', function()
  it('tiene entre 150 y 200 entradas documentadas y offsets válidos', function()
    local dom = require('asp.dom')
    assert.is_true(dom.count >= 150 and dom.count <= 200, tostring(dom.count))
    local all = vim.list_extend({}, dom.globals)
    for _, object in ipairs({ 'document', 'window', 'console', 'Math', 'JSON', 'localStorage',
      'sessionStorage', 'location', 'navigator', 'history', 'Array', 'Object', 'Date', 'String',
      'Number', 'Promise', 'XMLHttpRequest.prototype' }) do
      vim.list_extend(all, dom.members(object))
    end
    for _, e in ipairs(all) do
      assert.is_true(#e.doc > 0, e.name)
      assert.is_true(#e.detail > 0, e.name)
      for _, label in ipairs(e.signature and labels({ signatures = { {
        label = e.signature, parameters = e.parameters,
      } } }) or {}) do
        assert.is_truthy(label:match('^[%.%w_$]+$'), label)
      end
    end
  end)
end)

describe('asp-ls ayuda JavaScript de extremo a extremo', function()
  before_each(function()
    vim.cmd.edit(FIX .. 'pagina.asp')
    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end))
  end)
  after_each(function() vim.cmd('bwipeout!') end)

  local function request(method, position)
    for _, response in pairs(vim.lsp.buf_request_sync(0, method, params(position), 3000) or {}) do
      assert.is_nil(response.err)
      return response.result
    end
    error('sin respuesta LSP')
  end

  it('hover responde con la firma de una función JS externa', function()
    assert.is_truthy(request('textDocument/hover', pos('buscarExterna(1)')).contents.value:find('util.js', 1, true))
  end)

  it('completion en onclick ofrece funciones JS sin VBScript', function()
    local entries = request('textDocument/completion', pos('onclick="buscarGlobal', #'onclick="bus'))
    local names = vim.tbl_map(function(e) return e.label end, entries)
    assert.is_true(vim.tbl_contains(names, 'buscarGlobal'))
    assert.is_true(vim.tbl_contains(names, 'buscarIncluida'))
    assert.is_false(vim.tbl_contains(names, 'buscarOculta'))
  end)

  it('signatureHelp cuenta el segundo argumento JS', function()
    local result = request('textDocument/signatureHelp', pos('buscarGlobal(1, 2);', #'buscarGlobal(1, '))
    assert.are.equal(1, result.activeParameter)
    assert.are.same({ 'primero', 'segundo = 2', '...resto' }, labels(result))
  end)
end)
