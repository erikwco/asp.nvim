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
  local body = {}
  for j = 1, 120 do
    body[#body + 1] = ([[  sql = "SELECT a, b FROM t WHERE id = '" & id & "' AND x = 'y'" ' comentario %d]]):format(j)
    body[#body + 1] = [[  Response.Write "<td class=""celda"" style=""width:10px"">" & rs("campo") & "</td>"]]
  end
  body[#body + 1] = [[<a href="/destino.asp?id=1">d</a> <a href="otra.asp">o</a>]]
  local extensions = { 'asp', 'asp', 'asp', 'inc', 'htm', 'js' }
  for i = 1, 5000 do
    local dir = ('%s/m%02d/s%02d'):format(root, i % 20, i % 7)
    vim.fn.mkdir(dir, 'p')
    write(('%s/p%05d.%s'):format(dir, i, extensions[i % #extensions + 1]), body)
  end
  local mini = {}
  for i = 1, 3000 do
    mini[#mini + 1] = ('a.fn.x%d=function(e){return"string"===typeof e?\'k%d\':e}'):format(i, i)
  end
  vim.fn.mkdir(root .. '/Scripts', 'p')
  for i = 1, 5 do
    write(root .. ('/Scripts/jquery%d.min.js'):format(i), { table.concat(mini, ';') })
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, target)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '<p>Destino</p>' })
  local expected = 5000
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
      assert(ref.uri:match('/m%d+/s%d+/p%d+%.'), 'archivo inesperado')
      assert(ref.range.start.line == 240 and ref.range['end'].line == 240, 'línea inválida')
      assert(ref.range.start.character == 9 and ref.range['end'].character == 26, 'columnas inválidas')
    end
    return elapsed
  end
  print(('archivos=%d bytes=%d referencias=%d'):format(#paths, bytes, expected))
  for run = 1, 5 do
    for _, path in ipairs(paths) do pages.invalidate(path) end
    local cold = measure(#paths)
    local warm = measure(0)
    print(('ronda=%d cache_vacia_ms=%.3f siguiente_ms=%.3f lecturas=%d/0'):format(run, cold, warm, #paths))
  end
end, debug.traceback)

require('asp').options.virtual_root = previous_root
io.open = original_open
if buf then vim.api.nvim_buf_delete(buf, { force = true }) end
vim.fn.delete(root, 'rf')
if not ok then error(err) end
