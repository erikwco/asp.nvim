local FIX = vim.fn.fnamemodify('tests/fixtures/rename', ':p'):gsub('/$', '')
local rename = require('asp.rename')

-- Posición de la ocurrencia `nth` de `word` como palabra entera (por
-- defecto, la primera palabra de `text`) en la primera línea del buffer
-- actual que contiene `text`.
local function pos_in(text, word, nth)
  word = word or text:match('[%w_]+')
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = line:find(text, 1, true)
    if col then
      local from, count = col, 0
      while true do
        local s, e = line:find(word, from, true)
        assert(s, ('"%s" no aparece en la línea de "%s"'):format(word, text))
        local before, after = line:sub(s - 1, s - 1), line:sub(e + 1, e + 1)
        if (s == 1 or not before:match('[%w_]')) and not after:match('[%w_]') then
          count = count + 1
          if count == (nth or 1) then return { line = i - 1, character = s - 1 } end
        end
        from = e + 1
      end
    end
  end
  error('texto no encontrado: ' .. text)
end

-- Ruta de una uri relativa a `base` (el buffer usa su ruta y los archivos
-- del sitio, la real: se acepta cualquiera de las dos).
local function rel(uri, base)
  local path = vim.uri_to_fname(uri)
  for _, prefix in ipairs({ base .. '/', (vim.uv.fs_realpath(base) or base) .. '/' }) do
    if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  end
  return path
end

-- Archivo relativo → lista de 'línea:columna' de sus edits, en el orden
-- del WorkspaceEdit (descendente).
local function edits_of(edit, base)
  local out = {}
  for uri, edits in pairs(edit.changes) do
    local list = {}
    for _, e in ipairs(edits) do
      table.insert(list, ('%d:%d'):format(e.range.start.line, e.range.start.character))
    end
    out[rel(uri, base or FIX)] = list
  end
  return out
end

local function counts(edit, base)
  local out = {}
  for file, list in pairs(edits_of(edit, base)) do out[file] = #list end
  return out
end

-- Línea (0-indexed) de un archivo de disco.
local function file_line(path, lnum)
  local i = 0
  for line in io.lines(path) do
    if i == lnum then return line end
    i = i + 1
  end
end

-- Texto que cubre cada edit, leído del archivo de disco (o del buffer
-- actual si es su uri): debe ser siempre el nombre viejo.
local function covered(edit)
  local out = {}
  for uri, edits in pairs(edit.changes) do
    for _, e in ipairs(edits) do
      local line = uri == vim.uri_from_bufnr(0)
        and vim.api.nvim_buf_get_lines(0, e.range.start.line, e.range.start.line + 1, true)[1]
        or file_line(vim.uri_to_fname(uri), e.range.start.line)
      out[line:sub(e.range.start.character + 1, e.range['end'].character)] = true
    end
  end
  return vim.tbl_keys(out)
end

