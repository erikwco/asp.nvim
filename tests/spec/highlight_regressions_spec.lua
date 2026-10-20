describe('asp-ls regresiones de resaltado', function()
  local root, bufnr

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    root = vim.uv.fs_realpath(root)
  end)

  after_each(function()
    if bufnr then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    vim.fn.delete(root, 'rf')
  end)

  local function open(lines)
    vim.cmd.edit(root .. '/pagina.asp')
    bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    assert.is_true(vim.wait(2000, function()
      local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'asp-ls' })[1]
      return client and client.initialized
    end))
  end

  local function params(line, character)
    return {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = line, character = character },
      context = { includeDeclaration = true },
    }
  end

  local function request(method, line, character)
    local responses = vim.lsp.buf_request_sync(bufnr, 'textDocument/' .. method, params(line, character), 3000)
    assert.is_not_nil(responses)
    for _, response in pairs(responses) do
      assert.is_nil(response.err)
      return response.result
    end
    error('asp-ls no respondió')
  end

  local function highlight(line, character, kind)
    return {
      range = {
        start = { line = line, character = character },
        ['end'] = { line = line, character = character + 1 },
      },
      kind = kind,
    }
  end

  it('resuelve el i de página al include y excluye los locales de Sumar', function()
    vim.fn.writefile({ '<% Dim i %>' }, root .. '/comun.inc')
    open({
      '<!--#include file="comun.inc"-->', '<%',
      'Function Sumar(n)', '  Dim i, s', '  For i = 1 To n',
      '    s = s + i', '  Next', 'End Function',
      'For i = 1 To 3', '  Response.Write i', 'Next', '%>',
    })
    local definition = request('definition', 8, 4)
    assert.are.equal(vim.uri_from_fname(root .. '/comun.inc'), definition.uri)
    assert.are.same(highlight(0, 7).range, definition.range)
    local refs = request('references', 8, 4)
    assert.are.same({
      { uri = vim.uri_from_bufnr(bufnr), range = highlight(8, 4).range },
      { uri = vim.uri_from_bufnr(bufnr), range = highlight(9, 17).range },
      { uri = definition.uri, range = definition.range },
    }, refs)
    assert.are.same({ highlight(8, 4, 2), highlight(9, 17, 2) }, request('documentHighlight', 8, 4))
  end)

  it('el Dim de página excluye el Dim local y sus usos, pero conserva usos sin sombreado', function()
    open({
      '<%', 'Dim x', 'x = 1',
      'Function Sumar()', '  Dim x', '  x = 2', 'End Function',
      'Sub Mostrar()', '  Response.Write x', 'End Sub', '%>',
    })
    local expected = { highlight(1, 4, 3), highlight(2, 0, 2), highlight(8, 17, 2) }
    assert.are.same(expected, request('documentHighlight', 1, 4))
    local refs = request('references', 1, 4)
    assert.are.equal(#expected, #refs)
    for i, ref in ipairs(refs) do assert.are.same(expected[i].range, ref.range) end
    assert.are.same({ highlight(4, 6, 3), highlight(5, 2, 2) }, request('documentHighlight', 5, 2))
  end)

  local function without_reads(line, character)
    local original, reads = io.open, {}
    io.open = function(path, ...)
      if path:sub(1, #root) == root then table.insert(reads, path) end
      return original(path, ...)
    end
    local ok, result = pcall(request, 'documentHighlight', line, character)
    io.open = original
    assert.is_true(ok, tostring(result))
    assert.are.same({}, reads)
    return result
  end

  it('no lee includes para resaltar un binding VBScript del buffer', function()
    vim.fn.writefile({ '<% Dim x: x = 3 %>' }, root .. '/comun.inc')
    open({ '<!--#include file="comun.inc"-->', '<%', 'Dim x', 'x = 1', '%>' })
    assert.are.same({ highlight(2, 4, 3), highlight(3, 0, 2) }, without_reads(3, 0))
  end)

  it('no lee scripts externos ni includes para resaltar un global JS del buffer', function()
    vim.fn.writefile({ 'var x = 3;' }, root .. '/externo.js')
    vim.fn.writefile({ '<script>var x = 4;</script>' }, root .. '/comun.inc')
    open({
      '<!--#include file="comun.inc"-->', '<script src="externo.js"></script>',
      '<script>', 'var x = 1;', 'x++;', 'function f() { var x = 2; return x; }', '</script>',
      '<button onclick="x++">Sumar</button>',
    })
    assert.are.same({ highlight(3, 4, 3), highlight(4, 0, 2), highlight(7, 17, 2) }, without_reads(4, 0))
  end)

  it('asigna ids distintos a requests del mismo tick y entrega ambas respuestas', function()
    open({ '<%', 'Dim x', 'x = 1', '%>' })
    local replies = {}
    local ids = {}
    for _, method in ipairs({ 'documentHighlight', 'hover' }) do
      local requests = vim.lsp.buf_request(bufnr, 'textDocument/' .. method, params(2, 0), function(err, result)
        assert.is_nil(err)
        replies[method] = { result = result }
      end)
      for _, id in pairs(requests) do table.insert(ids, id) end
    end
    assert.are.equal(2, #ids)
    assert.are_not.equal(ids[1], ids[2])
    assert.is_true(vim.wait(2000, function() return replies.documentHighlight and replies.hover end))
    assert.are.same({ highlight(1, 4, 3), highlight(2, 0, 2) }, replies.documentHighlight.result)
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'asp-ls' })[1]
    assert.is_true(vim.wait(2000, function() return next(client.requests) == nil end))
  end)
end)
