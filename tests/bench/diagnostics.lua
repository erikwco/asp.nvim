-- Mide asp.diagnostics.refresh sobre una página de ~20 KB con 20 includes
-- (ver diagnostics.md). Desde la raíz del repo, con los parsers de
-- `make parsers-test`:
--
--   nvim --headless -u NONE -i NONE --cmd 'set rtp+=.' -l tests/bench/diagnostics.lua
--
-- Para medir el costo de los indicios en el parseo en frío de un include
-- (asp.symbols.collect_file), anteponé otra revisión con
-- --cmd 'set rtp^=/ruta/al/checkout': el script imprime de dónde cargó cada
-- módulo y salta lo que esa revisión no tiene.
local RUNS = 9
local INCLUDES = 20

local root = vim.fn.tempname()
local original_open = io.open
local previous_root = require('asp').options.virtual_root

-- Cuenta las aperturas de archivo de la consulta medida.
local opens = 0
io.open = function(...)
  opens = opens + 1
  return original_open(...)
end

local function median(xs)
  local sorted = vim.deepcopy(xs)
  table.sort(sorted)
  return sorted[math.ceil(#sorted / 2)]
end

local function timed(fn)
  opens = 0
  local start = vim.uv.hrtime()
  local res = fn()
  return (vim.uv.hrtime() - start) / 1e6, opens, res
end

-- Un include de ~8 KB: una Function, un Sub, una Class y un Const de
-- página, 100 filas HTML con `<%= %>` y un <script> con una función JS.
local function include_lines(i)
  local lines = {
    '<%',
    ('Const LIMITE_%02d = %d'):format(i, i),
    ('Function Formato%02d(valor)'):format(i),
    '  Dim texto',
    ('  texto = Replace(CStr(valor), ".", ",") & LIMITE_%02d'):format(i),
    ('  Formato%02d = texto'):format(i),
    'End Function',
    ('Sub Registrar%02d(mensaje)'):format(i),
    '  Response.Write Server.HTMLEncode(mensaje) & vbCrLf',
    'End Sub',
    ('Class Item%02d'):format(i),
    '  Private total',
    '  Public Sub Sumar(n)',
    '    total = total + n',
    '  End Sub',
    'End Class',
    '%>',
    ('<div class="bloque" id="b%02d">'):format(i),
  }
  for r = 1, 100 do
    lines[#lines + 1] = ('  <p class="fila">Fila %d: <%%= Server.HTMLEncode(rs("c%d")) %%></p>'):format(r, r)
  end
  vim.list_extend(lines, {
    '<script type="text/javascript">',
    ('function js%02d(e) { return e + %d; }'):format(i, i),
    '</script>',
    '</div>',
  })
  return lines
end

-- La página: 20 directivas (file= y virtual= alternadas), Option Explicit,
-- un bloque VBScript que usa lo de cada include, una tabla HTML con
-- `<%= %>` y enlaces, y un <script>. Pesa unos 20 KB. Tiene exactamente un
-- error de cada familia: `sinDeclarar`, `NoExiste(1)` y `falta.asp`.
local function page_lines()
  local lines = {}
  for i = 1, INCLUDES do
    lines[#lines + 1] = i % 2 == 0
      and ('<!--#include file="inc/i%02d.inc" -->'):format(i)
      or ('<!--#include virtual="/inc/i%02d.inc" -->'):format(i)
  end
  vim.list_extend(lines, { '<%', 'Option Explicit', 'Dim rs, i, total, item, fila', 'total = 0' })
  for i = 1, INCLUDES do
    vim.list_extend(lines, {
      ('total = total + LIMITE_%02d'):format(i),
      ('Registrar%02d Formato%02d(total)'):format(i, i),
      ('Set item = New Item%02d'):format(i),
      'item.Sumar total',
    })
  end
  vim.list_extend(lines, {
    'sinDeclarar = NoExiste(1)',
    'Set rs = Server.CreateObject("ADODB.Recordset")',
    '%>',
    '<html><head><link rel="stylesheet" href="/css/sitio.css"></head><body>',
    '<table>',
  })
  for r = 1, 120 do
    lines[#lines + 1] = ('<tr><td><a href="detalle.asp?id=<%%= rs("id") %%>">%d</a></td>'
      .. '<td><%%= Formato%02d(rs("monto")) %%></td><td><a href="inc/i01.inc">i</a></td></tr>')
      :format(r, (r % INCLUDES) + 1)
  end
  vim.list_extend(lines, {
    '</table>',
    '<a href="falta.asp">falta</a>',
    '<script>',
    'function iniciar() { location.href = "detalle.asp?id=" + 1; }',
    '</script>',
    '</body></html>',
  })
  return lines
end

local function source_of(mod, fn)
  local ok, m = pcall(require, mod)
  if not ok or not m[fn] then return 'no está' end
  return (debug.getinfo(m[fn], 'S').source:gsub('^@', ''))
end

local ok, err = xpcall(function()
  vim.fn.mkdir(root .. '/inc', 'p')
  vim.fn.mkdir(root .. '/css', 'p')
  root = assert(vim.uv.fs_realpath(root))
  vim.fn.writefile({}, root .. '/web.config')
  vim.fn.writefile({ 'body { margin: 0; }' }, root .. '/css/sitio.css')
  require('asp').options.virtual_root = nil
  vim.treesitter.language.register('aspclassic', 'asp')
  print(('nvim=%s'):format(tostring(vim.version())))
  for _, m in ipairs({ { 'asp.diagnostics', 'refresh' }, { 'asp.symbols', 'collect_file' } }) do
    print(('%s=%s'):format(m[1], source_of(m[1], m[2])))
  end

  local files = {}
  for i = 1, INCLUDES do
    local path = ('%s/inc/i%02d.inc'):format(root, i)
    vim.fn.writefile(include_lines(i), path)
    files[#files + 1] = path
  end
  local page = root .. '/pagina.asp'
  vim.fn.writefile(page_lines(), page)
  local symbols, includes = require('asp.symbols'), require('asp.includes')

  local function forget()
    for _, path in ipairs(files) do
      symbols.invalidate(path)
      includes.invalidate(path)
    end
  end

  -- Parseo en frío de los includes con asp.symbols.collect_file: lo que
  -- agregan los indicios de diagnósticos (asp.vbscript_scan.facts).
  local cold_collect = {}
  for _ = 1, RUNS do
    forget()
    cold_collect[#cold_collect + 1] = timed(function()
      for _, path in ipairs(files) do symbols.collect_file(path) end
    end)
  end
  local bytes = 0
  for _, path in ipairs(files) do bytes = bytes + vim.uv.fs_stat(path).size end
  print(('collect_file_frio_ms=%.2f includes=%d bytes_includes=%d'):format(median(cold_collect), #files, bytes))

  local has_diagnostics, diagnostics = pcall(require, 'asp.diagnostics')
  if not (has_diagnostics and diagnostics.config) then return end

  vim.cmd.edit(page)
  vim.bo.filetype = 'asp'
  local buf = vim.api.nvim_get_current_buf()
  local page_bytes = vim.uv.fs_stat(page).size

  local function check()
    local got = {}
    for _, d in ipairs(vim.diagnostic.get(buf, { namespace = diagnostics.ns })) do
      got[#got + 1] = d.code
    end
    table.sort(got)
    assert(vim.deep_equal(got, { 'missing_page', 'syntax', 'undeclared', 'unknown_call' })
      or vim.deep_equal(got, { 'missing_page', 'undeclared', 'unknown_call' }),
      'diagnósticos inesperados: ' .. vim.inspect(got))
    assert(vim.tbl_isempty(diagnostics.last_errors), vim.inspect(diagnostics.last_errors))
    return #got
  end

  -- Frío: cachés de includes y de símbolos vacías (lee y parsea los 20).
  local cold, cold_reads = {}, nil
  for _ = 1, RUNS do
    forget()
    local ms, reads = timed(function() diagnostics.refresh(buf) end)
    check()
    cold[#cold + 1] = ms
    cold_reads = reads
  end

  -- Caliente: nada cambió.
  local warm, warm_reads = {}, 0
  for _ = 1, RUNS do
    local ms, reads = timed(function() diagnostics.refresh(buf) end)
    check()
    warm[#warm + 1] = ms
    warm_reads = math.max(warm_reads, reads)
  end

  -- Tras editar el buffer: el árbol VBScript se vuelve a parsear.
  local edited, edited_reads = {}, 0
  for r = 1, RUNS do
    vim.api.nvim_buf_set_lines(buf, INCLUDES + 3, INCLUDES + 4, false, { ('total = %d'):format(r) })
    local ms, reads = timed(function() diagnostics.refresh(buf) end)
    check()
    edited[#edited + 1] = ms
    edited_reads = math.max(edited_reads, reads)
  end

  -- Desglose en caliente: cada pieza sola.
  local parts = {}
  local function part(name, fn)
    local xs = {}
    for _ = 1, RUNS do xs[#xs + 1] = timed(fn) end
    parts[#parts + 1] = ('%s=%.2f'):format(name, median(xs))
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  part('buffer_graph', function() return includes.buffer_graph(buf) end)
  part('literales', function() return require('asp.pages').buffer_literals(buf, lines) end)
  local saved = require('asp').options.diagnostics
  for _, only in ipairs({ 'includes', 'syntax', 'undeclared', 'missing_page' }) do
    local cfg = { includes = false, syntax = false, undeclared = false, unknown_call = false, missing_page = false }
    cfg[only] = 'WARN'
    if only == 'undeclared' then cfg.unknown_call = 'WARN' end
    require('asp').options.diagnostics = cfg
    part('solo_' .. only, function() diagnostics.refresh(buf) end)
  end
  require('asp').options.diagnostics = saved
  diagnostics.refresh(buf)

  print(('pagina_bytes=%d diagnosticos=%d'):format(page_bytes, check()))
  print(('refresh_frio_ms=%.2f lecturas=%d'):format(median(cold), cold_reads))
  print(('refresh_caliente_ms=%.2f lecturas=%d'):format(median(warm), warm_reads))
  print(('refresh_tras_editar_ms=%.2f lecturas=%d'):format(median(edited), edited_reads))
  print('desglose_caliente_ms ' .. table.concat(parts, ' '))
  assert(warm_reads == 0, 'el refresh en caliente leyó disco')
end, debug.traceback)

io.open = original_open
require('asp').options.virtual_root = previous_root
vim.fn.delete(root, 'rf')
if not ok then error(err) end
