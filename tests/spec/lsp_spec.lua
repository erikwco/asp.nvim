describe('asp-ls', function()
  before_each(function()
    vim.cmd.edit('tests/fixtures/symbols.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  it('se adjunta automáticamente a buffers asp', function()
    local clients = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })
    assert.are.equal(1, #clients)
  end)

  it('negocia utf-8 y anuncia sus capacidades', function()
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    assert.are.equal('utf-8', client.offset_encoding)
    assert.is_true(client.server_capabilities.documentSymbolProvider)
    assert.is_true(client.server_capabilities.definitionProvider)
    assert.is_true(client.server_capabilities.documentHighlightProvider)
  end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do
      return r.result
    end
    return nil
  end

  it('documentSymbol devuelve outline jerárquico', function()
    local syms = request('textDocument/documentSymbol', {
      textDocument = vim.lsp.util.make_text_document_params(),
    })
    assert.is_not_nil(syms)
    local by_name = {}
    for _, s in ipairs(syms) do by_name[s.name] = s end
    assert.are.equal(5, by_name['Pedido'].kind)
    assert.are.equal(12, by_name['CalcularTotal'].kind)
    assert.are.equal(13, by_name['total'].kind)
    local children = {}
    for _, c in ipairs(by_name['Pedido'].children or {}) do children[c.name] = c end
    assert.is_not_nil(children['Agregar'])
    assert.is_not_nil(children['m_total'])
    -- Task-1 fix agregó Public Property Let Total(nuevoTotal) a la fixture:
    -- la property es miembro de la clase (kind 7); su parámetro nuevoTotal
    -- tiene scope_id ≠ nil y no debe aparecer en el outline.
    assert.is_not_nil(children['Total'])
    assert.are.equal(7, children['Total'].kind)
    -- locales de función fuera del outline:
    assert.is_nil(by_name['recargo'])
    assert.is_nil(by_name['monto'])
    assert.is_nil(by_name['nuevoTotal'])
  end)

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

  local function line_of(text)
    return pos_of(text).line
  end

  local function definition_at(pos)
    return request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos,
    })
  end

  it('definition salta a la Function desde su llamada', function()
    local loc = definition_at(pos_of('CalcularTotal(total)'))
    assert.is_not_nil(loc)
    assert.are.equal(line_of('Function CalcularTotal'), loc.range.start.line)
  end)

  it('definition es case-insensitive', function()
    local loc = definition_at(pos_of('mostrar'))
    assert.are.equal(line_of('Sub Mostrar'), loc.range.start.line)
  end)

  it('definition prefiere el scope local y cae a página', function()
    -- 'recargo' usado dentro de CalcularTotal → Dim recargo local
    local loc = definition_at(pos_of('recargo = base'))
    assert.are.equal(line_of('Dim recargo'), loc.range.start.line)
    -- 'total' usado dentro de Mostrar → Dim de página
    local loc2 = definition_at(pos_of('CalcularTotal(total)'))
    -- (posiciona sobre 'total' dentro del paréntesis:)
    local p = pos_of('CalcularTotal(total)')
    p.character = p.character + #('CalcularTotal(')
    local loc3 = definition_at(p)
    assert.are.equal(line_of('Dim total'), loc3.range.start.line)
    assert.is_not_nil(loc2)
  end)

  -- Nota: este spec pinnea el comportamiento determinista del lookup
  -- confinado a un árbol propio por capa; el race original solo era
  -- observable a escala real (decenas de árboles inyectados), no con este
  -- fixture.
  it('definition en un bloque <script> cliente (JS/regex) resuelve vía la capa JS de forma estable', function()
    -- Regresión del bug de carrera: asp.symbols confina la búsqueda al árbol
    -- vbscript inyectado (una posición en <script> no tiene definición
    -- VBScript) y asp.js a su propio parser javascript, sin tocar el árbol
    -- de inyecciones del highlighter. `foo` resuelve a su propia
    -- declaración, siempre igual entre llamadas sucesivas.
    local pos = pos_of('function foo()')
    pos.character = pos.character + #('function ')
    for i = 1, 5 do
      local loc = definition_at(pos)
      assert.is_not_nil(loc, 'llamada ' .. i .. ' de 5 devolvió nil')
      assert.are.equal(pos.line, loc.range.start.line, 'llamada ' .. i .. ' de 5')
      assert.are.equal(pos.character, loc.range.start.character, 'llamada ' .. i .. ' de 5')
    end
  end)
