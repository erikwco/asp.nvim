-- nvim --headless -u tests/minimal_init.lua -i NONE -c "lua dofile('tests/bench/js_help.lua')"
-- Página sintética de 20 KiB, 20 includes y 5 archivos JS externos.
local dir = vim.fn.tempname()
local original_open, original_parser = io.open, vim.treesitter.get_string_parser
local reads, parses = 0, 0
local ok, result = xpcall(function()
  vim.fn.mkdir(dir, 'p')
  require('asp').setup({ diagnostics = false })
  local directives = {}
  for i = 1, 20 do
    local name = ('inc%02d.inc'):format(i)
    directives[#directives + 1] = ('<!--#include file="%s" -->'):format(name)
    vim.fn.writefile({ '<% Dim dato %>', '<script>',
      ('function incluida%02d(valor, extra = 1) { return valor + extra; }'):format(i),
      '</script>' }, dir .. '/' .. name)
  end
  for i = 1, 5 do
    local name = ('util%02d.js'):format(i)
    directives[#directives + 1] = ('<script src="%s"></script>'):format(name)
    local lines = {}
    for j = 1, 10 do
      lines[#lines + 1] = ('function externa%02d_%02d(valor) { return valor; }'):format(i, j)
    end
    vim.fn.writefile(lines, dir .. '/' .. name)
  end
  local prefix = table.concat(directives, '\n') .. '\n<h1>Medición JS</h1>\n<script>\n'
    .. 'function propia(valor) { return valor; }\nlet total = 0;\n'
  local suffix = '\nincluida20(1, 2);\n \n</script>\n'
  local line = 'total += propia("texto de prueba, con comas");\n'
  local content = prefix .. line:rep(math.floor((20480 - #prefix - #suffix) / #line))
  content = content .. (' '):rep(20480 - #content - #suffix) .. suffix
  local file = assert(io.open(dir .. '/pagina.asp', 'w'))
  file:write(content)
  file:close()
  vim.cmd.edit(dir .. '/pagina.asp')
  local count = vim.api.nvim_buf_line_count(0)
  local completion_pos = { line = count - 2, character = 1 }
  local hover_pos = { line = count - 3, character = 0 }
  local signature_pos = { line = count - 3, character = #'incluida20(1, ' }
  local help = require('asp.js_help')
  assert(vim.wait(3000, function()
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    return client and client.initialized
  end), 'asp-ls no inicializó')
  local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
  local params = { textDocument = vim.lsp.util.make_text_document_params(), position = completion_pos }
  local expected
  local function check(items)
    local names = {}
    for _, item in ipairs(items) do names[item.label] = item end
    assert(names.propia and names.incluida20 and names.externa05_10 and names.total and names.document)
    assert(not names.Response and not names['function'])
    expected = expected or #items
    assert(#items == expected)
  end
  local function complete() check(help.complete(0, completion_pos)) end
  local function hover()
    assert(help.hover(0, hover_pos).contents.value:find('Archivo: `inc20.inc`', 1, true))
  end
  local function signature()
    local response = assert(help.signature(0, signature_pos))
    assert(response.activeParameter == 1 and #response.signatures[1].parameters == 2)
  end
  local function lsp_complete()
    local response = assert(vim.lsp.buf_request_sync(0, 'textDocument/completion', params, 3000))[client.id]
    assert(response and not response.err)
    check(response.result)
  end
  for _ = 1, 15 do complete(); hover(); signature() end
  lsp_complete()
  io.open = function(...) reads = reads + 1; return original_open(...) end
  vim.treesitter.get_string_parser = function(...) parses = parses + 1; return original_parser(...) end
  local function measure(fn, n)
    local samples = {}
    for _ = 1, n do
      local start = vim.uv.hrtime()
      fn()
      samples[#samples + 1] = (vim.uv.hrtime() - start) / 1e6
    end
    table.sort(samples)
    local function rounded(value) return tonumber(('%.3f'):format(value)) end
    return { samples = n, median_ms = rounded((samples[n / 2] + samples[n / 2 + 1]) / 2),
      p95_ms = rounded(samples[math.ceil(n * 0.95)]), min_ms = rounded(samples[1]), max_ms = rounded(samples[n]) }
  end
  local data = { bytes = #content, includes = #require('asp.includes').buffer_graph(0).order,
    external_js = 5, nvim = tostring(vim.version()), completion_items = expected,
    catalog = require('asp.dom').count, completion = measure(complete, 200), hover = measure(hover, 100),
    signatureHelp = measure(signature, 100), lsp_completion = measure(lsp_complete, 100) }
  data.content_reads, data.string_parses, data.errors = reads, parses, 0
  assert(reads == 0 and parses == 0, 'hubo lectura o parseo en caliente')
  -- Perfil separado de las muestras publicadas, opt-in para localizar el coste.
  if vim.env.ASP_JS_PROFILE then
    local costs, restores = {}, {}
    for _, target in ipairs({ { require('asp.js_context'), 'mask' }, { require('asp.js'), 'visible' } }) do
      local module, name = target[1], target[2]
      local original = module[name]
      costs[name] = 0
      module[name] = function(...)
        local start = vim.uv.hrtime()
        local value = original(...)
        costs[name] = costs[name] + (vim.uv.hrtime() - start) / 1e6
        return value
      end
      restores[#restores + 1] = function() module[name] = original end
    end
    local start = vim.uv.hrtime()
    for _ = 1, 200 do complete() end
    costs.total = (vim.uv.hrtime() - start) / 1e6
    for _, restore in ipairs(restores) do restore() end
    data.profile_ms = costs
  end
  return data
end, debug.traceback)
io.open, vim.treesitter.get_string_parser = original_open, original_parser
vim.cmd('bwipeout!')
vim.fn.delete(dir, 'rf')
if not ok then
  print(result)
  vim.cmd('cquit 1')
else
  print(vim.json.encode(result))
  vim.cmd('qa!')
end
