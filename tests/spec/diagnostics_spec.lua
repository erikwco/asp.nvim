local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')
local DIAG = vim.fn.fnamemodify('tests/fixtures/diagnosticos', ':p'):gsub('/$', '')

local function diagnostics()
  return require('asp.diagnostics')
end

-- Abre `path`, refresca y devuelve sus diagnósticos ordenados por posición.
local function diags_at(path)
  vim.cmd.edit(path)
  diagnostics().refresh(0)
  local ds = vim.diagnostic.get(0, { namespace = diagnostics().ns })
  table.sort(ds, function(a, b)
    return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
  end)
  return ds
end

-- Diagnósticos de una familia (campo `code`).
local function of(ds, family)
  return vim.tbl_filter(function(d) return d.code == family end, ds)
end

-- Texto que cubre un diagnóstico de una sola línea.
local function text_of(d)
  local line = vim.api.nvim_buf_get_lines(0, d.lnum, d.lnum + 1, true)[1]
  return line:sub(d.col + 1, d.end_col)
end

local function texts(ds)
  return vim.tbl_map(text_of, ds)
end

-- Crea `files` (nombre → líneas) en un directorio temporal con web.config
-- y corre fn(dir); siempre borra el directorio.
local function in_temp(files, fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  dir = vim.uv.fs_realpath(dir)
  vim.fn.writefile({}, dir .. '/web.config')
  for name, lines in pairs(files) do
    vim.fn.mkdir(vim.fs.dirname(dir .. '/' .. name), 'p')
    vim.fn.writefile(lines, dir .. '/' .. name)
  end
  local ok, err = pcall(fn, dir)
  vim.fn.delete(dir, 'rf')
  assert(ok, err)
end

describe('diagnósticos de includes', function()
  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function diags_for(file)
    vim.cmd.edit(FIX .. '/' .. file)
    require('asp.diagnostics').refresh(0)
    return vim.diagnostic.get(0, { namespace = require('asp.diagnostics').ns })
  end

  it('marca includes irresolubles con WARN en su línea', function()
    local ds = diags_for('roto.asp')
    assert.are.equal(2, #ds)
    assert.are.equal(vim.diagnostic.severity.WARN, ds[1].severity)
    assert.are.equal(0, ds[1].lnum)
    assert.are.equal(1, ds[2].lnum)
    assert.is_truthy(ds[1].message:find('no_existe%.inc'))
  end)

  it('reporta ciclos con un WARN', function()
    local ds = diags_for('ciclo_a.asp')
    assert.are.equal(1, #ds)
    assert.is_truthy(ds[1].message:lower():find('ciclo'))
  end)

  it('un grafo sano no produce diagnósticos', function()
    local ds = diags_for('default.asp')
    assert.are.same({}, ds)
  end)
end)

describe('diagnósticos de VBScript', function()
  local previous

  before_each(function()
    previous = require('asp').options.diagnostics
  end)

  after_each(function()
    require('asp').options.diagnostics = previous
    vim.cmd('bwipeout!')
  end)

  describe('sintaxis', function()
    it('marca el ERROR de VBScript con HINT y su rango real', function()
      local ds = of(diags_at(DIAG .. '/sintaxis.asp'), 'syntax')
      assert.are.equal(1, #ds)
      assert.are.equal(vim.diagnostic.severity.HINT, ds[1].severity)
      assert.are.equal('asp-ls', ds[1].source)
      -- La forma exacta del ERROR depende de la versión de tree-sitter.
      assert.are.equal(8, ds[1].lnum)
      assert.is_truthy(text_of(ds[1]):find('(1 +', 1, true))
    end)

    it('no reporta HTML ni JavaScript rotos fuera de los bloques <% %>', function()
      assert.are.same({}, diags_at(DIAG .. '/limpio.asp'))
    end)

    it('un error que cruza bloques se recorta al bloque donde empieza', function()
      in_temp({
        ['p.asp'] = { '<% If x Then', 'y = (1 + %>', '<p>html</p>', '<% End If %>' },
      }, function(dir)
        local ds = of(diags_at(dir .. '/p.asp'), 'syntax')
        assert.is_true(#ds > 0)
        for _, d in ipairs(ds) do
          assert.is_true((d.end_lnum or d.lnum) <= 1, 'el diagnóstico cruza al HTML')
        end
      end)
    end)

    it('un comentario Rem no produce errores ni nombres sin declarar', function()
      in_temp({
        ['p.asp'] = { '<%', 'Option Explicit', 'Rem texto libre: sinDeclarar ó (', 'Dim x : x = 1', '%>' },
      }, function(dir)
        assert.are.same({}, diags_at(dir .. '/p.asp'))
      end)
    end)

    it('una página JScript no se revisa como VBScript', function()
      assert.are.same({}, diags_at(DIAG .. '/jscript.asp'))
    end)
  end)

  describe('variables sin declarar', function()
    it('marca el uso sin Dim bajo Option Explicit', function()
      local ds = of(diags_at(DIAG .. '/explicit.asp'), 'undeclared')
      assert.are.same({ 'total' }, texts(ds))
      assert.are.equal(vim.diagnostic.severity.WARN, ds[1].severity)
      assert.is_truthy(ds[1].message:find('"total"', 1, true))
    end)

    it('acepta includes transitivos, miembros, intrínsecos, nativos, arreglos, clases, parámetros y For', function()
      -- explicit.asp usa gTransitiva y MAX_FILAS (de un include
      -- transitivo), obj.Prop.Metodo, Response/Server/Err, Len y vbCrLf,
      -- arr(1), el Private saldo de una clase dentro de su método, los
      -- parámetros de MiSub, las variables de For y For Each, un ReDim y
      -- un Const locales, y Me.
      local ds = of(diags_at(DIAG .. '/explicit.asp'), 'undeclared')
      assert.are.same({ 'total' }, texts(ds))
    end)

    it('reconoce las constantes nativas de fechas, comparación y MsgBox', function()
      in_temp({
        ['p.asp'] = {
          '<%', 'Option Explicit', 'Dim valor',
          'valor = DatePart("ww", Date, vbSunday, vbUseSystem)',
          'valor = vbDatabaseCompare',
          'valor = vbMsgBoxHelpButton + vbMsgBoxSetForeground + vbMsgBoxRight + vbMsgBoxRtlReading',
          'valor = vbConstanteInventada', '%>',
        },
      }, function(dir)
        local ds = diags_at(dir .. '/p.asp')
        assert.are.same({ 'vbConstanteInventada' }, texts(ds))
        assert.are.equal('undeclared', ds[1].code)
      end)
    end)

    it('conserva todas las declaraciones al mezclar arrays y escalares', function()
      in_temp({
        ['p.asp'] = {
          '<%', 'Option Explicit', 'Dim a(10), b(), x', 'ReDim Preserve b(10)',
          'a(1) = 3', 'x = a(1)', 'b(0) = x', 'suelta = x',
          'Sub Probar()', 'Dim c(2), d(), local', 'local = c(0)', 'End Sub',
          'local = 1', '%>',
        },
      }, function(dir)
        local ds = diags_at(dir .. '/p.asp')
        assert.are.same({ 'suelta', 'local' }, texts(ds))
        assert.are.equal('undeclared', ds[1].code)
        assert.are.equal('undeclared', ds[2].code)
      end)
    end)

    it('recoge arrays y escalares declarados juntos en includes', function()
      in_temp({
        ['inc/arrays.inc'] = { '<% Dim a(10), b(), valor %>' },
        ['p.asp'] = {
          '<!--#include file="inc/arrays.inc" -->', '<%', 'Option Explicit',
          'valor = a(0)', 'ReDim b(2)', 'b(0) = valor', '%>',
        },
      }, function(dir)
        assert.are.same({}, diags_at(dir .. '/p.asp'))
      end)
    end)

    it('sin Option Explicit no reporta variables ni llamadas', function()
      local ds = diags_at(DIAG .. '/sin_explicit.asp')
      assert.are.same({}, of(ds, 'undeclared'))
      assert.are.same({}, of(ds, 'unknown_call'))
    end)

    it('Option Explicit en un include también activa la revisión', function()
      in_temp({
        ['inc/cabecera.inc'] = { '<% Option Explicit %>' },
        ['p.asp'] = { '<!--#include file="inc/cabecera.inc" -->', '<% suelta = 1 %>' },
      }, function(dir)
        assert.are.same({ 'suelta' }, texts(of(diags_at(dir .. '/p.asp'), 'undeclared')))
      end)
    end)

    it('reconoce Option Explicit tras Rem en un include transitivo virtual', function()
      in_temp({
        ['inc/base.inc'] = { '<!--#include file="opciones.inc" -->' },
        ['inc/opciones.inc'] = { '<%', 'Rem cabecera del sitio', 'Option Explicit', '%>' },
        ['p.asp'] = { '<!--#include virtual="/inc/base.inc" -->', '<% suelta = Ausente(1) %>' },
      }, function(dir)
        local ds = diags_at(dir .. '/p.asp')
        assert.are.same({ 'suelta' }, texts(of(ds, 'undeclared')))
        assert.are.same({ 'Ausente' }, texts(of(ds, 'unknown_call')))
      end)
    end)

    it('un include sin resolver apaga la revisión de nombres', function()
      in_temp({
        ['p.asp'] = { '<!--#include file="falta.inc" -->', '<% Option Explicit', 'suelta = 1', 'NoExiste %>' },
      }, function(dir)
        local ds = diags_at(dir .. '/p.asp')
        assert.are.equal(1, #of(ds, 'includes'))
        assert.are.same({}, of(ds, 'undeclared'))
        assert.are.same({}, of(ds, 'unknown_call'))
      end)
    end)

    it('un nombre dentro de un error de sintaxis cuenta como declarado', function()
      in_temp({
        ['p.asp'] = { '<%', 'Option Explicit', 'Dim x', 'Const A = 1, B = 2', 'x = A + B + C', '%>' },
      }, function(dir)
        assert.are.same({ 'C' }, texts(of(diags_at(dir .. '/p.asp'), 'undeclared')))
      end)
    end)
  end)

  describe('llamadas inexistentes', function()
    it('marca llamadas sin paréntesis, con paréntesis, con Call y New de una clase inexistente', function()
      local ds = of(diags_at(DIAG .. '/explicit.asp'), 'unknown_call')
      assert.are.same({ 'NoExiste', 'Inexistente', 'Fantasma', 'NoClase' }, texts(ds))
      assert.is_truthy(ds[4].message:find('clase', 1, true))
    end)

    it('acepta funciones de includes, subs de la página, índices, miembros, nativos y New de clases', function()
      -- Utilidad y FormatoBase vienen del grafo; MiSub es de la página;
      -- arr(2) indexa un Dim arr(10); c.Sumar es un miembro; New Carro
      -- (clase de un include) y New RegExp (nativa) son válidos.
      local ds = of(diags_at(DIAG .. '/explicit.asp'), 'unknown_call')
      for _, name in ipairs({ 'Utilidad', 'FormatoBase', 'MiSub', 'arr', 'Sumar', 'Carro', 'RegExp', 'Len' }) do
        assert.is_false(vim.tbl_contains(texts(ds), name), name)
      end
    end)

    it('New no acepta una Function homónima', function()
      in_temp({
        ['p.asp'] = { '<%', 'Option Explicit', 'Dim o', 'Set o = New Armar', 'Function Armar()', 'End Function', '%>' },
      }, function(dir)
        assert.are.same({ 'Armar' }, texts(of(diags_at(dir .. '/p.asp'), 'unknown_call')))
      end)
    end)
  end)

  describe('código dinámico', function()
    it('Execute apaga variables y llamadas y deja un HINT en su línea', function()
      local ds = diags_at(DIAG .. '/dinamico.asp')
      assert.are.equal(1, #ds)
      assert.are.equal(vim.diagnostic.severity.HINT, ds[1].severity)
      assert.are.equal(4, ds[1].lnum)
      assert.is_truthy(ds[1].message:find('Execute', 1, true))
    end)

    it('Eval en un include deja el HINT en la directiva que lo trae', function()
      local ds = diags_at(DIAG .. '/dinamico_inc.asp')
      assert.are.equal(1, #ds)
      assert.are.equal(vim.diagnostic.severity.HINT, ds[1].severity)
      assert.are.equal(3, ds[1].lnum)
      assert.is_truthy(ds[1].message:find('dinamico.inc:3', 1, true))
    end)

    it('Server.Execute es un miembro, no código dinámico', function()
      in_temp({
        ['p.asp'] = { '<%', 'Option Explicit', 'Server.Execute "otra.asp"', 'suelta = 1', '%>' },
      }, function(dir)
        local ds = diags_at(dir .. '/p.asp')
        assert.are.same({ 'suelta' }, texts(of(ds, 'undeclared')))
        assert.are.same({}, of(ds, 'dynamic'))
      end)
    end)

    it('Rem en includes no ejecuta código dinámico ni oculta declaraciones', function()
      in_temp({
        ['inc/lib.inc'] = {
          '<%', 'Rem Execute "no ejecutar"', 'Rem ejemplo: Function Rota(',
          'Dim valor', 'Function Utilidad()', 'Utilidad = valor', 'End Function', '%>',
        },
        ['p.asp'] = {
          '<!--#include file="inc/lib.inc" -->', '<%', 'Option Explicit',
          'valor = Utilidad()', 'suelta = Ausente(1)', '%>',
        },
      }, function(dir)
        local ds = diags_at(dir .. '/p.asp')
        assert.are.same({}, of(ds, 'dynamic'))
        assert.are.same({}, of(ds, 'syntax'))
        assert.are.same({ 'suelta' }, texts(of(ds, 'undeclared')))
        assert.are.same({ 'Ausente' }, texts(of(ds, 'unknown_call')))
      end)
    end)
  end)

  describe('páginas inexistentes', function()
    it('marca enlaces y recursos que no existen en disco', function()
      -- falta_js.asp está en un <script><!-- ... //--></script>: ese
      -- comentario HTML no comenta el JavaScript.
      local ds = of(diags_at(DIAG .. '/enlaces.asp'), 'missing_page')
      assert.are.same({ 'js/falta.js', 'no_existe.asp', 'falta_js.asp' }, texts(ds))
      assert.are.equal(vim.diagnostic.severity.WARN, ds[1].severity)
    end)

    it('no reporta existentes, raíz virtual, <%= %>, concatenaciones, URLs absolutas ni comentarios', function()
      -- existe.asp, /css/estilo.css, js/app.js existen; detalle.asp lleva
      -- un <%= %>; falta.asp y '.asp' se concatenan; la URL es absoluta;
      -- viejo.asp y viejo2.asp están comentados (HTML y VBScript).
      local reported = texts(of(diags_at(DIAG .. '/enlaces.asp'), 'missing_page'))
      for _, path in ipairs({ 'existe.asp', '/css/estilo.css', 'js/app.js', 'detalle.asp?id=<%= id %>',
        'falta.asp?id=', 'http://ejemplo.com/remota.asp', 'viejo.asp', 'viejo2.asp', '.asp' }) do
        assert.is_false(vim.tbl_contains(reported, path), path)
      end
      assert.are.equal(3, #reported)
    end)
  end)

  describe('configuración', function()
    it('respeta severidades y false por familia', function()
      require('asp').setup({ diagnostics = {
        undeclared = 'ERROR', unknown_call = vim.diagnostic.severity.INFO, syntax = false,
      } })
      local ds = diags_at(DIAG .. '/explicit.asp')
      assert.are.equal(vim.diagnostic.severity.ERROR, of(ds, 'undeclared')[1].severity)
      assert.are.equal(vim.diagnostic.severity.INFO, of(ds, 'unknown_call')[1].severity)
      vim.cmd('bwipeout!')
      assert.are.same({}, of(diags_at(DIAG .. '/sintaxis.asp'), 'syntax'))
    end)

    it('false apaga includes y páginas', function()
      require('asp').setup({ diagnostics = { includes = false, missing_page = 'hint' } })
      assert.are.same({}, diags_at(FIX .. '/roto.asp'))
      vim.cmd('bwipeout!')
      local ds = of(diags_at(DIAG .. '/enlaces.asp'), 'missing_page')
      assert.are.equal(vim.diagnostic.severity.HINT, ds[1].severity)
    end)

    it('diagnostics = false apaga todas las familias', function()
      require('asp').setup({ diagnostics = false })
      assert.are.same({}, diags_at(DIAG .. '/explicit.asp'))
    end)

    it('un valor inválido avisa una sola vez y usa el de por defecto', function()
      local notify, calls = vim.notify, {}
      vim.notify = function(msg, level) table.insert(calls, { msg, level }) end
      local ok, err = pcall(function()
        require('asp').setup({ diagnostics = { undeclared = 'ROJO', unknown_calls = 'WARN' } })
        local ds = diags_at(DIAG .. '/explicit.asp')
        diagnostics().refresh(0)
        assert.are.equal(vim.diagnostic.severity.WARN, of(ds, 'undeclared')[1].severity)
      end)
      vim.notify = notify
      assert(ok, err)
      -- Uno por el valor y otro por la familia desconocida.
      assert.are.equal(2, #calls)
      assert.is_truthy(calls[1][1]:find('ROJO', 1, true) or calls[2][1]:find('ROJO', 1, true))
      assert.are.equal(vim.log.levels.WARN, calls[1][2])
    end)
  end)

  describe('refresco', function()
    it('ubica un include transitivo roto en la directiva de la página actual', function()
      local leaf = {}
      for _ = 1, 100 do leaf[#leaf + 1] = '' end
      leaf[#leaf + 1] = '<!--#include file="falta.inc" -->'
      in_temp({
        ['p.asp'] = {
          '<!--#include file="inc/sano.inc" -->',
          '<!--#include file="inc/base.inc" -->',
          '<% Dim x : x = (1 + %>',
        },
        ['inc/sano.inc'] = { '<% Dim sano %>' },
        ['inc/base.inc'] = { '<!--#include file="hoja.inc" -->' },
        ['inc/hoja.inc'] = leaf,
      }, function(dir)
        local ds = diags_at(dir .. '/p.asp')
        local inc = of(ds, 'includes')
        assert.are.equal(1, #inc)
        assert.are.equal(1, inc[1].lnum)
        assert.are.equal(1, inc[1].end_lnum)
        assert.are.equal('<!--#include file="inc/base.inc" -->', text_of(inc[1]))
        assert.is_truthy(inc[1].message:find('hoja.inc:101', 1, true))
        assert.are.equal(1, #of(ds, 'syntax'))
      end)
    end)

    it('TextChanged programa un refresh y al cerrar el buffer no queda ningún timer', function()
      vim.cmd.edit(DIAG .. '/explicit.asp')
      local buf = vim.api.nvim_get_current_buf()
      local autocmds = vim.api.nvim_get_autocmds({ group = 'asp_diagnostics_' .. buf })
      local events = {}
      for _, a in ipairs(autocmds) do events[a.event] = true end
      assert.is_true(events.TextChanged and events.InsertLeave and true or false)
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
      assert.are.equal(1, diagnostics().pending())
      vim.cmd('bwipeout!')
      assert.are.equal(0, diagnostics().pending())
      assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = 'asp_diagnostics_' .. buf }))
      vim.cmd.enew()
    end)

    it('el refresh diferido publica los cambios del buffer y cierra su timer', function()
      local debounce = diagnostics().debounce_ms
      diagnostics().debounce_ms = 10
      local ok, err = pcall(function()
        in_temp({ ['p.asp'] = { '<%', 'Option Explicit', 'Dim x : x = 1', '%>' } }, function(dir)
          diags_at(dir .. '/p.asp')
          assert.are.same({}, vim.diagnostic.get(0, { namespace = diagnostics().ns }))
          vim.api.nvim_buf_set_lines(0, 2, 3, false, { 'Dim x : y = 1' })
          diagnostics().schedule(vim.api.nvim_get_current_buf())
          -- El cambio también dispara TextChanged, que reprograma: se
          -- espera a que no quede nada pendiente.
          assert.is_true(vim.wait(2000, function()
            return diagnostics().pending() == 0
              and #vim.diagnostic.get(0, { namespace = diagnostics().ns }) == 1
          end))
          vim.cmd('bwipeout!')
        end)
      end)
      diagnostics().debounce_ms = debounce
      vim.cmd.enew()
      assert(ok, err)
    end)

    it('el segundo refresh de una página con 20 includes no lee disco', function()
      local files = { ['p.asp'] = { '<%', 'Option Explicit', '%>' } }
      for i = 1, 20 do
        local name = ('inc/i%02d.inc'):format(i)
        files[name] = { '<%', ('Function F%02d(x)'):format(i), ('  F%02d = x'):format(i), 'End Function', '%>' }
        table.insert(files['p.asp'], 1, ('<!--#include file="%s" -->'):format(name))
      end
      table.insert(files['p.asp'], '<% Dim r : r = F01(1) + F20(2) + Inexistente(3) %>')
      table.insert(files['p.asp'], '<a href="inc/i01.inc">ok</a> <a href="falta.asp">no</a>')
      in_temp(files, function(dir)
        local ds = diags_at(dir .. '/p.asp')
        assert.are.same({ 'Inexistente', 'falta.asp' }, texts(vim.tbl_filter(function(d)
          return d.code == 'unknown_call' or d.code == 'missing_page'
        end, ds)))
        local open, opens = io.open, 0
        io.open = function(...)
          opens = opens + 1
          return open(...)
        end
        local ok, err = pcall(diagnostics().refresh, 0)
        io.open = open
        assert(ok, err)
        assert.are.equal(0, opens)
        assert.are.same({}, diagnostics().last_errors)
      end)
    end)

    it('refresh nunca lanza y publica las familias que sí pudo calcular', function()
      local pages = require('asp.pages')
      local original = pages.buffer_literals
      pages.buffer_literals = function() error('falla simulada') end
      local ok, ds = pcall(diags_at, DIAG .. '/explicit.asp')
      pages.buffer_literals = original
      assert(ok, ds)
      assert.are.same({ 'total' }, texts(of(ds, 'undeclared')))
      assert.is_truthy(diagnostics().last_errors.missing_page)
    end)
  end)
end)

describe('asp.vbscript_builtins', function()
  local builtins = require('asp.vbscript_builtins')

  it('reconoce funciones, constantes, palabras clave y objetos sin distinguir mayúsculas', function()
    assert.are.equal('functions', builtins.lookup('len').group)
    assert.are.equal('Len', builtins.lookup('LEN').name)
    assert.are.equal('constants', builtins.lookup('VBCRLF').group)
    assert.are.equal('keywords', builtins.lookup('me').group)
    assert.are.equal('objects', builtins.lookup('err').group)
    assert.is_nil(builtins.lookup('MiFuncion'))
    assert.is_true(builtins.is_class('regexp'))
    assert.is_false(builtins.is_class('Len'))
  end)

  it('no repite nombres entre grupos', function()
    local seen = {}
    for group, entries in pairs(builtins.groups) do
      for _, entry in ipairs(entries) do
        local name = (type(entry) == 'table' and entry[1] or entry):lower()
        assert.is_nil(seen[name], ('%s está en %s y en %s'):format(name, tostring(seen[name]), group))
        seen[name] = group
      end
    end
  end)
end)