end)

describe('asp-ls documentHighlight', function()
  after_each(function() vim.cmd('bwipeout!') end)

  local function open(path, lines)
    vim.cmd.edit('tests/fixtures/' .. path)
    if lines then vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
    assert.is_true(vim.wait(2000, function()
      local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
      return client and client.initialized
    end))
  end

  local function highlights(line, character)
    local resp = vim.lsp.buf_request_sync(0, 'textDocument/documentHighlight', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = { line = line, character = character },
    }, 3000)
    assert.is_not_nil(resp)
    for _, r in pairs(resp) do
      assert.is_nil(r.err)
      return r.result
    end
    error('asp-ls no respondió a documentHighlight')
  end

  local function highlight(line, character, name, kind)
    return {
      range = {
        start = { line = line, character = character },
        ['end'] = { line = line, character = character + #name },
      },
      kind = kind,
    }
  end

  it('resalta la declaración VBScript como Write y los usos como Read sin distinguir mayúsculas', function()
    open('proyecto/scratch_highlight.asp', {
      '<%', 'Dim total', 'total = 2', 'Response.Write TOTAL', '%>',
    })
    assert.are.same({
      highlight(1, 4, 'total', 3),
      highlight(2, 0, 'total', 2),
      highlight(3, 15, 'TOTAL', 2),
    }, highlights(3, 17))
  end)

  it('confina los locales VBScript al scope de su declaración', function()
    open('proyecto/locales.asp')
    assert.are.same({
      highlight(2, 6, 'contador', 3),
      highlight(3, 2, 'contador', 2),
      highlight(4, 12, 'contador', 2),
    }, highlights(3, 3))
  end)

  it('resalta una función JS global desde su onclick y desde su uso en script', function()
    open('proyecto/scratch_highlight.asp', {
      '<script>',
      'function pagar() {}',
      'pagar();',
      '</script>',
      '<button onclick="pagar()">Pagar</button>',
    })
    local expected = {
      highlight(1, 9, 'pagar', 3),
      highlight(2, 0, 'pagar', 2),
      highlight(4, 17, 'pagar', 2),
    }
    assert.are.same(expected, highlights(4, 18))
    assert.are.same(expected, highlights(2, 1))
    assert.are.same(expected, highlights(1, 10))
  end)

  it('excluye las referencias VBScript de otros archivos', function()
    open('proyecto/default.asp')
    assert.are.same({ highlight(9, 14, 'FormatearMoneda', 2) }, highlights(9, 15))
  end)

  it('excluye las referencias JS externas y los locales homónimos', function()
    open('js/crossfile/pagina.asp')
    assert.are.same({ highlight(15, 0, 'desdeSrc', 2) }, highlights(15, 1))
  end)

  it('usa Text cuando VBScript no tiene una declaración resuelta', function()
    open('proyecto/scratch_highlight.asp', {
      '<%', 'sinDeclarar = 1', 'Response.Write sinDeclarar', '%>',
    })
    assert.are.same({
      highlight(1, 0, 'sinDeclarar', 1),
      highlight(2, 15, 'sinDeclarar', 1),
    }, highlights(1, 1))
  end)

  it('devuelve una lista vacía fuera de un símbolo y sobre un JS sin binding', function()
    open('proyecto/scratch_highlight.asp', {
      '<html>', '<script>sinDeclarar();</script>', '</html>',
    })
    assert.are.same({}, highlights(0, 0))
    assert.are.same({}, highlights(1, 10))
  end)

  it('no resalta usos de página ni desde un literal ni desde el archivo abierto', function()
    open('proyecto/paginas/inicio.asp')
    assert.are.same({}, highlights(1, 10))
    vim.cmd('bwipeout!')
    open('proyecto/paginas/otra.asp')
    assert.are.same({}, highlights(0, 0))
  end)

  it('no lanza ni devuelve un error LSP ante una posición inválida', function()
    open('proyecto/default.asp')
    assert.are.same({}, highlights(-1, -1))
  end)
end)

