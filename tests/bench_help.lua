-- nvim --headless -u tests/minimal_init.lua -c "lua dofile('tests/bench_help.lua')"
-- Carga sintética: 20 KiB de VBScript y 20 includes, sin páginas del usuario.
local dir = vim.fn.tempname()
local original_open, original_parser = io.open, vim.treesitter.get_string_parser
local reads, parses = 0, 0
local ok, result = pcall(function()
  vim.fn.mkdir(dir, 'p')
  require('asp').setup({ diagnostics = false })
  local directives = {}
  for i = 1, 20 do
    local name = ('inc%02d.inc'):format(i)
    directives[#directives + 1] = ('<!--#include file="%s" -->'):format(name)
    vim.fn.writefile({ '<%', ('Function Incluida%02d(valor)'):format(i),
      ('Incluida%02d = valor'):format(i), 'End Function', ('Dim objeto%02d'):format(i),
      ('Set objeto%02d = CreateObject("Scripting.Dictionary")'):format(i), '%>' }, dir .. '/' .. name)
  end
  local prefix = table.concat(directives, '\n') .. '\n<%\nDim total, conn, rs\ntotal = 0\n'
    .. 'Set conn = CreateObject("ADODB.Connection")\nSet rs = conn.Execute("select 1")\n'
  local suffix = '\nResponse.Write rs.EOF\nrs.Open("SELECT 1", conn)\n \n%>\n'
  local line = 'total = total + Len("ejemplo de texto")\n'
  local repeats = math.floor((20480 - #prefix - #suffix) / #line)
  local content = prefix .. line:rep(repeats)
  content = content .. (' '):rep(20480 - #content - #suffix) .. suffix
  local file = assert(io.open(dir .. '/pagina.asp', 'w'))
  file:write(content)
  file:close()
  vim.cmd.edit(dir .. '/pagina.asp')
  local count = vim.api.nvim_buf_line_count(0)
  local completion_pos = { line = count - 2, character = 1 }
  local hover_pos = { line = count - 4, character = #('Response.Write rs.') }
  local signature_pos = { line = count - 3, character = #('rs.Open(') }
  local completion, hover, signature = require('asp.completion'), require('asp.hover'), require('asp.signature')
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
    assert(names.Replace and names.Replace.detail:find('Replace(', 1, true))
    assert(names.vbCrLf and names.Incluida20 and names.rs and names.Response)
    expected = expected or #items
    assert(#items == expected)
  end
  local function complete() check(completion.complete(0, completion_pos)) end
  local function show_hover()
    assert(hover.hover(0, hover_pos).contents.value:find('ADODB.Recordset.EOF', 1, true))
  end
  local function show_signature()
    assert(signature.help(0, signature_pos).signatures[1].label:find('ADODB.Recordset.Open(', 1, true))
  end
  local function lsp_complete()
    local response = assert(vim.lsp.buf_request_sync(0, 'textDocument/completion', params, 3000))[client.id]
    assert(response and not response.err)
    check(response.result)
  end
  for _ = 1, 15 do complete(); show_hover(); show_signature() end
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
    return { samples = n, median_ms = rounded((samples[math.floor(n / 2)] + samples[math.floor(n / 2) + 1]) / 2),
      p95_ms = rounded(samples[math.ceil(n * 0.95)]), min_ms = rounded(samples[1]), max_ms = rounded(samples[n]) }
  end
  local data = { bytes = #content, includes = #require('asp.includes').buffer_graph(0).order,
    nvim = tostring(vim.version()), completion_items = expected,
    completion = measure(complete, 200), hover = measure(show_hover, 100),
    signatureHelp = measure(show_signature, 100), lsp_completion = measure(lsp_complete, 100) }
  data.content_reads, data.string_parses, data.errors = reads, parses, 0
  assert(reads == 0 and parses == 0, 'hubo lectura o parseo de disco en caliente')
  local native, com = require('asp.vbscript_builtins'), require('asp.com')
  local members = 0
  for _, obj in pairs(com.types) do members = members + #obj.members end
  data.catalog = { functions = #native.groups.functions, constants = #native.groups.constants,
    com_types = vim.tbl_count(com.types), com_members = members, progids = #com.progids() }
  return data
end)
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
