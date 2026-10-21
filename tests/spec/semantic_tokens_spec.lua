local FIX = vim.fn.fnamemodify('tests/fixtures/semantico', ':p'):gsub('/$', '')

local semantic = require('asp.semantic_tokens')
local legend = semantic.legend

---Decodifica `data` (codificación relativa de LSP) a una lista de tokens
---{line, col, len, text, type, mods} con el texto del buffer actual.
---Verifica de paso que los deltas y el orden sean válidos.
local function decode(data)
  assert.are.equal(0, #data % 5, 'data no tiene grupos de 5')
  local out, row, col, prev_end = {}, 0, 0, -1
  for i = 1, #data, 5 do
    local dl, dc, len, ty, mods = data[i], data[i + 1], data[i + 2], data[i + 3], data[i + 4]
    assert.is_true(dl >= 0 and dc >= 0 and len > 0, 'delta o largo inválido')
    if dl > 0 then
      row, col, prev_end = row + dl, dc, -1
    else
      col = col + dc
      if i > 1 then assert.is_true(dc > 0, 'tokens desordenados') end
    end
    assert.is_true(col >= prev_end, 'tokens solapados')
    prev_end = col + len
    local line = vim.api.nvim_buf_get_lines(0, row, row + 1, true)[1]
    local set = {}
    for j, name in ipairs(legend.tokenModifiers) do
      if bit.band(mods, bit.lshift(1, j - 1)) ~= 0 then set[name] = true end
    end
    assert.is_truthy(legend.tokenTypes[ty + 1], 'tipo fuera de la leyenda')
    out[#out + 1] = {
      line = row, col = col, len = len, text = line:sub(col + 1, col + len),
      type = legend.tokenTypes[ty + 1], mods = set,
    }
  end
  return out
end

---Token en la `occurrence`-ésima aparición de la palabra `needle` desde
---`context` (texto literal) en su línea, o nil.
local function token_at(tokens, context, needle, occurrence)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
  for row, line in ipairs(lines) do
    local at = line:find(context, 1, true)
    if at then
      local init, n = at, 0
      while true do
        local s = line:find('%f[%w_]' .. vim.pesc(needle) .. '%f[^%w_]', init)
        assert(s, ('"%s" no está en "%s"'):format(needle, line))
        n = n + 1
        if n == (occurrence or 1) then
          for _, t in ipairs(tokens) do
            if t.line == row - 1 and t.col == s - 1 then return t end
          end
          return nil
        end
        init = s + 1
      end
    end
  end
  error('contexto no encontrado: ' .. context)
end

local function mods_of(t)
  local list = vim.tbl_keys(t.mods)
  table.sort(list)
  return table.concat(list, ',')
end

---Tipo y modificadores de un token, para comparar de una vez.
local function kind(tokens, context, needle, occurrence)
  local t = token_at(tokens, context, needle, occurrence)
  if not t then return nil end
  assert.are.equal(needle, t.text)
  return t.type .. '/' .. mods_of(t)
end

describe('asp.semantic_tokens', function()
  local tokens

  before_each(function()
    vim.cmd.edit(FIX .. '/pagina.asp')
    tokens = decode(semantic.full(0).data)
  end)

  after_each(function()
    vim.cmd('silent! %bwipeout!')
  end)

  it('Function del usuario en su declaración y en una llamada', function()
    assert.are.equal('function/declaration', kind(tokens, 'Function Sumar(a, b)', 'Sumar'))
    assert.are.equal('function/', kind(tokens, 'total = Sumar(1, MAX)', 'Sumar'))
    -- Dentro de la Function, el nombre es su valor de retorno.
    assert.are.equal('function/', kind(tokens, 'Sumar = a + b + MAX', 'Sumar'))
  end)

  it('parámetros en su declaración y en sus usos', function()
    assert.are.equal('parameter/declaration', kind(tokens, 'Function Sumar(a, b)', 'a'))
    assert.are.equal('parameter/declaration', kind(tokens, 'Function Sumar(a, b)', 'b'))
    assert.are.equal('parameter/', kind(tokens, 'Sumar = a + b + MAX', 'a'))
    assert.are.equal('parameter/', kind(tokens, 'max = a', 'a'))
  end)

  it('variable local frente a una Const de página homónima', function()
    -- VBScript no distingue mayúsculas: dentro de Sumar, MAX es el local max.
    assert.are.equal('variable/declaration', kind(tokens, '  Dim max', 'max'))
    assert.are.equal('variable/', kind(tokens, 'max = a', 'max'))
    assert.are.equal('variable/', kind(tokens, 'Sumar = a + b + MAX', 'MAX'))
    -- Fuera, MAX es la Const de página: readonly.
    assert.are.equal('variable/declaration,readonly', kind(tokens, 'Const MAX = 10', 'MAX'))
    assert.are.equal('variable/readonly', kind(tokens, 'total = Sumar(1, MAX)', 'MAX'))
    assert.are.equal('variable/declaration', kind(tokens, 'Dim total, c', 'total'))
    assert.are.equal('variable/', kind(tokens, 'total = Sumar(1, MAX)', 'total'))
  end)

  it('miembros de clase, también por Me', function()
    assert.are.equal('class/declaration', kind(tokens, 'Class Caja', 'Caja'))
    assert.are.equal('property/declaration', kind(tokens, 'Private m_total', 'm_total'))
    assert.are.equal('method/declaration', kind(tokens, 'Public Sub Agregar(x)', 'Agregar'))
    assert.are.equal('property/', kind(tokens, 'm_total = m_total + x', 'm_total', 2))
    assert.are.equal('property/', kind(tokens, 'Me.m_total', 'm_total'))
  end)

  it('la clase en New', function()
    assert.are.equal('class/', kind(tokens, 'Set c = New Caja', 'Caja'))
    assert.are.equal('variable/', kind(tokens, 'Set c = New Caja', 'c'))
  end)

  it('nativos e intrínsecos con defaultLibrary', function()
    assert.are.equal('function/defaultLibrary', kind(tokens, 'Len("Sumar")', 'Len'))
    assert.are.equal('namespace/defaultLibrary', kind(tokens, 'Response.Write', 'Response'))
    assert.are.equal('method/defaultLibrary', kind(tokens, 'Response.Write', 'Write'))
    assert.are.equal('variable/defaultLibrary,readonly', kind(tokens, '& vbCrLf', 'vbCrLf'))
  end)

  it('no atribuye miembros de cadenas desconocidas a Response ni a Me', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      '<%', 'Class Caja', 'Private total', 'Sub Mostrar()',
      'obj. Response.Write 1', 'obj. Me.total = 2',
      'obj. _', ' Response.Write 3', 'End Sub', 'End Class', '%>',
    })
    local actual = decode(semantic.full(0).data)
    assert.is_nil(token_at(actual, 'obj. Response.Write', 'Write'))
    assert.is_nil(token_at(actual, 'obj. Me.total', 'total'))
    assert.is_nil(token_at(actual, ' Response.Write 3', 'Write'))
  end)

  it('resuelve miembros conocidos con continuación antes o después del punto', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      '<%', 'Class Caja', 'Private total', 'Sub Mostrar()',
      'Response. _', ' Write 1', 'Me. _', ' total = 2',
      'Response _', ' .Buffer = True', 'End Sub', 'End Class', '%>',
    })
    local actual = decode(semantic.full(0).data)
    assert.are.equal('method/defaultLibrary', kind(actual, ' Write 1', 'Write'))
    assert.are.equal('property/', kind(actual, ' total = 2', 'total'))
    assert.are.equal('property/defaultLibrary', kind(actual, ' .Buffer', 'Buffer'))
  end)

  it('una Function declarada en un include', function()
    assert.are.equal('function/', kind(tokens, 'Redondear(total)', 'Redondear'))
  end)

  it('JavaScript: función, parámetro, variable, clase y método', function()
    assert.are.equal('function/declaration', kind(tokens, 'function saludar(nombre)', 'saludar'))
    assert.are.equal('parameter/declaration', kind(tokens, 'function saludar(nombre)', 'nombre'))
    assert.are.equal('parameter/', kind(tokens, 'var x = nombre', 'nombre'))
    assert.are.equal('variable/declaration', kind(tokens, 'var x = nombre', 'x'))
    assert.are.equal('class/declaration', kind(tokens, 'class Punto', 'Punto'))
    assert.are.equal('method/declaration', kind(tokens, 'mover(dx)', 'mover'))
    assert.are.equal('parameter/', kind(tokens, 'return dx', 'dx'))
    assert.are.equal('function/', kind(tokens, 'saludar("total")', 'saludar'))
  end)

  it('no hay tokens sobre HTML, strings ni comentarios', function()
    for _, t in ipairs(tokens) do
      assert.is_truthy(t.text:match('^[%a_$][%w_$]*$'), t.text)
    end
    -- "Sumar" en Len("Sumar") y "total" en saludar("total") son strings.
    assert.is_nil(token_at(tokens, 'Len("Sumar")', 'Sumar'))
    assert.is_nil(token_at(tokens, 'saludar("total")', 'total'))
    -- `total:` es HTML; los dos <%= %> pegados sí tienen token.
    assert.is_nil(token_at(tokens, '<p>total:', 'total'))
    assert.are.equal('variable/', kind(tokens, '<p>total:', 'total', 2))
    assert.are.equal('variable/readonly', kind(tokens, '<%=MAX%>', 'MAX'))
    -- Option Explicit y las palabras clave las resalta tree-sitter.
    assert.is_nil(token_at(tokens, 'Option Explicit', 'Explicit'))
  end)

  it('las columnas son bytes UTF-8', function()
    local t = token_at(tokens, 'ñandú', 'total')
    assert.is_not_nil(t)
    local line = vim.api.nvim_buf_get_lines(0, t.line, t.line + 1, true)[1]
    assert.are.equal(line:find('total', 1, true) - 1, t.col)
    assert.is_true(t.col > vim.fn.strchars(line:sub(1, t.col)))
  end)

  it('range devuelve los tokens de esas líneas, con deltas desde su inicio', function()
    local row = token_at(tokens, 'Function Sumar(a, b)', 'Sumar').line
    local data = semantic.range(0, {
      start = { line = row, character = 0 }, ['end'] = { line = row + 1, character = 0 },
    }).data
    -- El primer token se codifica relativo a la fila 0.
    local ranged = decode(data)
    assert.are.same({ 'Sumar', 'a', 'b' }, vim.tbl_map(function(t) return t.text end, ranged))
  end)

  it('nunca lanza: sin parser o con un buffer inválido devuelve data vacía', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Dim x' })
    assert.are.same({ data = {} }, semantic.full(buf))
    assert.are.same({ data = {} }, semantic.full(99999))
    assert.are.same({ data = {} }, semantic.range(99999, {
      start = { line = 0, character = 0 }, ['end'] = { line = 1, character = 0 },
    }))
  end)
