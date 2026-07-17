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

  it('definition en un bloque <script> cliente (JS/regex) devuelve nil de forma estable', function()
    -- Regresión del bug de carrera: M.definition confinaba la búsqueda al
    -- árbol vbscript inyectado; una posición dentro de <script> (capa
    -- javascript/regex, no vbscript) no tiene definición VBScript posible y
    -- debe devolver nil siempre, sin flakiness entre llamadas sucesivas.
    local pos = pos_of('function foo()')
    pos.character = pos.character + #('function ')
    for i = 1, 5 do
      local loc = definition_at(pos)
      assert.is_nil(loc, 'llamada ' .. i .. ' de 5 devolvió non-nil')
    end
  end)
end)
