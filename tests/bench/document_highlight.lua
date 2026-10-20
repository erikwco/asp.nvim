-- nvim --headless -u tests/minimal_init.lua -l tests/bench/document_highlight.lua
-- PR8_BENCH_OUTPUT=/tmp/resultados.json guarda las muestras y la verificación.
local runs = 7
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/inc', 'p')
root = vim.uv.fs_realpath(root)
local lsp = require('asp.lsp')
local original_open = io.open
local reads = 0
io.open = function(path, ...)
  if path:sub(1, #root) == root then reads = reads + 1 end
  return original_open(path, ...)
end

local function stats(samples)
  local sorted = vim.deepcopy(samples)
  table.sort(sorted)
  return { median = sorted[math.ceil(#sorted / 2)], min = sorted[1], max = sorted[#sorted], samples = samples }
end

local function timed(fn)
  reads = 0
  local start = vim.uv.hrtime()
  local result = fn()
  return (vim.uv.hrtime() - start) / 1e6, result, reads
end

local function open(name, lines)
  local path = root .. '/' .. name
  vim.fn.writefile(lines, path)
  vim.cmd.edit(path)
  assert(vim.wait(3000, function()
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    return client and client.initialized
  end), 'asp-ls no se adjuntó')
  local ready = false
  vim.schedule(function() ready = true end)
  assert(vim.wait(3000, function() return ready end))
end

local function measure(label, line, character, expected, declaration)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(0) },
    position = { line = line, character = character },
    context = { includeDeclaration = true },
  }
  local function direct(method) return lsp.handlers['textDocument/' .. method](params) end
  local function validate(method, result)
    assert(type(result) == 'table' and #result == expected[method], label .. ': cantidad incorrecta en ' .. method)
    if method == 'documentHighlight' then
      for _, item in ipairs(result) do
        local pos = item.range.start
        local is_decl = pos.line == declaration[1] and pos.character == declaration[2]
        assert(item.kind == (is_decl and 3 or 2), label .. ': kind incorrecto')
      end
    end
  end
  local expected_ranges = {}
  for _, ref in ipairs(direct('references')) do
    if ref.uri == params.textDocument.uri then table.insert(expected_ranges, ref.range) end
  end
  local function validate_highlights(result)
    validate('documentHighlight', result)
    local ranges = {}
    for _, item in ipairs(result) do table.insert(ranges, item.range) end
    assert(vim.deep_equal(expected_ranges, ranges), label .. ': rangos distintos de references')
  end
  validate_highlights(direct('documentHighlight'))
  local samples = { documentHighlight = {}, references = {}, client = {} }
  local disk = { documentHighlight = {}, references = {} }
  for i = 1, runs do
    local order = i % 2 == 1 and { 'documentHighlight', 'references' } or { 'references', 'documentHighlight' }
    for _, method in ipairs(order) do
      local elapsed, result, count = timed(function() return direct(method) end)
      validate(method, result)
      if method == 'documentHighlight' then validate_highlights(result) end
      table.insert(samples[method], elapsed)
      table.insert(disk[method], count)
    end
  end
  for _ = 1, runs do
    local elapsed, responses = timed(function()
      return vim.lsp.buf_request_sync(0, 'textDocument/documentHighlight', params, 10000)
    end)
    assert(responses and next(responses), label .. ': falta respuesta LSP')
    for _, response in pairs(responses) do
      assert(not response.err, vim.inspect(response.err))
      validate_highlights(response.result)
    end
    table.insert(samples.client, elapsed)
  end
  -- Atribución separada de las muestras: tiempo inclusivo en collect.
  local symbols = require('asp.symbols')
  local collect, collect_ms, calls = symbols.collect, 0, 0
  symbols.collect = function(...)
    local start = vim.uv.hrtime()
    local result = collect(...)
    collect_ms = collect_ms + (vim.uv.hrtime() - start) / 1e6
    calls = calls + 1
    return result
  end
  local total, result = timed(function() return direct('documentHighlight') end)
  symbols.collect = collect
  validate_highlights(result)
  local out = {
    case = label, lines = vim.api.nvim_buf_line_count(0), counts = expected, reads = disk,
    documentHighlight = stats(samples.documentHighlight), references = stats(samples.references),
    client = stats(samples.client), attribution = { total_ms = total, collect_ms = collect_ms, collect_calls = calls },
  }
  print(vim.json.encode(out))
  return out
end

local ok, result = pcall(function()
  local cases = {}
  local big = { '<%', 'Dim total', 'total = 0' }
  for i = 0, 2999 do
    vim.list_extend(big, {
      ('Function F%d(n)'):format(i), '  Dim contador', ('  contador = n + %d'):format(i),
      '  total = total + contador', ('  F%d = contador'):format(i), 'End Function',
    })
  end
  vim.list_extend(big, { 'Response.Write total', '%>' })
  open('vb3000.asp', big)
  cases[#cases + 1] = measure('3000 Functions: total de página', 9006, 2,
    { documentHighlight = 6003, references = 6003 }, { 1, 4 })
  cases[#cases + 1] = measure('3000 Functions: contador local', 9005, 3,
    { documentHighlight = 4, references = 4 }, { 9004, 6 })
  cases[#cases + 1] = measure('3000 Functions: F1500', 9003, 9,
    { documentHighlight = 2, references = 2 }, { 9003, 9 })
  vim.cmd('bwipeout!')

  local page = {}
  for i = 0, 19 do
    local include = { '<%' }
    for j = 0, 149 do
      vim.list_extend(include, {
        ('Function L%d_%d(x)'):format(i, j), ('  L%d_%d = x + total'):format(i, j), 'End Function',
      })
    end
    include[#include + 1] = '%>'
    vim.fn.writefile(include, ('%s/inc/lib%d.inc'):format(root, i))
    page[#page + 1] = ('<!--#include file="inc/lib%d.inc" -->'):format(i)
  end
  vim.list_extend(page, { '<%', 'Dim total', 'total = 1', 'Response.Write total', '%>' })
  open('includes20.asp', page)
  cases[#cases + 1] = measure('20 includes de 452 líneas: total de página', 22, 0,
    { documentHighlight = 3, references = 3003 }, { 21, 4 })
  vim.cmd('bwipeout!')
  return { nvim = tostring(vim.version()), runs = runs, cases = cases, failures = 0 }
end)
io.open = original_open
vim.fn.delete(root, 'rf')
if not ok then error(result) end
if vim.env.PR8_BENCH_OUTPUT then
  vim.fn.writefile({ vim.json.encode(result) }, vim.env.PR8_BENCH_OUTPUT)
end
vim.cmd('qa!')
