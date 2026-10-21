local FIX = vim.fn.getcwd() .. '/tests/fixtures/formato'

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---El esperado está con shiftwidth=4 y espacios. Lo lleva a otro
---shiftwidth, y a tabs si `tabstop` no es nil.
local function convert(text, sw, tabstop)
  return vim.tbl_map(function(line)
    local spaces = #line:match('^ *')
    local width = spaces / 4 * sw
    local indent = tabstop and ('\t'):rep(math.floor(width / tabstop)) .. (' '):rep(width % tabstop)
      or (' '):rep(width)
    return indent .. line:sub(spaces + 1)
  end, text)
end

---Buffer asp con `text`, como si se hubiera abierto.
local function page(text)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].filetype = 'asp'
  vim.bo[buf].shiftwidth = 4
  vim.bo[buf].expandtab = true
  return buf
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end

describe('indentación', function()
  after_each(function()
    require('asp').options.indent = nil
    vim.cmd('silent! %bwipeout!')
  end)

  describe('gg=G sobre el fixture desordenado', function()
    local expected = vim.fn.readfile(FIX .. '/esperado.asp')

    local function reindent(sw, et)
      vim.cmd.edit(FIX .. '/desordenado.asp')
      vim.bo.shiftwidth = sw
      vim.bo.expandtab = et
      vim.bo.tabstop = 8
      vim.cmd('silent normal! gg=G')
      return lines()
    end

    it('deja exactamente el esperado (shiftwidth=4, expandtab)', function()
      assert.are.same(expected, reindent(4, true))
    end)

    it('respeta shiftwidth=2', function()
      assert.are.same(convert(expected, 2), reindent(2, true))
    end)

    it('con noexpandtab indenta con tabs', function()
      assert.are.same(convert(expected, 4, 8), reindent(4, false))
    end)

    it('es estable: otra pasada no cambia nada', function()
      local once = reindent(4, true)
      vim.cmd('silent normal! gg=G')
      assert.are.same(once, lines())
    end)
  end)

  it('conserva el contenido de pre, incluso entre bloques ASP', function()
    local expected = {
      '<% If x Then %>',
      '    <pre>',
      '  primera',
      '        segunda',
      '    <%',
      '    x = 1',
      '    %>',
      '   tercera',
      '    </pre>',
      '<% End If %>',
    }
    page(expected)
    vim.cmd('silent normal! gg=G')
    assert.are.same(expected, lines())
    vim.cmd('silent normal! gg=G')
    assert.are.same(expected, lines())
  end)

  describe('mientras se escribe', function()
    local SUB = { '<%', 'Sub Foo()', '    If x Then', '        y = 1', 'End Sub', '%>' }

    it('o tras una línea del If sigue en el cuerpo del If', function()
      page(SUB)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      feed('oz = 2<Esc>')
      assert.are.equal('        z = 2', lines()[4])
    end)

    it('escribir End If lo desindenta (indentkeys)', function()
      page(SUB)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      feed('oEnd If<Esc>')
      assert.are.equal('    End If', lines()[5])
    end)

    it('escribir Else, Next o Loop en minúsculas también desindenta', function()
      page({ '<%', 'For i = 1 To 3', '    If x Then', '        y = 1' })
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      feed('oelse<CR>z = 2<CR>end if<CR>next<Esc>')
      assert.are.same({ '    else', '        z = 2', '    end if', 'next' }, vim.list_slice(lines(), 5, 8))
    end)

    it('cerrar una etiqueta HTML la alinea con su apertura', function()
      page({ '<div>', '    <ul>', '        <li>a</li>' })
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      feed('o</ul><CR></div><Esc>')
      assert.are.same({ '    </ul>', '</div>' }, vim.list_slice(lines(), 4, 5))
    end)

    it('una línea dentro de un ERROR no lanza y conserva la indentación anterior', function()
      page({ '<%', 'Sub Foo()', '    If x Then', '        y = 1', '            z = 2', 'End Sub', '%>' })
      -- Sin End If, la capa vbscript tiene un ERROR que abarca la línea 5.
      local parser = vim.treesitter.get_parser(0)
      parser:parse(true)
      local root = parser:children().vbscript:trees()[1]:root()
      local node = root:named_descendant_for_range(4, 12, 4, 13)
      local in_error = false
      while node do
        if node:type() == 'ERROR' then in_error = true end
        node = node:parent()
      end
      assert.is_true(in_error)

      assert.is_true(pcall(vim.cmd, 'silent 5normal! =='))
      assert.are.equal('        z = 2', lines()[5])
    end)

    it('tras un If incompleto, el respaldo por texto abre un nivel', function()
      page({ '<%', 'Sub Foo()', '    If x Then', 'y = 1', 'End Sub', '%>' })
      vim.cmd('silent 4normal! ==')
      assert.are.equal('        y = 1', lines()[4])
    end)
  end)

  describe('ftplugin', function()
    it('fija indentexpr e indentkeys sin distinguir mayúsculas', function()
      page({ '<% x = 1 %>' })
      assert.are.equal("v:lua.require'asp.indent'.indentexpr()", vim.bo.indentexpr)
      for _, key in ipairs({ '0=~end', '0=~else', '0=~elseif', '0=~case', '0=~next', '0=~loop', '0=~wend', '0=%>', '<>>' }) do
        assert.is_truthy(vim.tbl_contains(vim.split(vim.bo.indentkeys, ','), key), key)
      end
    end)

    it('setup({ indent = false }) no toca indentexpr ni indentkeys', function()
      require('asp').setup({ indent = false })
      page({ '<% x = 1 %>' })
      assert.are.equal('', vim.bo.indentexpr)
      assert.are.equal(vim.api.nvim_get_option_info2('indentkeys', {}).default, vim.bo.indentkeys)
    end)

    it('undo_ftplugin deshace lo que fija el ftplugin', function()
      page({ '<% x = 1 %>' })
      vim.bo.filetype = 'text'
      assert.are.equal('', vim.bo.indentexpr)
      assert.are.equal('', vim.bo.includeexpr)
      assert.are.equal('0', vim.wo.foldexpr)
      assert.is_nil(vim.b.did_asp_ftplugin)
      vim.bo.filetype = 'asp'
      assert.are.equal("v:lua.require'asp.indent'.indentexpr()", vim.bo.indentexpr)
    end)
  end)

  it('HtmlIndent está disponible en 0.10 y 0.12', function()
    assert.is_true(require('asp.indent').html_available())
    assert.are.equal(1, vim.fn.exists('*HtmlIndent'))
  end)
end)
