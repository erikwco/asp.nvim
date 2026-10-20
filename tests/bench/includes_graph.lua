-- Mide en caliente las consultas cross-file que recorren el grafo de
-- includes (ver includes_graph.md). Desde la raíz del repo:
--
--   nvim --headless -u NONE -i NONE --cmd 'set rtp+=.' -l tests/bench/includes_graph.lua
--
-- Para medir otra revisión, anteponé un checkout con sus módulos:
-- --cmd 'set rtp^=/ruta/al/checkout'. Los parsers siguen saliendo de `.`
-- (`make parsers-test`); la salida dice de dónde se cargó cada módulo.
local RUNS = 5
local ROWS = 100

local root = vim.fn.tempname()
local previous_root = require('asp').options.virtual_root
local original_open = io.open

-- Cuenta las aperturas de archivo: con las cachés calientes, una consulta
-- no debería leer nada de disco.
local opens = 0
io.open = function(...)
  opens = opens + 1
  return original_open(...)
end

local function median(xs)
  table.sort(xs)
  return xs[math.ceil(#xs / 2)]
end

local function timed(fn)
  local start = vim.uv.hrtime()
  local res = fn()
  return (vim.uv.hrtime() - start) / 1e6, res
end

-- Un include con HTML, VBScript intercalado y, si `fns > 0`, un <script>
-- con `fns` funciones globales (la primera, js<i>): unas 110 líneas y 8 KB
-- con una función, el tamaño de un include de cabecera o de funciones chico.
local function include_lines(i, fns)
  local lines = {
    '<%',
    ('Function vb%03d(x)'):format(i),
    ('  vb%03d = x * %d'):format(i, i),
    'End Function',
    '%>',
    ('<div class="bloque" id="b%03d">'):format(i),
  }
  for r = 1, ROWS do
    lines[#lines + 1] = ('  <p class="fila">Fila %d: <%%= Server.HTMLEncode(rs("c%d")) %%></p>'):format(r, r)
  end
  if fns > 0 then
    vim.list_extend(lines, {
      '<script type="text/javascript">',
      ('function js%03d(e) {'):format(i),
      ('  var total = e + %d;'):format(i),
      '  return total;',
      '}',
    })
    for k = 2, fns do
      lines[#lines + 1] = ('function js%03d_%d(e) { return e + %d; }'):format(i, k, k)
    end
    lines[#lines + 1] = '</script>'
  end
  lines[#lines + 1] = '</div>'
  return lines
end

-- Proyecto con una página que incluye `n` archivos en `inc/` y termina con
-- `body`, alternando includes `file=` y `virtual=` (contra el web.config de
-- la raíz). Devuelve el buffer de la página, abierto como asp.
local function project(name, n, fns, body)
  local dir = ('%s/%s'):format(root, name)
  vim.fn.mkdir(dir .. '/inc', 'p')
  local page = {}
  for i = 1, n do
    vim.fn.writefile(include_lines(i, fns), ('%s/inc/i%03d.inc'):format(dir, i))
    page[#page + 1] = i % 2 == 0
      and ('<!--#include file="inc/i%03d.inc" -->'):format(i)
      or ('<!--#include virtual="/%s/inc/i%03d.inc" -->'):format(name, i)
  end
  vim.list_extend(page, body)
  vim.fn.writefile(page, dir .. '/pagina.asp')
  vim.cmd.edit(dir .. '/pagina.asp')
  vim.bo.filetype = 'asp'
  return vim.api.nvim_get_current_buf()
end

-- Posición (0-indexed) de `word` en la primera línea de `buf` que lo tiene.
local function pos_of(buf, word)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local col = line:find(word, 1, true)
    if col then return { line = i - 1, character = col - 1 } end
  end
  error('no aparece: ' .. word)
end

local function source_of(mod, fn)
  return debug.getinfo(require(mod)[fn], 'S').source:gsub('^@', '')
end

local ok, err = xpcall(function()
  vim.fn.mkdir(root, 'p')
  root = assert(vim.uv.fs_realpath(root))
  vim.fn.writefile({}, root .. '/web.config')
  require('asp').options.virtual_root = nil
  vim.treesitter.language.register('aspclassic', 'asp')

  local includes = require('asp.includes')
  local js = require('asp.js')
  local symbols = require('asp.symbols')
  print(('nvim=%s'):format(tostring(vim.version())))
  for _, m in ipairs({ { 'asp.includes', 'graph' }, { 'asp.js', 'definition' }, { 'asp.symbols', 'definition' } }) do
    print(('%s=%s'):format(m[1], source_of(m[1], m[2])))
  end

  local function js_page(n)
    return { '<html><body>', '<script>', ('js%03d(1);'):format(n), '</script>', '</body></html>' }
  end

  -- Cada caso: buffer, consulta y comprobación del resultado. La función
  -- buscada está en el último include: la consulta recorre todo el grafo.
  local function js_def(name, n, fns)
    local buf = project(name, n, fns, js_page(n))
    local pos = pos_of(buf, ('js%03d'):format(n))
    return buf, function() return js.definition(buf, pos) end, function(loc)
      assert(loc and loc.uri:match(('/i%03d%%.inc$'):format(n)), 'definición JS inesperada')
    end
  end

  local cases = {
    { 'js_def_20', function() return js_def('paginas20', 20, 1) end },
    { 'js_def_100', function() return js_def('paginas100', 100, 1) end },
    { 'vb_def_100', function()
      local buf = project('vbscript100', 100, 0, { '<%', 'Dim r : r = vb100(2)', '%>' })
      local pos = pos_of(buf, 'vb100')
      return buf, function() return symbols.definition(buf, pos) end, function(loc)
        assert(loc and loc.uri:match('/i100%.inc$'), 'definición VBScript inesperada')
      end
    end },
    { 'js_refs_100', function()
      vim.cmd.edit(root .. '/paginas100/pagina.asp')
      vim.bo.filetype = 'asp'
      local buf = vim.api.nvim_get_current_buf()
      local pos = pos_of(buf, 'js100')
      return buf, function() return js.references(buf, pos) end, function(refs)
        assert(refs and #refs == 2, 'referencias JS inesperadas')
      end
    end },
    -- El caso de la nota de rendimiento del README: includes de 250
    -- funciones JS, cuyas plantillas son caras de reparsear.
    { 'js_def_20_250fn', function() return js_def('grandes20', 20, 250) end },
  }

  for _, case in ipairs(cases) do
    local buf, query, check = case[2]()
    -- Calienta las cachés (archivos, datos del buffer, grafo).
    check(query())
    check(query())
    opens = 0
    check(query())
    local reads = opens
    local q, g = {}, {}
    for _ = 1, RUNS do
      local ms, res = timed(query)
      check(res)
      q[#q + 1] = ms
      g[#g + 1] = timed(function() return includes.buffer_graph(buf) end)
    end
    print(('caso=%s consulta_ms=%.3f buffer_graph_ms=%.3f lecturas=%d'):format(
      case[1], median(q), median(g), reads))
  end
end, debug.traceback)

io.open = original_open
require('asp').options.virtual_root = previous_root
vim.fn.delete(root, 'rf')
if not ok then error(err) end