-- Crea `files` (nombre → contenido, bytes tal cual) en un directorio
-- temporal con web.config y corre fn(dir). Siempre borra el directorio y
-- los buffers que quedaron abiertos de él, modificados o no.
local function in_temp(files, fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  dir = vim.uv.fs_realpath(dir)
  files['web.config'] = files['web.config'] or ''
  for name, content in pairs(files) do
    vim.fn.mkdir(vim.fs.dirname(dir .. '/' .. name), 'p')
    local f = assert(io.open(dir .. '/' .. name, 'wb'))
    f:write(content)
    f:close()
  end
  local ok, err = pcall(fn, dir)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:sub(1, #dir) == dir or (vim.uv.fs_realpath(name) or ''):sub(1, #dir) == dir then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
  vim.fn.delete(dir, 'rf')
  assert(ok, err)
end

-- Copia los fixtures a un directorio temporal: los tests que aplican el
-- WorkspaceEdit nunca tocan los originales.
local function fixture_copy()
  local files = {}
  for _, path in ipairs(vim.fs.find(function() return true end, { path = FIX, type = 'file', limit = math.huge })) do
    local f = assert(io.open(path, 'rb'))
    files[path:sub(#FIX + 2)] = f:read('*a')
    f:close()
  end
  return files
end

local function buffer_lines(path)
  local b = vim.fn.bufnr(path)
  assert(b > 0, 'sin buffer para ' .. path)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false), b
end

local function wait_client()
  vim.wait(2000, function()
    return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
  end)
end

describe('asp.rename prepareRename', function()
  before_each(function()
    vim.cmd.edit(FIX .. '/pagina.asp')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function range(line, c0, c1)
    return { start = { line = line, character = c0 }, ['end'] = { line = line, character = c1 } }
  end

  it('devuelve rango y placeholder sobre una variable de página', function()
    local res, err = rename.prepare(0, pos_in('total = 0'))
    assert.is_nil(err)
    assert.are.same({ range = range(3, 0, 5), placeholder = 'total' }, res)
  end)

  it('devuelve rango y placeholder sobre una variable local', function()
    local pos = pos_in('  Dim i', 'i')
    local res = rename.prepare(0, pos)
    assert.are.same({ range = range(pos.line, 6, 7), placeholder = 'i' }, res)
  end)

  it('devuelve rango y placeholder sobre una Function de un include', function()
    local pos = pos_in('Response.Write Redondear', 'Redondear')
    -- Desde cualquier columna del identificador, el rango es el entero.
    local res = rename.prepare(0, { line = pos.line, character = pos.character + 4 })
    assert.are.same({ range = range(pos.line, 15, 24), placeholder = 'Redondear' }, res)
  end)

  it('devuelve rango y placeholder sobre una función JS de un .js externo', function()
    local pos = pos_in('  validarFormulario();')
    local res = rename.prepare(0, pos)
    assert.are.same({ range = range(pos.line, 2, 19), placeholder = 'validarFormulario' }, res)
  end)

  it('rechaza con un error lo que no es un símbolo renombrable', function()
    for _, case in ipairs({
      { 'rs.EOF', 'EOF', 'miembro de objeto' },
      { 'calc.Redondear', 'Redondear', 'miembro de objeto' },
      { 'Response.Write Redondear', 'Response', 'intrínseco de ASP' },
      { 'Len("abc")', 'Len', 'función nativa' },
      { 'Response.Redirect "otra.asp"', 'otra', 'literal de página' },
      { '<div class', 'div', 'no hay un símbolo' },
      { 'If Not rs.EOF', 'If', 'no hay un símbolo' },
      -- Sin Dim ni Option Explicit: no hay declaración que renombrar.
      { 'calc.Redondear', 'calc', 'no tiene una declaración' },
      -- JS: global implícito y propiedad.
      { 'document.title', 'document', 'no tiene una declaración' },
      { 'document.title', 'title', 'propiedad de objeto' },
    }) do
      local res, err = rename.prepare(0, pos_in(case[1], case[2]))
      assert.is_nil(res, case[2])
      assert.are.equal(-32602, err.code, case[2])
      assert.is_truthy(err.message:find(case[3], 1, true), case[2] .. ': ' .. err.message)
    end
  end)

  it('en un buffer sin nombre devuelve un error claro', function()
    vim.cmd('enew')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '<%', 'Dim x', 'x = 1', '%>' })
    vim.bo.filetype = 'asp'
    local res, err = rename.prepare(0, { line = 2, character = 0 })
    assert.is_nil(res)
    assert.is_truthy(err.message:find('no tiene nombre', 1, true))
    -- El handler no resuelve `file://` a otro buffer.
    local hres, herr = require('asp.lsp').handlers['textDocument/prepareRename']({
      textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = 2, character = 0 },
    })
    assert.is_nil(hres)
    assert.is_truthy(herr.message:find('no tiene nombre', 1, true))
  end)
end)

describe('asp.rename rename', function()
  after_each(function()
    vim.cmd('silent! %bwipeout!')
  end)

  local function open(file)
    vim.cmd.edit(FIX .. '/' .. file)
  end

  it('una Function de un include cambia la declaración y las llamadas en todo el sitio', function()
    open('pagina.asp')
    local edit = assert(rename.rename(0, pos_in('Response.Write Redondear', 'Redondear'), 'Redondeo'))
    -- sin_include.asp declara su propio Redondear y no incluye la librería;
    -- carrito.asp no lo usa. calc.Redondear y util.Redondear son miembros.
    assert.are.same({
      ['pagina.asp'] = 2,
      ['inc/base.inc'] = 2,
      ['inc/utilidades.inc'] = 1,
      ['otra.asp'] = 1,
    }, counts(edit))
    assert.are.same({ 'Redondear' }, covered(edit))
    assert.are.same({
      ('%d:13'):format(pos_in('Promedio = Redondear').line),
      ('%d:15'):format(pos_in('Response.Write Redondear').line),
    }, edits_of(edit)['pagina.asp'])
    assert.are.same({ '3:9' }, edits_of(edit)['otra.asp'])
    for _, edits in pairs(edit.changes) do
      for _, e in ipairs(edits) do assert.are.equal('Redondeo', e.newText) end
    end
  end)

  it('desde la declaración del include da los mismos edits que desde la página', function()
    open('pagina.asp')
    local from_page = counts(assert(rename.rename(0, pos_in('Response.Write Redondear', 'Redondear'), 'Redondeo')))
    open('inc/base.inc')
    local from_lib = assert(rename.rename(0, pos_in('Function Redondear', 'Redondear'), 'Redondeo'))
    assert.are.same(from_page, counts(from_lib))
    assert.are.same({ '2:2', '1:9' }, edits_of(from_lib)['inc/base.inc'])
  end)

  it('una local no toca la homónima de otra Sub ni la de página', function()
    open('pagina.asp')
    local edit = assert(rename.rename(0, pos_in('  Dim i', 'i'), 'k'))
    local sumar = pos_in('Sub Sumar').line
    assert.are.same({
      ['pagina.asp'] = {
        ('%d:20'):format(sumar + 3), -- total = total + i
        ('%d:6'):format(sumar + 2),  -- For i = 1
        ('%d:6'):format(sumar + 1),  -- Dim i
      },
    }, edits_of(edit))
  end)

  it('un cambio solo de mayúsculas en VBScript genera edits', function()
    open('pagina.asp')
    local edit = assert(rename.rename(0, pos_in('total = 0'), 'Total'))
    -- Dim, total = 0, total = Len, Redondear(total) y los dos de Sumar.
    assert.are.same({ ['pagina.asp'] = 6 }, counts(edit))
    for _, e in ipairs(edit.changes[vim.uri_from_bufnr(0)]) do assert.are.equal('Total', e.newText) end
  end)

  it('una función JS cambia su declaración en el .js externo y los usos en <script> y onclick', function()
    open('pagina.asp')
    local edit = assert(rename.rename(0, pos_in('onclick="validarFormulario', 'validarFormulario'), 'validar'))
    -- form.validarFormulario de app.js es una propiedad: no se toca.
    assert.are.same({
      ['js/app.js'] = { '1:9' },
      ['pagina.asp'] = {
        ('%d:17'):format(pos_in('onclick=').line),
        ('%d:2'):format(pos_in('  validarFormulario();').line),
      },
    }, edits_of(edit))
    assert.are.same({ 'validarFormulario' }, covered(edit))
  end)

  it('una función JS declarada en la página cambia su declaración y el onload', function()
    open('pagina.asp')
    local edit, err = rename.rename(0, pos_in('function iniciar', 'iniciar'), 'arrancar')
    assert.is_nil(err)
    assert.are.same({
      ['pagina.asp'] = {
        ('%d:14'):format(pos_in('<body onload=').line),
        ('%d:9'):format(pos_in('function iniciar').line),
      },
    }, edits_of(edit))
  end)

  it('rechaza un nombre nuevo inválido, reservado o igual al actual', function()
    open('pagina.asp')
    local vbs, js = pos_in('total = 0'), pos_in('  validarFormulario();')
    for _, case in ipairs({
      { vbs, 'If', 'palabra clave' },
      { vbs, 'len', 'función nativa' },
      { vbs, 'vbCrLf', 'constante nativa' },
      { vbs, 'Request', 'intrínseco de ASP' },
      { vbs, '1abc', 'no es un identificador de VBScript' },
      { vbs, 'con_ñ', 'no es un identificador de VBScript' },
      { vbs, '_total', 'no es un identificador de VBScript' },
      { vbs, ('a'):rep(256), '255 caracteres' },
      { vbs, 'total', 'igual al actual' },
      { js, 'class', 'palabra reservada' },
      { js, 'null', 'palabra reservada' },
      { js, '1abc', 'no es un identificador de JavaScript' },
      { js, 'validar-form', 'no es un identificador de JavaScript' },
      { js, 'validarFormulario', 'igual al actual' },
    }) do
      local res, err = rename.rename(0, case[1], case[2])
      assert.is_nil(res, case[2])
      assert.are.equal(-32602, err.code, case[2])
      assert.is_truthy(err.message:find(case[3], 1, true), case[2] .. ': ' .. err.message)
    end
    -- En JS el cambio de mayúsculas es otro nombre; `$` y `_` valen.
    assert.is_table(rename.rename(0, js, 'ValidarFormulario'))
    assert.is_table(rename.rename(0, js, '$_validar'))
  end)

  it('rechaza un nombre nuevo ya declarado en el mismo alcance', function()
    open('pagina.asp')
    for _, case in ipairs({
      { pos_in('total = 0'), 'RS', 'pagina.asp:3' },
      { pos_in('  Dim i', 'i'), 'cantidad', 'pagina.asp:12' },
      -- La declaración de página de un include del grafo.
      { pos_in('Response.Write Redondear', 'Redondear'), 'formatearPrecio', 'utilidades.inc:3' },
      { pos_in('  validarFormulario();'), 'iniciar', 'pagina.asp:34' },
    }) do
      local res, err = rename.rename(0, case[1], case[2])
      assert.is_nil(res, case[2])
      assert.is_truthy(err.message:find('mismo alcance', 1, true), err.message)
      assert.is_truthy(err.message:find(case[3], 1, true), err.message)
    end
    -- Un local puede tomar el nombre de un local de otra Sub.
    assert.is_table(rename.rename(0, pos_in('  Dim i', 'i'), 'suma'))
  end)

  it('un miembro de clase se renombra solo como identificador suelto dentro de la clase', function()
    open('carrito.asp')
    local expected = {
      ['carrito.asp'] = {
        ('%d:12'):format(pos_in('total = total + monto').line),
        ('%d:4'):format(pos_in('total = total + monto').line),
        ('%d:10'):format(pos_in('Private total').line),
      },
    }
    -- Desde la declaración y desde un uso dentro de un método: Me.total y
    -- el total de página quedan igual.
    assert.are.same(expected, edits_of(assert(rename.rename(0, pos_in('Private total', 'total'), 'm_total'))))
    assert.are.same(expected, edits_of(assert(rename.rename(0, pos_in('total = total + monto'), 'm_total'))))
    -- El nombre de página homónimo arrastraría al miembro (límite heredado
    -- del resolver): se rechaza en vez de dejar Me.total sin cambiar.
    local res, err = rename.rename(0, pos_in('Dim total', 'total'), 'suma')
    assert.is_nil(res)
    assert.is_truthy(err.message:find('clase `Carrito`', 1, true), err.message)
    res, err = rename.prepare(0, pos_in('c.Agregar', 'Agregar'))
    assert.is_nil(res)
    assert.is_truthy(err.message:find('miembro de objeto', 1, true))
  end)

  it('rechaza el rename si un archivo a cambiar tiene cambios sin guardar', function()
    open('inc/base.inc')
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { '<% \' sin guardar %>' })
    open('pagina.asp')
    local res, err = rename.rename(0, pos_in('Response.Write Redondear', 'Redondear'), 'Redondeo')
    assert.is_nil(res)
    assert.is_truthy(err.message:find('base.inc tiene cambios sin guardar', 1, true), err.message)
  end)

  it('omite miembros tras una continuación de línea en el buffer y en disco', function()
    local members = table.concat({
      '<%', 'x = obj. _', '  Total', 'With obj', '  . _',
      '  Total = 3', 'End With', '%>', '',
    }, '\n')
    in_temp({
      ['lib.inc'] = members:gsub('\n', '\r\n'),
      ['pagina.asp'] = '<!--#include file="lib.inc"-->\n<% Dim Total : Total = 1 %>\n' .. members,
    }, function(dir)
      vim.cmd.edit(dir .. '/pagina.asp')
      local pos = pos_in('Dim Total', 'Total')
      local refs = require('asp.symbols').references(0, pos)
      assert.are.equal(6, #refs)
      local edit = assert(rename.rename(0, pos, 'Saldo'))
      assert.are.same({ ['pagina.asp'] = 2 }, counts(edit, dir))
      for _, text in ipairs({ '  Total', '  Total = 3' }) do
        local prepared, err = rename.prepare(0, pos_in(text, 'Total'))
        assert.is_nil(prepared)
        assert.is_truthy(err.message:find('miembro de objeto', 1, true))
      end
      vim.lsp.util.apply_workspace_edit(edit, 'utf-8')
      assert.are.equal('<% Dim Saldo : Saldo = 1 %>', buffer_lines(dir .. '/pagina.asp')[2])
      assert.are.equal(members, table.concat(vim.api.nvim_buf_get_lines(0, 2, -1, false), '\n') .. '\n')
      assert.are.equal(-1, vim.fn.bufnr(dir .. '/lib.inc'))
    end)
  end)

  it('con las cachés calientes no vuelve a leer archivos de disco', function()
    open('pagina.asp')
    local vbs = pos_in('Response.Write Redondear', 'Redondear')
    local js = pos_in('  validarFormulario();')
    assert.is_table(rename.rename(0, vbs, 'Redondeo'))
    assert.is_table(rename.rename(0, js, 'validar'))
    local open_file, reads = io.open, {}
    io.open = function(path, ...)
      if type(path) == 'string' and path:find(FIX, 1, true) then table.insert(reads, path) end
      return open_file(path, ...)
    end
    local ok, err = pcall(function()
      assert.is_table(rename.prepare(0, vbs))
      assert.is_table(rename.rename(0, vbs, 'Redondeado'))
      assert.is_table(rename.prepare(0, js))
      assert.is_table(rename.rename(0, js, 'comprobar'))
    end)
    io.open = open_file
    assert(ok, err)
    assert.are.same({}, reads)
  end)

  it('un archivo abierto sin cambios recibe los edits en su propio buffer', function()
    open('inc/base.inc')
    local lib = vim.uri_from_bufnr(0)
    open('pagina.asp')
    local edit = assert(rename.rename(0, pos_in('Response.Write Redondear', 'Redondear'), 'Redondeo'))
    assert.are.equal(2, #edit.changes[lib])
  end)

  it('un identificador VBScript fundido entre dos <%= %> no tapa el JS del medio', function()
    in_temp({
      ['pagina.asp'] = table.concat({
        '<%', 'Dim nombre, apellido', '%>',
        '<p><%=nombre%></p>',
        '<script>', 'function saludar() { return 1; }', '</script>',
        '<p><%=apellido%></p>',
        '<button onclick="saludar()">x</button>', '',
      }, '\n'),
    }, function(dir)
      vim.cmd.edit(dir .. '/pagina.asp')
      local pos = pos_in('function saludar', 'saludar')
      -- La inyección combinada lee `nombre` y `apellido` como un solo
      -- identificador que cruza el <script>.
      local fused = require('asp.symbols').identifier_at(0, pos)
      assert.is_not_nil(fused)
      assert.are_not.equal(fused:start(), (fused:end_()))
      assert.are.same({ range = {
        start = pos, ['end'] = { line = pos.line, character = pos.character + 7 },
      }, placeholder = 'saludar' }, rename.prepare(0, pos))
      assert.are.same({ ['pagina.asp'] = 2 }, counts(assert(rename.rename(0, pos, 'hola')), dir))
    end)
  end)

  it('latin1 y BOM: los edits caen en la columna del buffer', function()
    in_temp({
      -- latin1: "Cálculo", "Canción número", "Validación".
      ['lib.inc'] = '<%\n\' C\225lculo\nFunction Calcular(n)\n  Calcular = n * 2\nEnd Function\n'
        .. 'mensaje = "Canci\243n n\250mero " & Calcular(3)\n%>\n',
      ['bom.inc'] = '\239\187\191<% Const LIMITE = 10 %>\n',
      ['app.js'] = '/* Validaci\243n */ function validar() { return true; }\n',
      ['pagina.asp'] = '<!--#include file="lib.inc"-->\n<!--#include file="bom.inc"-->\n'
        .. '<%\nResponse.Write Calcular(LIMITE)\n%>\n<script src="app.js"></script>\n'
        .. '<button onclick="validar()">ok</button>\n',
    }, function(dir)
      vim.cmd.edit(dir .. '/pagina.asp')
      local page = vim.api.nvim_get_current_buf()
      local function apply(text, word, new)
        vim.api.nvim_set_current_buf(page)
        local edit = assert(rename.rename(0, pos_in(text, word), new))
        vim.lsp.util.apply_workspace_edit(edit, 'utf-8')
      end
      apply('Response.Write Calcular', 'Calcular', 'Duplicar')
      apply('(LIMITE)', 'LIMITE', 'TOPE')
      apply('onclick="validar', 'validar', 'comprobar')

      local lib, b = buffer_lines(dir .. '/lib.inc')
      assert.are.equal('latin1', vim.bo[b].fileencoding)
      assert.are.same({
        '<%', "' Cálculo", 'Function Duplicar(n)', '  Duplicar = n * 2', 'End Function',
        'mensaje = "Canción número " & Duplicar(3)', '%>',
      }, lib)
      local bom
      bom, b = buffer_lines(dir .. '/bom.inc')
      assert.is_true(vim.bo[b].bomb)
      assert.are.same({ '<% Const TOPE = 10 %>' }, bom)
      local js
      js, b = buffer_lines(dir .. '/app.js')
      assert.are.equal('latin1', vim.bo[b].fileencoding)
      assert.are.same({ '/* Validación */ function comprobar() { return true; }' }, js)
      assert.are.same({ 'Response.Write Duplicar(TOPE)' }, vim.api.nvim_buf_get_lines(page, 3, 4, true))
    end)
  end)
end)

describe('asp-ls rename', function()
  after_each(function()
    vim.cmd('silent! %bwipeout!')
  end)

  -- El error de la respuesta viene en `err` (0.11+) o en `error` (0.10).
  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 5000)
    for _, r in pairs(resp or {}) do return r.result, r.err or r.error end
  end

  local function params(pos, extra)
    return vim.tbl_extend('force', {
      textDocument = vim.lsp.util.make_text_document_params(), position = pos,
    }, extra or {})
  end

  it('anuncia renameProvider con prepareProvider', function()
    vim.cmd.edit(FIX .. '/pagina.asp')
    wait_client()
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    assert.are.same({ prepareProvider = true }, client.server_capabilities.renameProvider)
  end)

  it('prepareRename y rename responden por LSP, con error cuando no se puede', function()
    vim.cmd.edit(FIX .. '/pagina.asp')
    wait_client()
    local pos = pos_in('Response.Write Redondear', 'Redondear')
    local res, err = request('textDocument/prepareRename', params(pos))
    assert.is_nil(err)
    assert.are.equal('Redondear', res.placeholder)
    assert.are.same({ line = pos.line, character = 15 }, res.range.start)

    res, err = request('textDocument/prepareRename', params(pos_in('rs.EOF', 'EOF')))
    assert.is_nil(res)
    assert.are.equal(-32602, err.code)
    assert.is_truthy(err.message:find('miembro de objeto', 1, true))

    res, err = request('textDocument/rename', params(pos, { newName = 'Redondeo' }))
    assert.is_nil(err)
    assert.are.same({ ['pagina.asp'] = 2, ['inc/base.inc'] = 2, ['inc/utilidades.inc'] = 1, ['otra.asp'] = 1 },
      counts(res))

    res, err = request('textDocument/rename', params(pos, { newName = 'If' }))
    assert.is_nil(res)
    assert.are.equal(-32602, err.code)
    assert.is_truthy(err.message:find('palabra clave', 1, true))
  end)

  it('el WorkspaceEdit aplicado deja el sitio renombrado en buffers sin guardar', function()
    in_temp(fixture_copy(), function(dir)
      vim.cmd.edit(dir .. '/pagina.asp')
      wait_client()
      local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
      local res = request('textDocument/rename',
        params(pos_in('Response.Write Redondear', 'Redondear'), { newName = 'Redondeo' }))
      vim.lsp.util.apply_workspace_edit(res, client.offset_encoding)

      local page = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.are.equal('Response.Write Redondeo(total)', page[10])
      assert.are.equal('  Promedio = Redondeo(suma / (UBound(lista) + 1))', page[24])
      assert.are.equal('calc.Redondear 2', page[27])
      local base, b = buffer_lines(dir .. '/inc/base.inc')
      assert.are.same({ '<%', 'Function Redondeo(valor)', '  Redondeo = Round(valor, 2)', 'End Function', '%>' }, base)
      assert.is_true(vim.bo[b].modified)
      local util = buffer_lines(dir .. '/inc/utilidades.inc')
      assert.are.equal('  FormatearPrecio = "$" & Redondeo(valor)', util[4])
      local otra = buffer_lines(dir .. '/otra.asp')
      assert.are.equal('precio = Redondeo(10.456)', otra[4])
      assert.are.equal('Response.Write util.Redondear', otra[6])
      assert.are.equal(-1, vim.fn.bufnr(dir .. '/sin_include.asp'))
      -- Nada se escribió a disco: eso queda para :wa.
      assert.are.equal('Function Redondear(valor)', file_line(dir .. '/inc/base.inc', 1))

      -- JS: la declaración del .js externo y los usos de la página.
      vim.cmd.buffer(vim.fn.bufnr(dir .. '/pagina.asp'))
      res = request('textDocument/rename',
        params(pos_in('  validarFormulario();'), { newName = 'validar' }))
      vim.lsp.util.apply_workspace_edit(res, client.offset_encoding)
      local js = buffer_lines(dir .. '/js/app.js')
      assert.are.equal('function validar() {', js[2])
      assert.are.equal('  return form.validarFormulario || true;', js[4])
      page = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.are.equal('  validar();', page[pos_in('  validar();').line + 1])
      assert.are.equal('<button onclick="validar()">Enviar</button>', page[pos_in('<button').line + 1])
    end)
  end)
end)
