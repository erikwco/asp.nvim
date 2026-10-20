local root = vim.fn.tempname()
local target
local pages = require('asp.pages')
local paths, bytes = {}, 0
local previous_root = require('asp').options.virtual_root
local original_open = io.open
local buf

local function write(path, lines)
  vim.fn.writefile(lines, path)
  table.insert(paths, path)
  bytes = bytes + vim.uv.fs_stat(path).size
end

local ok, err = xpcall(function()
  vim.fn.mkdir(root, 'p')
  root = assert(vim.uv.fs_realpath(root))
  target = root .. '/destino.asp'
  require('asp').options.virtual_root = nil
  vim.fn.writefile({}, root .. '/web.config')
  write(target, { '<p>Destino</p>' })
  local extensions = { 'asp', 'inc', 'htm', 'html', 'js' }
  for i = 1, 499 do
    local lines = {}
    for j = 1, 10 do
      table.insert(lines, '<a href="/destino.asp?id=' .. j .. '">Destino</a>')
      table.insert(lines, [[<% Response.Redirect "destino.asp#detalle" %>]])
      table.insert(lines, [[<!--#include virtual="destino.asp" -->]])
      table.insert(lines, [[<script>location.href = 'destino.asp';</script>]])
    end
    write(root .. ('/pagina-%03d.'):format(i) .. extensions[(i - 1) % #extensions + 1], lines)
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, target)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '<p>Destino</p>' })
  local expected = 499 * 40
  local reads = 0
  io.open = function(path, mode)
    if mode == 'r' then reads = reads + 1 end
    return original_open(path, mode)
  end
  local function measure(expected_reads)
    reads = 0
    local start = vim.uv.hrtime()
    local refs = pages.references(buf, { line = 0, character = 0 })
    local elapsed = (vim.uv.hrtime() - start) / 1e6
    assert(refs and #refs == expected, 'referencias incompletas')
    assert(reads == expected_reads, ('lecturas=%d, esperadas=%d'):format(reads, expected_reads))
    for _, ref in ipairs(refs) do
      assert(ref.uri:find('/pagina-', 1, true), 'archivo inesperado')
      assert(ref.range.start.line >= 0 and ref.range.start.line < 40, 'línea inválida')
      assert(ref.range['end'].character > ref.range.start.character, 'rango vacío')
    end
    return elapsed
  end
  print(('archivos=%d bytes=%d referencias=%d'):format(#paths, bytes, expected))
  for run = 1, 5 do
    for _, path in ipairs(paths) do pages.invalidate(path) end
    local cold = measure(500)
    local warm = measure(0)
    print(('ronda=%d cache_vacia_ms=%.3f siguiente_ms=%.3f lecturas=500/0'):format(run, cold, warm))
  end
end, debug.traceback)

require('asp').options.virtual_root = previous_root
io.open = original_open
if buf then vim.api.nvim_buf_delete(buf, { force = true }) end
vim.fn.delete(root, 'rf')
if not ok then error(err) end
