describe('asp.ts.add', function()
  local original_add, original_has

  before_each(function()
    original_add = vim.treesitter.language.add
    original_has = vim.fn.has
  end)

  after_each(function()
    vim.treesitter.language.add = original_add
    vim.fn.has = original_has
  end)

  local function version(modern)
    vim.fn.has = function(feature)
      if feature == 'nvim-0.11' then return modern and 1 or 0 end
      return original_has(feature)
    end
  end

  it('acepta la carga sin retorno de Neovim 0.10', function()
    version(false)
    vim.treesitter.language.add = function(lang)
      assert.are.equal('vbscript', lang)
    end
    assert.is_true(require('asp.ts').add('vbscript'))
  end)

  it('acepta true en Neovim 0.11+', function()
    version(true)
    vim.treesitter.language.add = function() return true end
    assert.is_true(require('asp.ts').add('javascript'))
  end)

  it('rechaza nil con mensaje en Neovim 0.11+', function()
    version(true)
    vim.treesitter.language.add = function() return nil, 'parser ausente' end
    assert.is_false(require('asp.ts').add('ausente'))
  end)

  for _, modern in ipairs({ false, true }) do
    it('captura excepciones en Neovim ' .. (modern and '0.11+' or '0.10'), function()
      version(modern)
      vim.treesitter.language.add = function() error('parser inválido o ausente') end
      assert.is_false(require('asp.ts').add('ausente'))
    end)
  end

  it('rechaza un parser que no existe en el runtime real', function()
    assert.is_false(require('asp.ts').add('asp_parser_inexistente'))
  end)
end)
