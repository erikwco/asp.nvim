-- Plegado con vim.treesitter.foldexpr() y las queries folds del repo.
-- La query folds de html (p. ej. la de nvim-treesitter) se anula para que
-- los niveles dependan sólo de aspclassic y vbscript.

local PAGE = {
  '<html>', --  1
  '<%', --  2
  'Sub Foo(a)', --  3
  '    If a Then x = 1', --  4
  '    If a Then', --  5
  '        y = 2', --  6
  '    End If', --  7
  'End Sub', --  8
  '%>', --  9
  '<% If z Then %>', -- 10
  '    <p>a</p>', -- 11
  '<% End If %>', -- 12
  '<p><%= x %></p>', -- 13
}

---Buffer asp con `lines`: el FileType arranca tree-sitter, el ftplugin
---fija foldexpr y el plugin parsea la capa vbscript.
local function page(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'asp'
  return buf
end

---Primera y última línea del pliegue más interno que empieza en `lnum`,
---o nil si ninguno empieza ahí.
local function fold_at(lnum)
  vim.cmd('normal! zR')
  vim.cmd(lnum .. 'foldclose')
  local first, last = vim.fn.foldclosed(lnum), vim.fn.foldclosedend(lnum)
  vim.cmd('normal! zR')
  if first ~= lnum then return nil end
  return { first, last }
end

describe('plegado', function()
  before_each(function()
    vim.treesitter.query.set('html', 'folds', '')
  end)

  after_each(function()
    require('asp').options.folds = nil
    vim.cmd('silent! %bwipeout!')
  end)

  it('el ftplugin fija foldexpr y no toca foldmethod ni foldlevel', function()
    vim.cmd('setglobal foldmethod=manual foldlevel=0')
    page(PAGE)
    assert.are.equal('v:lua.vim.treesitter.foldexpr()', vim.wo.foldexpr)
    assert.are.equal('manual', vim.wo.foldmethod)
    assert.are.equal(0, vim.wo.foldlevel)
  end)

  describe('con foldmethod=expr', function()
    before_each(function()
      page(PAGE)
      vim.wo.foldmethod = 'expr'
      vim.cmd('normal! zx')
    end)

    it('un Sub pliega de su Sub a su End Sub', function()
      assert.are.same({ 3, 8 }, fold_at(3))
    end)

    it('un If de bloque pliega hasta su End If y uno de una línea no pliega', function()
      assert.are.same({ 5, 7 }, fold_at(5))
      assert.is_nil(fold_at(4))
      assert.is_nil(vim.treesitter.foldexpr(4):find('>', 1, true))
    end)

    it('un bloque <% %> multilínea pliega entero', function()
      assert.are.same({ 2, 9 }, fold_at(2))
    end)

    it('un If que cruza bloques <% %> pliega el HTML de en medio', function()
      assert.are.same({ 10, 12 }, fold_at(10))
      assert.are.equal(1, vim.fn.foldlevel(11))
    end)

    it('un <%= %> no pliega', function()
      assert.are.equal(0, vim.fn.foldlevel(13))
      assert.are.equal(0, vim.fn.foldlevel(1))
    end)
  end)

  it('setup({ folds = false }) no toca foldexpr', function()
    require('asp').setup({ folds = false })
    vim.cmd('setglobal foldexpr=0')
    vim.cmd('setlocal foldexpr=0')
    page(PAGE)
    assert.are.equal('0', vim.wo.foldexpr)
  end)

  it('las queries folds compilan', function()
    assert.is_not_nil(vim.treesitter.query.get('vbscript', 'folds'))
    assert.is_not_nil(vim.treesitter.query.get('aspclassic', 'folds'))
  end)
end)