end)

describe('asp-ls: semanticTokens', function()
  local previous

  before_each(function()
    previous = require('asp').options.semantic_tokens
    vim.cmd.edit(FIX .. '/pagina.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)

  after_each(function()
    require('asp').options.semantic_tokens = previous
    vim.cmd('silent! %bwipeout!')
  end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do return r.result, r.err end
  end

  it('anuncia la leyenda con full y range', function()
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    local provider = client.server_capabilities.semanticTokensProvider
    assert.is_not_nil(provider)
    assert.is_true(provider.full)
    assert.is_true(provider.range)
    assert.are.same(legend, provider.legend)
  end)

  it('full y range por LSP', function()
    local full = request('textDocument/semanticTokens/full', {
      textDocument = vim.lsp.util.make_text_document_params(),
    })
    assert.are.same(semantic.full(0), full)
    local tokens = decode(full.data)
    assert.are.equal('function/declaration', kind(tokens, 'Function Sumar(a, b)', 'Sumar'))
    local range = { start = { line = 0, character = 0 }, ['end'] = { line = 5, character = 0 } }
    local ranged = request('textDocument/semanticTokens/range', {
      textDocument = vim.lsp.util.make_text_document_params(), range = range,
    })
    assert.are.same(semantic.range(0, range), ranged)
  end)

  it('Neovim pide los tokens y los aplica como @lsp.type.*', function()
    local row = vim.fn.search('^Function Sumar', 'n') - 1
    local found
    assert.is_true(vim.wait(3000, function()
      for _, t in ipairs(vim.lsp.semantic_tokens.get_at_pos(0, row, 9) or {}) do
        if t.type == 'function' then found = t end
      end
      return found ~= nil
    end), 'Neovim no aplicó los tokens')
    assert.is_true(found.modifiers.declaration)
    -- Y los vuelve a pedir tras editar.
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, { 'Function Restar(a, b)' })
    assert.is_true(vim.wait(3000, function()
      for _, t in ipairs(vim.lsp.semantic_tokens.get_at_pos(0, row, 9) or {}) do
        if t.type == 'function' and t.end_col == 15 then return true end
      end
      return false
    end), 'Neovim no actualizó los tokens tras la edición')
  end)

  it('setup({ semantic_tokens = false }) no anuncia la capacidad', function()
    require('asp').options.semantic_tokens = false
    assert.is_nil(require('asp.lsp').capabilities().semanticTokensProvider)
    require('asp').options.semantic_tokens = nil
    assert.is_not_nil(require('asp.lsp').capabilities().semanticTokensProvider)
  end)
end)
