-- Texto de cada parámetro según sus offsets [inicio, fin) en el label.
local function param_labels(result)
  local signature = result.signatures[1]
  return vim.tbl_map(function(param)
    assert.are.equal('table', type(param.label))
    return signature.label:sub(param.label[1] + 1, param.label[2])
  end, signature.parameters)
end

describe('catálogos de ayuda VBScript y COM', function()
  local native = require('asp.vbscript_builtins')
  local com = require('asp.com')

  it('conserva los grupos y expone firmas, parámetros y retornos', function()
    for _, entry in ipairs(native.groups.functions) do
      local info = native.lookup(entry[1]:upper())
      assert.are.equal('functions', info.group)
      assert.is_true(#info.signature > 0)
      assert.is_true(#info.doc > 0)
      assert.is_true(#info.returns > 0)
      for _, param in ipairs(info.params) do
        assert.is_true(#param.name > 0)
        assert.are.equal('boolean', type(param.optional))
        assert.is_true(#param.doc > 0, info.name .. '.' .. param.name)
      end
    end
    assert.is_true(native.is_class('regexp'))
    assert.are.equal('keywords', native.lookup('SUB').group)
    assert.are.equal('objects', native.lookup('Err').group)
  end)

  it('describe parámetros opcionales al principio y al final', function()
    local mid = native.lookup('Mid')
    assert.are.equal('Mid(string, start[, length])', mid.signature)
    assert.is_false(mid.params[2].optional)
    assert.is_true(mid.params[3].optional)
    local instr = native.lookup('InStr')
    assert.is_true(instr.params[1].optional)
    assert.is_false(instr.params[2].optional)
    assert.is_false(instr.params[3].optional)
    assert.is_true(instr.params[4].optional)
    assert.are.equal(0, #native.lookup('Now').params)
  end)

  it('expone valores y documentación de todas las constantes', function()
    for _, entry in ipairs(native.groups.constants) do
      local info = native.lookup(entry[1])
      assert.are.equal('constants', info.group)
      assert.is_true(#info.value > 0)
      assert.is_true(#info.doc > 0)
    end
    assert.are.equal('Chr(13) & Chr(10)', native.lookup('vbcrlf').value)
    assert.are.equal('1', native.lookup('vbTextCompare').value)
  end)

  it('resuelve ProgIDs y variantes de versión sin distinguir mayúsculas', function()
    assert.are.equal('Recordset', com.from_progid('aDoDb.Recordset.6.0').id)
    assert.are.equal('FileSystemObject', com.from_progid('Scripting.FileSystemObject').id)
    assert.are.equal('DOMDocument', com.from_progid('MSXML2.DOMDocument.6.0').id)
    assert.are.equal('XMLHTTP', com.from_progid('Microsoft.XMLHTTP').id)
    assert.is_nil(com.from_progid('Recordset'))
    assert.is_nil(com.from_progid('No.Existe'))
  end)

  it('documenta miembros y conserva los retornos de objetos derivados', function()
    for _, obj in pairs(com.types) do
      assert.is_true(#obj.doc > 0)
      for _, member in ipairs(obj.members) do
        assert.is_true(#member.signature > 0)
        assert.is_true(#member.doc > 0)
        assert.is_true(member.kind == 'method' or member.kind == 'property')
      end
    end
    assert.are.equal('Recordset', com.member('Connection', 'EXECUTE').returns)
    assert.are.equal('TextStream', com.member('FileSystemObject', 'OpenTextFile').returns)
    assert.are.equal('Matches', com.member('RegExp', 'Execute').returns)
    assert.are.equal('Match', com.member('Matches', 'Item').returns)
  end)
end)

describe('ayuda nativa y COM', function()
  local hover = require('asp.hover')
  local completion = require('asp.completion')
  local signature = require('asp.signature')
  local types = require('asp.types')

  before_each(function() vim.cmd.edit('tests/fixtures/ayuda/pagina.asp') end)
  after_each(function() vim.cmd('bwipeout!') end)

  local function pos(text, shift)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      local col = line:find(text, 1, true)
      if col then return { line = i - 1, character = col - 1 + (shift or 0) } end
    end
    error('texto no encontrado: ' .. text)
  end

  local function query(text)
    local row = vim.api.nvim_buf_line_count(0) - 1
    vim.api.nvim_buf_set_lines(0, row, row, false, { text })
    return { line = row, character = #text }
  end

  local function items(text)
    local result = {}
    for _, entry in ipairs(completion.complete(0, query(text))) do result[entry.label] = entry end
    return result
  end

  it('muestra firma, parámetros y retorno de Len', function()
    local value = hover.hover(0, pos('Len(')).contents.value
    assert.is_truthy(value:find('```vbscript\nLen(string)', 1, true))
    assert.is_truthy(value:find('Cadena cuya longitud', 1, true))
    assert.is_truthy(value:find('Retorno: `Long`', 1, true))
  end)

  it('muestra valor y documentación de vbCrLf', function()
    local value = hover.hover(0, pos('vbCrLf')).contents.value
    assert.is_truthy(value:find('vbCrLf = Chr(13) & Chr(10)', 1, true))
    assert.is_truthy(value:find('salto de línea', 1, true))
  end)

  it('muestra el tipo de una variable COM y la ayuda de su miembro', function()
    local variable = hover.hover(0, pos('rs.EOF')).contents.value
    local member = hover.hover(0, pos('rs.EOF', 3)).contents.value
    assert.is_truthy(variable:find('ADODB.Recordset', 1, true))
    assert.is_truthy(member:find('ADODB.Recordset.EOF', 1, true))
    assert.is_truthy(member:find('último registro', 1, true))
  end)

  it('infiere un Recordset del retorno de Connection.Execute', function()
    assert.are.equal('Recordset', types.infer(0, pos('filas.EOF'), 'FiLaS').id)
    assert.is_truthy(hover.hover(0, pos('filas.EOF', 6)).contents.value:find('Recordset.EOF', 1, true))
  end)

  it('infiere TextStream, New RegExp y Matches', function()
    local p = pos('Response.Write Len')
    assert.are.equal('TextStream', types.infer(0, p, 'texto').id)
    assert.are.equal('RegExp', types.infer(0, p, 'rx').id)
    assert.are.equal('Matches', types.infer(0, p, 'coincidencias').id)
  end)

  it('muestra una Function de un include transitivo con su archivo', function()
    local value = hover.hover(0, pos('FuncionIncluida(1')).contents.value
    assert.is_truthy(value:find('Function FuncionIncluida(ByVal primero, segundo)', 1, true))
    assert.is_truthy(value:find('funciones.inc', 1, true))
  end)

  it('prefiere asignaciones locales sin mezclar procedimientos', function()
    assert.are.equal('Dictionary', types.infer(0, pos('rs.Exists'), 'RS').id)
    assert.are.equal('Recordset', types.infer(0, pos('rs.EOF'), 'rs').id)
    assert.are.equal('Dictionary', types.infer(0, pos('rs.EOF'), 'objetoIncluido').id)
  end)

  it('completa Replace con firma y documentación sin distinguir mayúsculas', function()
    local entry = items('rEp').Replace
    assert.are.equal(3, entry.kind)
    assert.is_truthy(entry.detail:find('Replace(expression', 1, true))
    assert.is_true(#entry.documentation.value > 0)
  end)

  it('completa constantes con su valor', function()
    local entry = items('vbCrL').vbCrLf
    assert.are.equal(21, entry.kind)
    assert.are.equal('Chr(13) & Chr(10)', entry.detail)
  end)

  it('ofrece keywords solo desde dos letras', function()
    assert.is_nil(items('F').Function)
    assert.are.equal(14, items('Fu').Function.kind)
  end)

  it('completa métodos y propiedades COM con sus kinds', function()
    local result = items('rs.')
    assert.are.equal(2, result.MoveNext.kind)
    assert.are.equal('ADODB.Recordset.MoveNext()', result.MoveNext.detail)
    assert.are.equal(10, result.EOF.kind)
    assert.is_nil(result.Replace)
  end)

  it('filtra miembros COM por prefijo', function()
    local result = items('rs.moVeN')
    assert.is_not_nil(result.MoveNext)
    assert.is_nil(result.Open)
    assert.is_not_nil(items('Response.Write rs.').EOF)
  end)

  it('ofrece ProgIDs en CreateObject y Server.CreateObject', function()
    local plain = items('Set nuevo = CreateObject("')
    assert.is_not_nil(plain['ADODB.Recordset'])
    assert.is_not_nil(plain['Scripting.FileSystemObject'])
    assert.is_not_nil(plain['Microsoft.XMLHTTP'])
    local filtered = items('Set nuevo = Server.CreateObject("adodb.r')
    assert.is_not_nil(filtered['ADODB.Recordset'])
    assert.is_nil(filtered['Scripting.Dictionary'])
  end)

  it('mantiene intrínsecos y símbolos de la página y los includes', function()
    assert.is_not_nil(items('Response.').Write)
    assert.is_not_nil(items('MiS').MiSub)
    assert.is_not_nil(items('FuncionI').FuncionIncluida)
    local value = hover.hover(0, pos('Response.Write', #('Response.'))).contents.value
    assert.is_truthy(value:find('Response.Write(variant)', 1, true))
  end)

  it('Mid activa el segundo parámetro tras la primera coma', function()
    local result = signature.help(0, query('x = Mid(s, '))
    assert.are.equal(1, result.activeParameter)
    assert.are.equal('Mid(string, start[, length])', result.signatures[1].label)
    assert.are.equal('start', param_labels(result)[2])
  end)

  it('ofrece la firma de Response.Write', function()
    local result = signature.help(0, query('Response.Write('))
    assert.are.equal(0, result.activeParameter)
    assert.are.equal('Response.Write(variant)', result.signatures[1].label)
  end)

  it('ofrece la firma COM de rs.Open', function()
    local result = signature.help(0, query('rs.Open('))
    assert.are.equal(0, result.activeParameter)
    assert.is_truthy(result.signatures[1].label:find('ADODB.Recordset.Open(', 1, true))
    assert.are.equal('Source', param_labels(result)[1])
  end)

  it('ofrece parámetros de Sub sin paréntesis, con y sin Call', function()
    for _, text in ipairs({ 'MiSub a, ', 'Call MiSub a, ', 'x = 1: MiSub a, ' }) do
      local result = signature.help(0, query(text))
      assert.are.equal(1, result.activeParameter)
      assert.are.equal('Sub MiSub(ByVal a, ByRef b)', result.signatures[1].label)
      assert.are.same({ 'a', 'b' }, param_labels(result))
    end
  end)

  it('resalta el parámetro y no la misma letra dentro de ByVal', function()
    local result = signature.help(0, query('MiSub '))
    local label = result.signatures[1].label
    assert.are.equal('Sub MiSub(ByVal ', label:sub(1, result.signatures[1].parameters[1].label[1]))
    -- Lo mismo que dibuja Neovim: 0.10 devuelve {inicio, fin} en la línea
    -- de la firma; 0.11+ un Range4 sobre las líneas del markdown.
    local lines, hl = vim.lsp.util.convert_signature_help_to_markdown_lines(result, 'vbscript', { '(', ',' })
    local row, s, e = 2, hl[1], hl[2]
    if #hl == 4 then row, s, e = hl[1] + 1, hl[2], hl[4] end
    assert.are.equal('ByVal a', lines[row]:sub(s - 5, e))
  end)

  it('ofrece los parámetros de una Function de un include transitivo', function()
    local result = signature.help(0, query('x = FuncionIncluida(1, '))
    assert.are.equal(1, result.activeParameter)
    assert.are.equal('Function FuncionIncluida(ByVal primero, segundo)', result.signatures[1].label)
    assert.are.equal('segundo', param_labels(result)[2])
    assert.is_truthy(result.signatures[1].documentation.value:find('funciones.inc', 1, true))
  end)

  it('no cuenta comas dentro de strings ni llamadas anidadas', function()
    local result = signature.help(0, query('x = Mid(Replace("a,""b,c", "a", "b"), '))
    assert.are.equal(1, result.activeParameter)
    assert.is_truthy(result.signatures[1].label:find('Mid(', 1, true))
  end)

  it('elige la llamada abierta más cercana en expresiones con varias llamadas', function()
    local result = signature.help(0, query('x = Len(s) + Mid(s, '))
    assert.are.equal(1, result.activeParameter)
    assert.are.equal('Mid(string, start[, length])', result.signatures[1].label)
  end)

  it('devuelve nil fuera de llamadas, en comentarios y en otras capas', function()
    for _, text in ipairs({ 'x = 1', 'x = Len(s)', 'Len (s)', "' Mid(s, ", 'Rem Mid(s, ' }) do
      assert.is_nil(signature.help(0, query(text)), text)
    end
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { '<script>Mid(s, </script>' })
    assert.is_nil(signature.help(0, { line = vim.api.nvim_buf_line_count(0) - 1, character = 15 }))
  end)

  it('no ofrece ayuda nativa en strings o miembros desconocidos', function()
    assert.are.same({}, items('Response.Write "Rep'))
    assert.is_nil(signature.help(0, query('desconocido.Mid(s, ')))
    local result = items('desconocido.')
    assert.is_nil(result.Len)
    assert.is_nil(result.vbCrLf)
    assert.is_nil(result.MoveNext)
  end)

  it('sin tipo COM, Objeto. ofrece los símbolos como antes', function()
    vim.api.nvim_buf_set_lines(0, -2, -2, false, {
      'Class Persona', 'Public Nombre', 'Function Saludar(otro)', 'End Function', 'End Class',
      'Set persona1 = New Persona',
    })
    assert.is_not_nil(items('persona1.Sa').Saludar)
    local all = items('desconocido.')
    assert.is_not_nil(all.MiSub)
    assert.is_not_nil(all.Response)
    assert.is_not_nil(all.FuncionIncluida)
  end)

  it('responde signatureHelp por LSP y anuncia los disparadores', function()
    local position = query('x = Mid(s, ')
    assert.is_true(vim.wait(2000, function()
      local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
      return client and client.initialized
    end))
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    assert.are.same({ triggerCharacters = { '(', ',' }, retriggerCharacters = { ',' } },
      client.server_capabilities.signatureHelpProvider)
    local response = vim.lsp.buf_request_sync(0, 'textDocument/signatureHelp', {
      textDocument = vim.lsp.util.make_text_document_params(), position = position,
    }, 3000)
    assert.is_not_nil(response)
    local result = response[client.id]
    assert.is_nil(result.err)
    assert.are.equal(1, result.result.activeParameter)
    assert.are.equal('Mid(string, start[, length])', result.result.signatures[1].label)
  end)
end)

describe('alcance y cachés de ayuda', function()
  local types, symbols = require('asp.types'), require('asp.symbols')
  local hover, completion, signature = require('asp.hover'), require('asp.completion'), require('asp.signature')

  before_each(function() vim.cmd.edit('tests/fixtures/ayuda/pagina.asp') end)
  after_each(function() vim.cmd('bwipeout!') end)

  local function code(lines)
    local source = { '<%' }
    vim.list_extend(source, lines)
    source[#source + 1] = '%>'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, source)
  end

  local function infer(name, row)
    local result = types.infer(0, { line = row or 1, character = 0 }, name)
    return result and result.id
  end

  it('la primera asignación del scope gana aunque sea posterior al cursor', function()
    code({ 'Response.Write x.EOF',
      'Set x = CreateObject("ADODB.Recordset")', 'Set X = CreateObject("Scripting.Dictionary")' })
    assert.are.equal('Recordset', infer('X'))
  end)

  it('una primera asignación desconocida no se salta', function()
    code({ 'Set x = fabrica()', 'Set x = CreateObject("ADODB.Recordset")' })
    assert.is_nil(infer('x'))
  end)

  it('Dim y parámetros locales sin tipo no heredan el tipo de página', function()
    code({ 'Set x = CreateObject("ADODB.Recordset")',
      'Sub Uno()', 'Dim x', 'Response.Write x', 'End Sub',
      'Sub Dos(x)', 'Response.Write x', 'End Sub' })
    assert.is_nil(infer('x', 4))
    assert.is_nil(infer('x', 7))
    assert.are.equal('Recordset', infer('x'))
  end)

  it('una asignación local desconocida oculta la de página', function()
    code({ 'Set x = CreateObject("ADODB.Recordset")',
      'Sub Uno()', 'Set x = fabrica()', 'Response.Write x', 'End Sub' })
    assert.is_nil(infer('x', 4))
  end)

  it('infiere en Property y evita tomar asignaciones de otro método', function()
    code({ 'Class Ejemplo', 'Property Get Dato()',
      'Set localObjeto = CreateObject("ADODB.Stream")', 'Dato = localObjeto.State', 'End Property',
      'Sub Otro()', 'Response.Write localObjeto', 'End Sub', 'End Class' })
    assert.are.equal('Stream', infer('localObjeto', 4))
    assert.is_nil(infer('localObjeto', 7))
  end)

  it('un retorno de página no usa el objeto homónimo del scope del cursor', function()
    code({ 'Set origen = CreateObject("ADODB.Connection")', 'Set resultado = origen.Execute("select 1")',
      'Sub Local()', 'Set origen = CreateObject("VBScript.RegExp")', 'Response.Write resultado.EOF', 'End Sub' })
    assert.are.equal('Recordset', infer('resultado', 5))
  end)

  it('solo sigue un nivel de retornos y corta ciclos y fábricas de usuario', function()
    code({ 'Set fso = CreateObject("Scripting.FileSystemObject")', 'Set folder = fso.GetFolder(".")',
      'Set file = folder.CreateTextFile("x")', 'Set a = b.Item(0)', 'Set b = a.Item(0)', 'Set c = fabrica()' })
    assert.are.equal('Folder', infer('folder'))
    assert.is_nil(infer('file'))
    assert.is_nil(infer('a'))
    assert.is_nil(infer('c'))
  end)

  it('distingue Fields de un campo indexado', function()
    code({ 'Set rs = CreateObject("ADODB.Recordset")', 'Set campos = rs.Fields', 'Set campo = rs.Fields("id")' })
    assert.are.equal('Fields', infer('campos'))
    assert.are.equal('Field', infer('campo'))
  end)

  it('no infiere desde comentarios, strings o ProgIDs calculados', function()
    code({ 'Rem Set x = CreateObject("ADODB.Recordset")',
      "' Set y = CreateObject(\"ADODB.Recordset\")", 'texto = "Set z = New RegExp"',
      'Set variable = CreateObject(progID)', 'Set concatenado = CreateObject("ADODB." & "Recordset")' })
    for _, name in ipairs({ 'x', 'y', 'z', 'variable', 'concatenado' }) do assert.is_nil(infer(name), name) end
  end)

  it('New RegExp exige nodos contiguos en la misma sentencia', function()
    code({ 'Set x = New: RegExp', 'Set y = New', 'RegExp', 'Set z = New RegExp' })
    assert.is_nil(infer('x'))
    assert.is_nil(infer('y'))
    assert.are.equal('RegExp', infer('z'))
  end)

  it('refleja ediciones sin guardar al invalidar por changedtick', function()
    code({ 'Set x = CreateObject("ADODB.Recordset")' })
    assert.are.equal('Recordset', infer('x'))
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'Set x = CreateObject("Scripting.Dictionary")' })
    assert.are.equal('Dictionary', infer('x'))
  end)

  it('resuelve un retorno cuyo objeto viene de un include transitivo', function()
    vim.api.nvim_buf_set_lines(0, -2, -2, false, { 'Set resultado = globalConn.Execute("select 1")' })
    assert.are.equal('Recordset', infer('resultado'))
  end)

  it('no relee ni reparsea includes calientes en los tres handlers', function()
    local p = { line = 14, character = #('Response.Write FuncionIncluida(1, ') }
    local hpos = { line = 14, character = 15 }
    local cpos = { line = 14, character = 15 }
    hover.hover(0, hpos)
    completion.complete(0, cpos)
    signature.help(0, p)
    local read, parse = io.open, vim.treesitter.get_string_parser
    local reads, parses = 0, 0
    io.open = function(...) reads = reads + 1; return read(...) end
    vim.treesitter.get_string_parser = function(...) parses = parses + 1; return parse(...) end
    local ok, err = pcall(function()
      for _ = 1, 3 do
        assert.is_truthy(hover.hover(0, hpos).contents.value:find('funciones.inc', 1, true))
        assert.is_true(#completion.complete(0, cpos) > 0)
        assert.is_truthy(signature.help(0, p).signatures[1].label:find('FuncionIncluida', 1, true))
      end
    end)
    io.open, vim.treesitter.get_string_parser = read, parse
    assert.is_true(ok, err)
    assert.are.equal(0, reads)
    assert.are.equal(0, parses)
  end)

  it('comparte el parseo de disco con símbolos y diagnósticos e invalida por tamaño', function()
    local path = vim.fn.tempname() .. '.inc'
    local function write(content) vim.fn.writefile(content, path) end
    write({ '<%', 'Set objeto = CreateObject("ADODB.Recordset")', 'Function Externa(a)', 'End Function', '%>' })
    local read, parse = require('asp.pages').read, vim.treesitter.get_string_parser
    local reads, parses = 0, 0
    require('asp.pages').read = function(...) reads = reads + 1; return read(...) end
    vim.treesitter.get_string_parser = function(...) parses = parses + 1; return parse(...) end
    local ok, err = pcall(function()
      assert.are.equal('Externa', symbols.collect_file(path)[1].name)
      assert.is_false(symbols.file_facts(path).option_explicit)
      assert.are.equal('Recordset', symbols.file_help(path).assignments[1].type)
      assert.are.equal(1, reads)
      assert.are.equal(2, parses) -- plantilla y VBScript, ninguna otra capa
      write({ '<%', 'Set objeto = CreateObject("Scripting.Dictionary")', 'Function Externa(a, b)', 'End Function', '%>' })
      assert.are.equal('Dictionary', symbols.file_help(path).assignments[1].type)
      assert.are.equal(2, #symbols.collect_file(path)[1].params)
      assert.are.equal(2, reads)
      assert.are.equal(4, parses)
    end)
    require('asp.pages').read, vim.treesitter.get_string_parser = read, parse
    vim.fn.delete(path)
    symbols.invalidate(path)
    assert.is_true(ok, err)
  end)

  it('reemplaza todo el prefijo del ProgID, incluidos los puntos', function()
    local line = '<% Set x = CreateObject("ADODB.R'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { line, '%>' })
    local result = completion.complete(0, { line = 0, character = #line })
    assert.are.equal(1, #result)
    local edit = result[1].textEdit
    assert.are.equal('ADODB.Recordset', edit.newText)
    assert.are.equal('ADODB.R', line:sub(edit.range.start.character + 1, edit.range['end'].character))
  end)

  it('no ofrece miembros por confundir una cadena con una variable', function()
    code({ 'Set rs = CreateObject("ADODB.Recordset")', 'otro.rs.' })
    for _, entry in ipairs(completion.complete(0, { line = 2, character = 8 })) do
      assert.are_not.equal('MoveNext', entry.label)
    end
    code({ 'Set rs = CreateObject("ADODB.Recordset")', 'otro.rs.Len' })
    assert.is_nil(hover.hover(0, { line = 2, character = 9 }))
  end)

  it('muestra también los literales nativos y omite comentarios Rem', function()
    code({ 'x = True', 'Rem Len("x")' })
    assert.is_truthy(hover.hover(0, { line = 1, character = 5 }).contents.value:find('True = -1', 1, true))
    assert.is_nil(hover.hover(0, { line = 2, character = 5 }))
  end)

  it('ofrece firmas de Property con Optional cuando la gramática lo expone', function()
    code({ 'Class Ejemplo', 'Property Get Dato(Optional indice)', 'Dato = indice', 'End Property',
      'Sub Usar()', 'x = Dato(', 'End Sub', 'End Class' })
    local result = signature.help(0, { line = 6, character = 9 })
    assert.are.equal('Property Get Dato(Optional indice)', result.signatures[1].label)
    assert.are.equal('indice', param_labels(result)[1])
  end)

  it('no confunde declaraciones con llamadas activas', function()
    code({ 'Function Len(a)', 'End Function' })
    assert.is_nil(signature.help(0, { line = 1, character = 13 }))
    code({ 'Dim Len(2)' })
    assert.is_nil(signature.help(0, { line = 1, character = 8 }))
  end)

  it('un handler de signatureHelp con posición inválida devuelve nil', function()
    local result = require('asp.lsp').handlers['textDocument/signatureHelp']({
      textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = -1, character = -1 },
    })
    assert.is_nil(result)
  end)
end)
