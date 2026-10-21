-- ASP_BENCH_FILE=/ruta/pagina.asp nvim --headless -u tests/minimal_init.lua \
--   -i NONE -l tests/bench/semantic_tokens.lua
-- Sin ASP_BENCH_FILE usa una página sintética. Cada proceso mide una
-- primera llamada con parsers y cachés vacíos, otra caliente y una edición.
local path = vim.env.ASP_BENCH_FILE
local temporary = path == nil
if temporary then
  path = vim.fn.tempname() .. '.asp'
  local lines = { '<html>' }
  for i = 1, 350 do
    vim.list_extend(lines, {
      ('<%% Function Sumar%d(n)'):format(i),
      ' Dim total: total = n + 1', (' Sumar%d = total'):format(i),
      'End Function %>', ('<p>ñandú <%%=Sumar%d(2)%%></p>'):format(i),
      '<script>', ('function sumar%d(n) {'):format(i),
      ' const total = n + 1; return total;', '}',
      ('sumar%d(2);'):format(i), '</script>',
    })
  end
  lines[#lines + 1] = '</html>'
  vim.fn.writefile(lines, path)
end

vim.cmd('noautocmd edit ' .. vim.fn.fnameescape(path))
vim.cmd('noautocmd setlocal filetype=asp')
local semantic = require('asp.semantic_tokens')
local function measure(fn)
  local start = vim.uv.hrtime()
  local result = fn()
  local elapsed = (vim.uv.hrtime() - start) / 1e6
  assert(#result.data > 0 and #result.data % 5 == 0, 'faltan tokens')
  return { ms = elapsed, tokens = #result.data / 5 }
end

local out = { nvim = tostring(vim.version()), bytes = vim.uv.fs_stat(path).size }
out.cold = measure(function() return semantic.full(0) end)
out.warm = measure(function() return semantic.full(0) end)
local line = vim.api.nvim_buf_get_lines(0, 0, 1, true)[1]
vim.api.nvim_buf_set_lines(0, 0, 1, true, { line .. ' ' })
out.edited = measure(function() return semantic.full(0) end)
assert(out.cold.tokens == out.warm.tokens and out.cold.tokens == out.edited.tokens,
  'cambió la cantidad de tokens tras agregar un espacio')
print(vim.json.encode(out))
vim.cmd('bwipeout!')
if temporary then vim.fn.delete(path) end
vim.cmd('qa!')
