describe('treesitter en buffers asp', function()
  before_each(function()
    vim.cmd.edit('tests/fixtures/basic.asp')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  it('arranca el parser aspclassic para el filetype asp', function()
    local ok, parser = pcall(vim.treesitter.get_parser, 0)
    assert.is_true(ok)
    assert.are.equal('aspclassic', parser:lang())
  end)

  it('inyecta html y vbscript', function()
    local parser = vim.treesitter.get_parser(0)
    parser:parse(true)
    local langs = {}
    for lang in pairs(parser:children()) do
      langs[lang] = true
    end
    assert.is_true(langs.html, 'esperaba injection html')
    assert.is_true(langs.vbscript, 'esperaba injection vbscript')
  end)

  it('las queries de aspclassic compilan', function()
    assert.is_not_nil(vim.treesitter.query.get('aspclassic', 'highlights'))
    assert.is_not_nil(vim.treesitter.query.get('aspclassic', 'injections'))
  end)
end)

describe('queries de vbscript', function()
  it('las queries de vbscript compilan', function()
    assert.is_not_nil(vim.treesitter.query.get('vbscript', 'highlights'))
  end)
end)

describe('If de bloque en la inyección combinada', function()
  after_each(function()
    vim.cmd('bwipeout!')
  end)

  ---If de la capa vbscript del buffer, con sus filas y si es de bloque
  ---(termina con End If).
  local function ifs(lines)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'asp'
    local parser = vim.treesitter.get_parser(buf)
    parser:parse(true)
    local root = parser:children().vbscript:trees()[1]:root()
    assert.is_false(root:has_error())
    local out = {}
    local query = vim.treesitter.query.parse('vbscript', '(if_statement) @if')
    for _, node in query:iter_captures(root, buf) do
      local last = node:child(node:child_count() - 1)
      local sr, _, er = node:range()
      out[#out + 1] = { sr, er, last:type() == 'If' }
    end
    return out
  end

  it('un Then al final del bloque <% %> abre un If que abarca el HTML', function()
    assert.are.same({ { 0, 4, true } }, ifs({
      '<% If x Then %>',
      '<p>a</p>',
      '<% Else %>',
      '<p>b</p>',
      '<% End If %>',
    }))
  end)

  it('un If de una línea no se apropia del End If del siguiente', function()
    -- Antes del scanner externo, el primer If se parseaba de bloque y el
    -- segundo, de una línea con `y = 2`.
    assert.are.same({ { 0, 0, false }, { 2, 4, true } }, ifs({
      '<% If a Then b = 1 %>',
      '<p>z</p>',
      '<%If x Then%>',
      '<% y = 2 %>',
      '<% End If %>',
    }))
  end)
end)
