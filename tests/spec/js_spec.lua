local FIX = vim.fn.fnamemodify('tests/fixtures/js', ':p'):gsub('/$', '')

local function pos_of(text, occurrence)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local n = 0
  for i, line in ipairs(lines) do
    local col = line:find(text, 1, true)
    if col then
      n = n + 1
      if n == (occurrence or 1) then
        return { line = i - 1, character = col - 1 }
      end
    end
  end
  error('texto no encontrado en fixture: ' .. text)
end

-- Posición de `word` dentro de la (primera) línea que contiene `text`.
local function pos_in(text, word)
  local p = pos_of(text)
  local line = vim.api.nvim_buf_get_lines(0, p.line, p.line + 1, false)[1]
  local col = line:find(word, p.character + 1, true)
  assert(col, ('"%s" no aparece en la línea de "%s"'):format(word, text))
  return { line = p.line, character = col - 1 }
end

local function line_of(text)
  return pos_of(text).line
end

describe('asp.js', function()
  local js

  before_each(function()
    vim.cmd.edit(FIX .. '/pagina.asp')
    js = require('asp.js')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function def_line(text, word)
    local loc = js.definition(0, pos_in(text, word))
    return loc and loc.range.start.line
  end

  it('clasifica las declaraciones con su kind', function()
    local kinds = {}
    for _, e in ipairs(js.collect(0)) do
      kinds[e.name] = kinds[e.name] or e.kind
    end
    assert.are.equal(12, kinds['inicializar'])  -- function_declaration
    assert.are.equal(5, kinds['Carrito'])       -- class_declaration
    assert.are.equal(6, kinds['agregar'])       -- method_definition
    assert.are.equal(13, kinds['contador'])     -- var
    assert.are.equal(13, kinds['pendiente'])    -- let
    assert.are.equal(14, kinds['LIMITE'])       -- const
    assert.are.equal(13, kinds['opciones'])     -- parámetro
    assert.are.equal(12, kinds['factorial'])    -- function expression con nombre
  end)

  it('definición de una función global declarada en otro <script> de la página', function()
    assert.are.equal(line_of('function inicializar('),
      def_line('inicializar({ inicio', 'inicializar'))
  end)

  it('variable local y global homónimas resuelven cada una a la suya', function()
    -- dentro de inicializar: el `var contador` local
    assert.are.equal(line_of('var contador = opciones'),
      def_line('return contador + LIMITE', 'contador'))
    -- en otro <script>, a nivel global: el `var contador` global
    assert.are.equal(line_of('var contador = 0'),
      def_line('carrito.agregar(contador)', 'contador'))
  end)

  it('resuelve un parámetro', function()
    assert.are.equal(line_of('function inicializar('),
      def_line('var contador = opciones', 'opciones'))
  end)

  it('método de clase: parámetro y local del método, y la clase desde new', function()
    assert.are.equal(line_of('agregar(item) {'), def_line('var total = item', 'item'))
    -- `total` del método, no el `var total` global homónimo
    assert.are.equal(line_of('var total = item'), def_line('return total;', 'total'))
    assert.are.equal(line_of('class Carrito'), def_line('new Carrito()', 'Carrito'))
  end)

  it('el nombre de una function expression sólo es visible dentro de ella', function()
    assert.are.equal(line_of('function factorial(k)'),
      def_line('k * factorial(k - 1)', 'factorial'))
    assert.is_nil(js.definition(0, pos_in('var fuera = typeof factorial', 'factorial')))
  end)

  it('el nombre de una función resuelve a ella aunque un local de su cuerpo lo sombree', function()
    assert.are.equal(line_of('function cola()'), def_line('function cola()', 'cola'))
    assert.are.equal(line_of('var cola = []'), def_line('return cola;', 'cola'))
    local refs = js.references(0, pos_in('function cola()', 'cola'))
    assert.are.equal(1, #refs)
  end)

  it('resuelve el parámetro de una arrow function sin paréntesis', function()
    assert.are.equal(line_of('var duplicados'), def_line('x => x * 2', 'x * 2'))
  end)

  it('un property_identifier (obj.metodo, obj.prop) devuelve nil', function()
    assert.is_nil(js.definition(0, pos_in('carrito.agregar(contador)', 'agregar')))
    assert.is_nil(js.definition(0, pos_in('var contador = opciones.inicio', 'inicio')))
  end)

  it('cursor en VBScript: js.definition devuelve nil y la capa VBScript sigue resolviendo', function()
    local pos = pos_in('saludo = "hola"', 'saludo')
    assert.is_nil(js.definition(0, pos))
    local loc = require('asp.symbols').definition(0, pos)
    assert.is_not_nil(loc)
    assert.are.equal(line_of('Dim saludo'), loc.range.start.line)
  end)

  it('ignora <script runat="server">', function()
    assert.is_nil(js.definition(0, pos_in('function soloServidor', 'soloServidor')))
    assert.is_nil(js.definition(0, pos_in('soloServidor();', 'soloServidor')))
  end)

  it('ignora <script type="text/template">', function()
    assert.is_nil(js.definition(0, pos_in('function enPlantilla', 'enPlantilla')))
    assert.is_nil(js.definition(0, pos_in('enPlantilla();', 'enPlantilla')))
  end)

  it('ignora <script language="VBScript"> (VBScript de cliente)', function()
    assert.is_nil(js.references(0, pos_in('Sub BotonCliente_OnClick', 'BotonCliente_OnClick')))
  end)

  it('un bloque con <%= %> adentro no lanza y el JS de alrededor resuelve', function()
    for _, pos in ipairs({
      pos_in('var url = "<%= saludo %>"', 'saludo'),
      pos_in('var veces = <%= Duplicar(2) %>', 'Duplicar'),
      pos_in('var veces = <%= Duplicar(2) %>', '<%='),
    }) do
      local ok, loc = pcall(js.definition, 0, pos)
      assert.is_true(ok)
      assert.is_nil(loc, 'el VBScript de un <%= %> no es un identificador JS')
      local rok, refs = pcall(js.references, 0, pos)
      assert.is_true(rok)
      assert.is_nil(refs, 'el VBScript de un <%= %> no es un identificador JS')
    end
    -- La declaración que sigue al `<%= %>` usado como valor sigue siendo una
    -- function_declaration global (no se la traga la recuperación de errores).
    assert.are.equal(line_of('var url ='), def_line('return url + veces', 'url'))
    assert.are.equal(line_of('var veces ='), def_line('return url + veces', 'veces'))
    local usar
    for _, e in ipairs(js.collect(0)) do
      if e.name == 'usarUrl' then usar = e end
      -- `var <%= saludo %> = 0;`: el relleno del <%= %> no es una declaración
      assert.is_nil(e.name:match('^_+$'), 'declaración con nombre de relleno')
    end
    assert.is_not_nil(usar)
    assert.are.equal(12, usar.kind)
    assert.is_nil(usar.scope)
  end)

  it('references devuelve la declaración y los usos del mismo binding', function()
    local refs = js.references(0, pos_in('carrito.agregar(contador)', 'contador'))
    local lines = {}
    for _, r in ipairs(refs) do lines[r.range.start.line] = true end
    -- el global: declaración + sus dos usos globales
    assert.is_true(lines[line_of('var contador = 0')])
    assert.is_true(lines[line_of('carrito.agregar(contador)')])
    assert.is_true(lines[line_of('var total = calcular(contador)')])
    -- no el `contador` local de inicializar (declaración ni uso)
    assert.is_nil(lines[line_of('var contador = opciones')])
    assert.is_nil(lines[line_of('return contador + LIMITE')])
    assert.are.equal(3, #refs)
  end)

  it('references de un local se confina a su función', function()
    local refs = js.references(0, pos_in('return contador + LIMITE', 'contador'))
    local lines = {}
    for _, r in ipairs(refs) do lines[r.range.start.line] = true end
    assert.is_true(lines[line_of('var contador = opciones')])
    assert.is_true(lines[line_of('return contador + LIMITE')])
    assert.are.equal(2, #refs)
  end)

  it('es case-sensitive', function()
    -- `carrito` (la instancia) no resuelve a `Carrito` (la clase)
    assert.are.equal(line_of('var carrito = new'),
      def_line('carrito.agregar(contador)', 'carrito'))
  end)

  it('document_symbols lista funciones y clases globales con detail javascript', function()
    local by_name = {}
    for _, s in ipairs(js.document_symbols(0)) do by_name[s.name] = s end
    assert.are.equal(12, by_name['inicializar'].kind)
    assert.are.equal('javascript', by_name['inicializar'].detail)
    assert.are.equal(12, by_name['usarUrl'].kind)
    assert.are.equal(5, by_name['Carrito'].kind)
    assert.are.equal('agregar', by_name['Carrito'].children[1].name)
    assert.are.equal(6, by_name['Carrito'].children[1].kind)
    -- variables y function expressions fuera del outline
    assert.is_nil(by_name['contador'])
    assert.is_nil(by_name['factorial'])
  end)

  it('sin parser javascript devuelve nil en silencio', function()
    -- `error` cubre las dos firmas: Neovim 0.10 lanza si falta el parser y
    -- 0.11+ devuelve nil + mensaje (ambas terminan en "no disponible").
    local add = vim.treesitter.language.add
    vim.treesitter.language.add = function(lang, ...)
      if lang == 'javascript' then error('no hay parser') end
      return add(lang, ...)
    end
    -- Edición trivial: invalida el caché por changedtick.
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { '' })
    local ok, loc = pcall(js.definition, 0, pos_in('inicializar({ inicio', 'inicializar'))
    local rok, refs = pcall(js.references, 0, pos_in('inicializar({ inicio', 'inicializar'))
    vim.treesitter.language.add = add
    assert.is_true(ok)
    assert.is_nil(loc)
    assert.is_true(rok)
    assert.is_nil(refs)
  end)

  it('la falta de parser no se cachea: resuelve en cuanto aparece, sin editar', function()
    local add = vim.treesitter.language.add
    vim.treesitter.language.add = function(lang, ...)
      if lang == 'javascript' then error('no hay parser') end
      return add(lang, ...)
    end
    local ok, loc = pcall(js.definition, 0, pos_in('inicializar({ inicio', 'inicializar'))
    vim.treesitter.language.add = add
    assert.is_true(ok)
    assert.is_nil(loc)
    assert.are.equal(line_of('function inicializar('),
      def_line('inicializar({ inicio', 'inicializar'))
  end)
end)

describe('asp.js casos borde', function()
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
    local p = pos_of(text)
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

  it('un identificador pegado a un <%= %> es VBScript aunque coincida con uno real', function()
    setup({
      '<script>',
      'var foo______ = 1;',
      'foo<%=x%>();',
      'var bar<%= sufijo %> = 1;',
      'bar<%= sufijo %>++;',
      '</script>',
    })
    -- `foo<%=x%>` se parsea como `foo______`, homónimo del `var` real.
    for _, pos in ipairs({
      pos_in('foo<%=x%>', 'x%>'),
      pos_in('foo<%=x%>', 'foo'),
      pos_in('bar<%= sufijo %>++', 'sufijo'),
      pos_in('bar<%= sufijo %>++', 'bar'),
    }) do
      assert.is_nil(js.definition(0, pos))
      assert.is_nil(js.references(0, pos))
    end
    assert.are.equal(1, #js.references(0, pos_in('var foo______', 'foo______')))
    for _, e in ipairs(js.collect(0)) do
      assert.is_nil(e.name:match('^bar'), 'declaración pegada a un <%= %>: ' .. e.name)
    end
  end)

  it('los parámetros y locales sombrean el nombre de una function expression', function()
    setup({
      '<script>',
      'const f = function inner(inner) { return inner; };',
      'const g = function propio() { var propio = 1; return propio; };',
      '</script>',
    })
    local name, param, use = nth('const f', 'inner', 1), nth('const f', 'inner', 2), nth('const f', 'inner', 3)
    assert.are.same(param, def_pos(use))
    assert.are.equal(2, #js.references(0, use))
    -- el nombre mismo sigue resolviendo a la función
    assert.are.same(name, def_pos(name))
    assert.are.equal(1, #js.references(0, name))
    assert.are.same(nth('const g', 'propio', 2), def_pos(nth('const g', 'propio', 3)))
  end)

  it('la x de { x } es un uso de la variable x', function()
    setup({
      '<script>',
      'const x = 1;',
      'const o = { x };',
      'console.log(x);',
      '</script>',
    })
    assert.are.same(pos_in('const x', 'x'), def_pos(pos_in('const o = { x }', 'x')))
    local lines = {}
    for _, r in ipairs(js.references(0, pos_in('const x', 'x'))) do
      lines[r.range.start.line] = true
    end
    assert.are.same({ [1] = true, [2] = true, [3] = true }, lines)
  end)

  it('un nombre sin declaración en la página no tiene definición ni referencias', function()
    setup({
      '<script>',
      'function a() { unknown(); }',
      'function b() { unknown(); }',
      '</script>',
    })
    assert.is_nil(js.definition(0, pos_in('function a', 'unknown')))
    assert.is_nil(js.references(0, pos_in('function a', 'unknown')))
  end)

  it('references no crece con el número de declaraciones homónimas', function()
    -- 2900 funciones con un parámetro `data` cada una (8700 líneas).
    local lines = { '<script>' }
    for i = 1, 2900 do
      lines[#lines + 1] = 'function f' .. i .. '(data) {'
      lines[#lines + 1] = '  consume(data); return data;'
      lines[#lines + 1] = '}'
    end
    lines[#lines + 1] = '</script>'
    setup(lines)
    local pos = { line = 3 * 1449 + 2, character = #'  consume(' }
    assert.are.equal(pos.line - 1, js.definition(0, pos).range.start.line) -- caché caliente

    local t0 = vim.uv.hrtime()
    local refs = js.references(0, pos)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    assert.are.equal(3, #refs)
    -- Con la resolución cuadrática tardaba ~1,1 s en una máquina de
    -- desarrollo; con el índice por scope, ~1 ms. Umbral holgado para
    -- runners lentos de CI.
    assert.is_true(ms < 250, ('references tardó %.1f ms'):format(ms))
  end)
end)

describe('asp-ls JavaScript', function()
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

  it('textDocument/definition resuelve un identificador JS', function()
    local loc = request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_in('inicializar({ inicio', 'inicializar'),
    })
    assert.is_not_nil(loc)
    assert.are.equal(line_of('function inicializar('), loc.range.start.line)
  end)

  it('textDocument/definition sobre VBScript sigue yendo a la capa VBScript', function()
    local loc = request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_in('<p><%= Duplicar(saludo)', 'Duplicar'),
    })
    assert.is_not_nil(loc)
    assert.are.equal(line_of('Function Duplicar'), loc.range.start.line)
  end)

  it('textDocument/references pasa a la capa JS fuera de VBScript', function()
    local refs = request('textDocument/references', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_in('return contador + LIMITE', 'LIMITE'),
      context = { includeDeclaration = true },
    })
    assert.is_not_nil(refs)
    local lines = {}
    for _, r in ipairs(refs) do lines[r.range.start.line] = true end
    assert.is_true(lines[line_of('const LIMITE')])
    assert.is_true(lines[line_of('return contador + LIMITE')])
    assert.is_true(lines[line_of('inicializar({ inicio: LIMITE })')])
  end)

  it('textDocument/references fuera de VBScript y de JS devuelve {} (no nil)', function()
    local refs = request('textDocument/references', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_of('</head>'),
      context = { includeDeclaration = true },
    })
    assert.are.same({}, refs)
  end)

  it('textDocument/documentSymbol incluye las funciones JS tras las de VBScript', function()
    local syms = request('textDocument/documentSymbol', {
      textDocument = vim.lsp.util.make_text_document_params(),
    })
    local by_name = {}
    for _, s in ipairs(syms) do by_name[s.name] = s end
    assert.is_not_nil(by_name['Duplicar'])
    assert.is_nil(by_name['Duplicar'].detail)
    assert.are.equal('javascript', by_name['inicializar'].detail)
  end)
end)
