-- Mide `gg=G` y la indentación al abrir una línea (`o`) sobre una página
-- sintética de ~300 KB sin indentar (ver indent.md). Desde la raíz del
-- repo, con los parsers de `make parsers-test`:
--
--   nvim --headless -u tests/minimal_init.lua -l tests/bench/indent.lua
--
-- BLOQUES cambia el tamaño (cada bloque tiene ~880 bytes y 50 líneas).
local BLOQUES = tonumber(vim.env.BLOQUES) or 350
local RUNS = 7

local function median(xs)
  local sorted = vim.deepcopy(xs)
  table.sort(sorted)
  return sorted[math.ceil(#sorted / 2)]
end

-- HTML con un <% If %> que lo envuelve, un bloque VBScript con Sub, For
-- Each e If, y un <script> con una función JS.
local function block(i)
  return {
    '<div class="seccion">',
    '<h2>Sección ' .. i .. '</h2>',
    '<% If mostrar Then %>',
    '<table class="datos">',
    '<tr>',
    '<td class="nombre"><%= nombre %></td>',
    '<td class="valor"><%= valor %></td>',
    '</tr>',
    '</table>',
    '<% Else %>',
    '<p class="vacio">Sin datos para mostrar en esta sección.</p>',
    '<% End If %>',
    '<%',
    ('Sub Procesar%03d(lista)'):format(i),
    'Dim item, total',
    'total = 0',
    'For Each item In lista',
    'If item > 0 Then',
    'total = total + item',
    'ElseIf item = 0 Then',
    'total = total + 1',
    'Else',
    'total = total - 1',
    'End If',
    'Next',
    'Select Case total',
    'Case 0',
    'Response.Write "cero"',
    'Case Else',
    'Response.Write "total: " & total',
    'End Select',
    'End Sub',
    '%>',
    '<script type="text/javascript">',
    ('function calcular%03d(a, b) {'):format(i),
    'var suma = a + b;',
    'if (suma > 10) {',
    'for (var j = 0; j < suma; j++) {',
    'suma = suma - j;',
    '}',
    'return suma;',
    '}',
    'return 0;',
    '}',
    '</script>',
    '<ul>',
    '<li><a href="pagina.asp?id=' .. i .. '">Ver detalle</a></li>',
    '<li><a href="otra.asp?id=' .. i .. '">Editar registro</a></li>',
    '</ul>',
    '</div>',
  }
end

local lines = { '<%@ Language=VBScript %>', '<html>', '<body>' }
for i = 1, BLOQUES do vim.list_extend(lines, block(i)) end
vim.list_extend(lines, { '</body>', '</html>' })
local path = vim.fn.tempname() .. '.asp'
vim.fn.writefile(lines, path)

local function open()
  vim.cmd('silent! %bwipeout!')
  vim.cmd.edit(path)
  vim.bo.shiftwidth = 4
  vim.bo.expandtab = true
end

-- Tiempo de HtmlIndent (incluye el indent de JavaScript de Vim que usa en
-- los <script>) frente al total de indentexpr.
local indent = require('asp.indent')
local html_ms, expr_ms = 0, 0
local function instrument()
  indent.html_available()
  local html = vim.fn.HtmlIndent
  vim.fn.HtmlIndent = function()
    local start = vim.uv.hrtime()
    local result = html()
    html_ms = html_ms + (vim.uv.hrtime() - start) / 1e6
    return result
  end
  _G.asp_bench_indentexpr = function()
    local start = vim.uv.hrtime()
    local result = indent.indentexpr()
    expr_ms = expr_ms + (vim.uv.hrtime() - start) / 1e6
    return result
  end
  vim.bo.indentexpr = 'v:lua.asp_bench_indentexpr()'
end

local function reindent()
  html_ms, expr_ms = 0, 0
  local start = vim.uv.hrtime()
  vim.cmd('silent normal! gg=G')
  return (vim.uv.hrtime() - start) / 1e6
end

open()
instrument()
local cold = reindent()
local cold_html, cold_expr = html_ms, expr_ms
local first = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local warm = reindent()
local stable = vim.deep_equal(first, vim.api.nvim_buf_get_lines(0, 0, -1, false))

-- `o` en una línea de código del último Sub y en una línea HTML del final.
local function open_line(pattern)
  local target
  for i = #first, 1, -1 do
    if first[i]:find(pattern) then target = i break end
  end
  local samples = {}
  for _ = 1, RUNS do
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    expr_ms = 0
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('ox<Esc>', true, false, true), 'xt', false)
    samples[#samples + 1] = expr_ms
    vim.cmd('silent undo')
  end
  return median(samples)
end
local code_o = open_line('^%s*total = total %+ item$')
local html_o = open_line('^%s*<li><a href="otra')

-- El mismo buffer como HTML puro, con HtmlIndent directo.
vim.bo.filetype = 'html'
vim.bo.shiftwidth = 4
vim.bo.expandtab = true
local native = reindent()

print(('Neovim %s, %d líneas, %d bytes'):format(tostring(vim.version()), #lines, vim.fn.getfsize(path)))
print(('gg=G en frío: %.0f ms (indentexpr %.0f ms, HtmlIndent %.0f ms, asp.nvim %.0f ms)'):format(
  cold, cold_expr, cold_html, cold_expr - cold_html))
print(('gg=G en caliente: %.0f ms; estable: %s'):format(warm, tostring(stable)))
print(('o en código: %.2f ms; o en HTML: %.2f ms (medianas de %d)'):format(code_o, html_o, RUNS))
print(('el mismo buffer con ft=html y HtmlIndent: %.0f ms'):format(native))
vim.fn.delete(path)
vim.cmd('qa!')