describe('asp-ls cross-file', function()
  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

  before_each(function()
    vim.cmd.edit(FIX .. '/default.asp')
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

  local function pos_of(text)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      local col = line:find(text, 1, true)
      if col then return { line = i - 1, character = col - 1 } end
    end
    error('texto no encontrado: ' .. text)
  end

  local function definition_at(pos)
    return request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos,
    })
  end

  it('salta a una Function definida en un include file', function()
    local loc = definition_at(pos_of('FormatearMoneda'))
    assert.is_not_nil(loc)
    assert.is_truthy(loc.uri:find('includes/helpers%.asp$'))
  end)

  it('salta a una Const definida en un include anidado', function()
    local loc = definition_at(pos_of('IVA'))
    assert.is_truthy(loc.uri:find('includes/constantes%.inc$'))
  end)

  it('salta a una Function de un include virtual', function()
    local loc = definition_at(pos_of('AbrirConexion'))
    assert.is_truthy(loc.uri:find('lib/db%.inc$'))
  end)

  it('cross-file es case-insensitive', function()
    local loc = definition_at(pos_of('respuestarapida'))
    assert.is_truthy(loc.uri:find('includes/helpers%.asp$'))
  end)

  it('sobrevive a un grafo con ciclo', function()
    vim.cmd('bwipeout!')
    vim.cmd.edit(FIX .. '/ciclo_a.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
    local loc = definition_at(pos_of('FuncionB()'))
    assert.is_truthy(loc.uri:find('ciclo_b%.asp$'))
  end)

  it('references encuentra usos y definición en todo el grafo', function()
    local refs = request('textDocument/references', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_of('FormatearMoneda'),
      context = { includeDeclaration = true },
    })
    -- default.asp: 1 uso; helpers.asp: nombre en Function + asignación de retorno
    assert.are.equal(3, #refs)
    local files = {}
    for _, r in ipairs(refs) do
      files[r.uri:match('([^/]+)$')] = (files[r.uri:match('([^/]+)$')] or 0) + 1
    end
    assert.are.equal(1, files['default.asp'])
    assert.are.equal(2, files['helpers.asp'])
  end)

  it('workspace/symbol busca case-insensitive en todo el proyecto', function()
    local syms = request('workspace/symbol', { query = 'funcion' })
    local names = {}
    for _, s in ipairs(syms) do names[s.name] = s end
    assert.is_not_nil(names['FuncionA'])
    assert.is_not_nil(names['FuncionB'])
    assert.is_truthy(names['FuncionA'].location.uri:find('ciclo_a%.asp$'))
  end)

  it('root_dir del cliente es el web.config más cercano, no el .git del repo', function()
    -- proyecto/web.config está más cerca de default.asp que el .git del
    -- repo; root_dir debe ser proyecto/, no la raíz del plugin.
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    assert.is_not_nil(client)
    assert.is_truthy(client.config.root_dir:match('tests/fixtures/proyecto$'))
  end)

  it('references con conciencia de scope: locales homónimos en dos Functions no se conflacionan', function()
    vim.cmd('bwipeout!')
    vim.cmd.edit(FIX .. '/locales.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
    local segunda_line = pos_of('Function Segunda').line
    local refs = request('textDocument/references', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_of('contador = 1'),
      context = { includeDeclaration = true },
    })
    assert.is_not_nil(refs)
    assert.are.equal(3, #refs)
    for _, r in ipairs(refs) do
      assert.is_true(r.range.start.line < segunda_line)
    end
  end)
end)

describe('asp-ls hover', function()
  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

  before_each(function()
    vim.cmd.edit(FIX .. '/default.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)
  after_each(function() vim.cmd('bwipeout!') end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do return r.result end
  end
  local function pos_of(text)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      local c = line:find(text, 1, true)
      if c then return { line = i - 1, character = c - 1 } end
    end
    error('no encontrado: ' .. text)
  end
  local function hover_at(pos)
    return request('textDocument/hover', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos,
    })
  end

  it('hover sobre un objeto intrínseco (Response)', function()
    local h = hover_at(pos_of('Response'))
    assert.is_not_nil(h)
    assert.are.equal('markdown', h.contents.kind)
    assert.is_true(h.contents.value:find('Response') ~= nil)
  end)

  it('hover sobre un miembro intrínseco (Server.CreateObject)', function()
    local p = pos_of('CreateObject')
    local h = hover_at(p)
    assert.is_true(h.contents.value:find('CreateObject') ~= nil)
    assert.is_true(h.contents.value:find('ProgID') ~= nil)
  end)

  it('hover sobre un símbolo de usuario muestra su declaración', function()
    -- default.asp usa FormatearMoneda (definido en include); en el buffer
    -- actual hay 'totalPagina' (Dim de página) — hover muestra su línea.
    local h = hover_at(pos_of('totalPagina'))
    assert.is_not_nil(h)
    assert.is_true(h.contents.value:lower():find('totalpagina') ~= nil)
  end)

  it('hover sobre algo desconocido devuelve nil', function()
    local h = hover_at(pos_of('<html>'))
    assert.is_nil(h)
  end)
end)

describe('asp-ls completion', function()
  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')
  after_each(function() vim.cmd('bwipeout!') end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do return r.result end
  end

  local function complete_line(text_line)
    -- crea un buffer asp con una sola línea de código y pide completion
    -- al final de la línea
    vim.cmd.edit(FIX .. '/scratch_complete.asp')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '<%', text_line, '%>' })
    vim.bo.filetype = 'asp'
    require('asp.lsp').start(0)
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
    local items = request('textDocument/completion', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = { line = 1, character = #text_line },
    })
    return items and (items.items or items) or {}
  end

  local function labels(items)
    local out = {}
    for _, it in ipairs(items) do out[it.label] = true end
    return out
  end

  it('tras Response. ofrece los miembros del objeto', function()
    local items = complete_line('Response.')
    local l = labels(items)
    assert.is_true(l['Write'], 'esperaba Write')
    assert.is_true(l['Redirect'], 'esperaba Redirect')
    assert.is_nil(l['CreateObject']) -- ese es de Server
  end)

  it('tras Server.Cr filtra por prefijo case-insensitive', function()
    local items = complete_line('Server.cr')
    local l = labels(items)
    assert.is_true(l['CreateObject'])
    assert.is_nil(l['MapPath'])
  end)

  it('sin punto ofrece objetos intrínsecos y símbolos', function()
    local items = complete_line('Res')
    local l = labels(items)
    assert.is_true(l['Response'])
  end)

  -- Regresión E565: un servidor in-process que responde SINCRÓNICAMENTE hace
  -- que la maquinaria de completion de Neovim llame vim.fn.complete() dentro
  -- de un contexto restringido → "E565: Not allowed to change text". El fix
  -- difiere la respuesta con vim.schedule (como un servidor real, async).
  it('el servidor responde de forma diferida, no sincrónica', function()
    vim.cmd.edit(FIX .. '/default.asp')
    vim.bo.filetype = 'asp'
    require('asp.lsp').start(0)
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
    local fired = false
    vim.lsp.buf_request(0, 'textDocument/documentSymbol',
      { textDocument = vim.lsp.util.make_text_document_params() },
      function() fired = true end)
    -- Sincrónico dispararía el callback aquí mismo; diferido, todavía no.
    assert.is_false(fired, 'la respuesta fue sincrónica (regresión E565)')
    vim.wait(1000, function() return fired end)
    assert.is_true(fired, 'la respuesta nunca llegó')
  end)
end)

describe('asp-ls límite: múltiples <%= %> en una línea', function()
  -- LIMITACIÓN CONOCIDA: bloques <%= %> múltiples en una línea se fusionan
  -- por la injection combinada; hover/definition no resuelven ahí. Ver README.
  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

  before_each(function()
    vim.cmd.edit(FIX .. '/inline_multi.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)

  after_each(function() vim.cmd('bwipeout!') end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do return r.result end
  end

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

  local function definition_at(pos)
    return request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos,
    })
  end

  it('definition sobre precio en su Dim de página (bloque standalone) funciona', function()
    -- 1ª ocurrencia de 'precio' es el propio Dim de la línea 2, en un
    -- bloque <% %> standalone (no adyacente a otro <%= %> en la misma
    -- línea): esto SIGUE funcionando, prueba de que la limitación es
    -- específica de bloques <%= %> adyacentes en una línea, no de todos
    -- los ecos.
    local loc = definition_at(pos_of('precio', 1))
    assert.is_not_nil(loc)
    assert.are.equal(1, loc.range.start.line)
  end)

  it('definition sobre precio DENTRO de <%=precio%> adyacente a otro bloque en la misma línea devuelve nil', function()
    -- 3ª ocurrencia de 'precio': dentro de <%=precio%>, en la línea
    -- <table><tr><td><%=precio%></td><td><%=cantidad%></td></tr></table>,
    -- adyacente a otro bloque <%=cantidad%>. La injection combinada fusiona
    -- ambos bloques en una sola región vbscript cuyo root no confina
    -- correctamente la búsqueda por (row,col) a este bloque — pinneamos el
    -- comportamiento actual (nil) para que un futuro fix sea detectable.
    local loc = definition_at(pos_of('precio', 3))
    assert.is_nil(loc)
  end)
end)
