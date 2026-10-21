-- Referencias VBScript con alcance de sitio: 500 páginas que incluyen una
-- librería de 50 funciones. Mide la primera consulta (cachés vacías), la
-- siguiente y la de otro nombre con la caché caliente, y cuenta lecturas.
--
--   nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/bench/symbols_site.lua
--
-- Con ASP_BENCH_ANTES=1 solo mide, sin validar resultados ni lecturas: sirve
-- para correr la misma carga con los módulos de una versión anterior
-- antepuestos en el runtimepath.
local root = vim.fn.tempname()
local symbols = require('asp.symbols')
local pages = require('asp.pages')
local includes = require('asp.includes')
local has_site = vim.env.ASP_BENCH_ANTES == nil
local paths, bytes = {}, 0
local previous_root = require('asp').options.virtual_root
local original_open = io.open
local buf, page_buf

vim.treesitter.language.register('aspclassic', 'asp')

local PAGES, FUNCTIONS = 500, 50

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
  table.insert(paths, path)
  bytes = bytes + vim.uv.fs_stat(path).size
end

local function median(list)
  local copy = vim.deepcopy(list)
  table.sort(copy)
  return copy[math.ceil(#copy / 2)]
end

local ok, err = xpcall(function()
  vim.fn.mkdir(root, 'p')
  root = assert(vim.uv.fs_realpath(root))
  require('asp').options.virtual_root = nil
  vim.fn.writefile({}, root .. '/web.config')

  local lib = { '<!--#include file="constantes.inc" -->', '<%' }
  for i = 1, FUNCTIONS do
    vim.list_extend(lib, {
      ('Function Fn%02d(valor)'):format(i),
      '  Dim parcial',
      ('  parcial = valor * %d + IVA'):format(i),
      ('  Fn%02d = parcial'):format(i),
      'End Function',
      '',
    })
  end
  table.insert(lib, '%>')
  local lib_path = root .. '/lib/funciones.inc'
  write(lib_path, lib)
  write(root .. '/lib/constantes.inc', { '<%', 'Const IVA = 12', '%>' })

  -- Unos 4 KB por página: directivas, un bloque VBScript con llamadas y una
  -- tabla HTML con <%= %>. Una de cada diez declara un parámetro Fn01, que
  -- no debe contarse.
  for i = 1, PAGES do
    local body = {
      '<!--#include virtual="/lib/funciones.inc" -->',
      '<%',
      'Dim total, i',
      ('total = Fn01(%d) + Fn02(total)'):format(i),
      '%>',
      '<table>',
    }
    for row = 1, 40 do
      body[#body + 1] = ('<tr><td class="celda"><%%= rs("campo%d") %%></td><td>Texto %d</td></tr>'):format(row, row)
    end
    body[#body + 1] = '</table>'
    if i % 10 == 0 then
      vim.list_extend(body, { '<%', 'Function Ajuste(Fn01)', '  Ajuste = Fn01 * 2', 'End Function', '%>' })
    end
    write(('%s/m%02d/p%04d.asp'):format(root, i % 10, i), body)
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, lib_path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lib)
  vim.bo[buf].filetype = 'asp'
  local fn01 = { line = 2, character = 9 }
  local fn02 = { line = 8, character = 9 }
  -- Prepara el parser del buffer fuera del cronómetro, como en un buffer
  -- ya abierto.
  vim.treesitter.get_parser(buf, 'aspclassic'):parse(true)

  local reads = 0
  io.open = function(path, mode)
    if mode == 'r' and type(path) == 'string' and path:sub(1, #root) == root then reads = reads + 1 end
    return original_open(path, mode)
  end
  local function measure(pos, expected_reads, source)
    reads = 0
    local start = vim.uv.hrtime()
    local refs = symbols.references(source or buf, pos)
    local elapsed = (vim.uv.hrtime() - start) / 1e6
    if has_site then
      -- Declaración y asignación de retorno en la librería, más una
      -- llamada por página; los parámetros Fn01 de las páginas no cuentan.
      assert(#refs == 2 + PAGES, ('referencias=%d, esperadas=%d'):format(#refs, 2 + PAGES))
      local per_page = {}
      for _, ref in ipairs(refs) do
        local page = ref.uri:match('/m%d+/p%d+%.asp$')
        if page then
          assert(ref.range.start.line == 3, 'línea inválida en ' .. ref.uri)
          per_page[page] = (per_page[page] or 0) + 1
        end
      end
      assert(vim.tbl_count(per_page) == PAGES, 'faltan páginas')
      if expected_reads then
        assert(reads == expected_reads, ('lecturas=%d, esperadas=%d'):format(reads, expected_reads))
      end
    end
    return elapsed, #refs, reads
  end

  print(('archivos=%d bytes=%d alcance_de_sitio=%s'):format(#paths, bytes, tostring(has_site)))
  local cold, warm, other, memory = {}, {}, {}, {}
  for run = 1, 5 do
    for _, path in ipairs(paths) do
      pages.invalidate(path)
      symbols.invalidate(path)
      includes.invalidate(path)
    end
    collectgarbage('collect')
    local before = collectgarbage('count')
    local elapsed, refs, cold_reads = measure(fn01)
    cold[run] = elapsed
    collectgarbage('collect')
    memory[run] = collectgarbage('count') - before
    local warm_ms, _, warm_reads = measure(fn01, 0)
    local other_ms, _, other_reads = measure(fn02, 0)
    warm[run], other[run] = warm_ms, other_ms
    print(('ronda=%d primera_ms=%.1f siguiente_ms=%.2f otro_nombre_ms=%.2f referencias=%d lecturas=%d/%d/%d memoria_kb=%.0f')
      :format(run, cold[run], warm[run], other[run], refs, cold_reads, warm_reads, other_reads, memory[run]))
  end
  print(('mediana primera_ms=%.1f siguiente_ms=%.2f otro_nombre_ms=%.2f memoria_kb=%.0f')
    :format(median(cold), median(warm), median(other), median(memory)))

  -- Desde una página que usa Fn01: mismo conjunto. La primera vez lee la
  -- librería, que hasta ahora solo se usó como buffer.
  local page_path = ('%s/m%02d/p%04d.asp'):format(root, 5, 5)
  page_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(page_buf, page_path)
  vim.api.nvim_buf_set_lines(page_buf, 0, -1, false, vim.fn.readfile(page_path))
  vim.bo[page_buf].filetype = 'asp'
  vim.treesitter.get_parser(page_buf, 'aspclassic'):parse(true)
  local from_page = { line = 3, character = 8 }
  local first_page, _, first_page_reads = measure(from_page, nil, page_buf)
  local next_page, _, next_page_reads = measure(from_page, 0, page_buf)
  print(('desde_pagina_primera_ms=%.2f lecturas=%d desde_pagina_siguiente_ms=%.2f lecturas=%d')
    :format(first_page, first_page_reads, next_page, next_page_reads))

  -- Una página cambiada: solo se relee esa (barrido y parseo).
  local changed = ('%s/m%02d/p%04d.asp'):format(root, 1, 1)
  local stat = assert(vim.uv.fs_stat(changed))
  local lines = vim.fn.readfile(changed)
  lines[#lines + 1] = '<p>Cambio</p>'
  vim.fn.writefile(lines, changed)
  assert(vim.uv.fs_utime(changed, stat.atime.sec, stat.mtime.sec + 2))
  local elapsed, _, changed_reads = measure(fn01, has_site and 2 or nil)
  print(('una_pagina_cambiada_ms=%.2f lecturas=%d'):format(elapsed, changed_reads))
end, debug.traceback)

require('asp').options.virtual_root = previous_root
io.open = original_open
for _, b in ipairs({ buf, page_buf }) do vim.api.nvim_buf_delete(b, { force = true }) end
vim.fn.delete(root, 'rf')
if not ok then error(err) end
