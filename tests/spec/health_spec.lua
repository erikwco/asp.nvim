describe('modulo asp', function()
  it('setup() no explota sin opciones', function()
    assert.is_true((pcall(require('asp').setup)))
  end)

  it('health.check existe', function()
    assert.is_function(require('asp.health').check)
  end)

  it('el modulo lsp expone start y handlers', function()
    local lsp = require('asp.lsp')
    assert.is_function(lsp.start)
    assert.is_function(lsp.handlers['textDocument/documentSymbol'])
    assert.is_function(lsp.handlers['textDocument/definition'])
  end)

  it('los módulos de hover y completion existen', function()
    assert.is_function(require('asp.hover').hover)
    assert.is_function(require('asp.completion').complete)
    assert.is_function(require('asp.intrinsics').object)
  end)
end)

describe('asp.health.check', function()
  local original_health, original_add, messages
  local parsers = {
    aspclassic = 'error', vbscript = 'error', html = 'error',
    javascript = 'warn', css = 'warn',
  }

  before_each(function()
    original_health, messages = {}, {}
    original_add = vim.treesitter.language.add
    for _, level in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
      original_health[level] = vim.health[level]
      messages[level] = {}
      vim.health[level] = function(message, advice)
        messages[level][message] = advice or {}
      end
    end
  end)

  after_each(function()
    for level, original in pairs(original_health) do vim.health[level] = original end
    vim.treesitter.language.add = original_add
  end)

  it('informa ok para los cuatro parsers compilados de la suite', function()
    require('asp.health').check()
    for _, message in ipairs({
      'parser aspclassic encontrado',
      'parser vbscript encontrado',
      'parser vbscript con su scanner externo: distingue el If de bloque del de una línea',
      'parser html encontrado (regiones HTML; ubica los <script> y atributos on* de la capa JavaScript)',
      'parser javascript encontrado (resaltado, navegación, rename y ayuda en <script>, on*, <script src> e includes)',
    }) do
      assert.is_not_nil(messages.ok[message], message)
    end
    assert.are.same({}, messages.error)
    assert.is_nil(messages.warn['parser javascript no encontrado'])
  end)

  it('detecta un parser vbscript sin el scanner externo', function()
    local get_string_parser = vim.treesitter.get_string_parser
    -- Lo que da un parser sin scanner: el segundo If queda adentro del primero.
    vim.treesitter.get_string_parser = function(source, lang, ...)
      if lang == 'vbscript' and source:find('If a Then b = 1', 1, true) then
        source = 'If a Then\nIf c Then\n  d = 2\nEnd If\nEnd If\n'
      end
      return get_string_parser(source, lang, ...)
    end
    local ok, err = pcall(require('asp.health').check)
    vim.treesitter.get_string_parser = get_string_parser
    assert(ok, err)
    local message = 'el parser vbscript no distingue el If de bloque del de una línea: '
      .. 'le falta el scanner externo o es de otra gramática'
    assert.is_truthy(table.concat(messages.error[message], '\n'):find('make parsers', 1, true))
    assert.is_nil(messages.ok['parser vbscript con su scanner externo: distingue el If de bloque del de una línea'])
  end)

  it('avisa si hay varias copias del parser y si sus queries no compilan', function()
    local runtime_file, query_get = vim.api.nvim_get_runtime_file, vim.treesitter.query.get
    vim.api.nvim_get_runtime_file = function(pattern, all)
      if pattern == 'parser/vbscript.*' then return { '/otro/parser/vbscript.so', '/asp/parser/vbscript.so' } end
      return runtime_file(pattern, all)
    end
    vim.treesitter.query.get = function(lang, name)
      if lang == 'vbscript' and name == 'folds' then error('Invalid node type "block"', 0) end
      return query_get(lang, name)
    end
    local ok, err = pcall(require('asp.health').check)
    vim.api.nvim_get_runtime_file, vim.treesitter.query.get = runtime_file, query_get
    assert(ok, err)
    assert.is_not_nil(messages.warn['hay 2 parsers vbscript en runtimepath; Neovim carga el primero: /otro/parser/vbscript.so'])
    assert.is_not_nil(messages.error['las queries de vbscript no compilan con el parser cargado: folds: Invalid node type "block"'])
    assert.is_nil(next(vim.tbl_filter(function(m) return m:find('aspclassic', 1, true) end, vim.tbl_keys(messages.error))))
  end)

  it('informa los métodos de asp-ls y la severidad de cada familia de diagnósticos', function()
    local previous = require('asp').options.diagnostics
    require('asp').setup({ diagnostics = { syntax = false, undeclared = 'ERROR' } })
    require('asp.health').check_server()
    local info = next(messages.info) or next(messages.ok)
    for _, method in ipairs({ 'completion', 'definition', 'documentHighlight', 'hover', 'prepareRename',
      'references', 'rename', 'signatureHelp', 'workspace/symbol' }) do
      assert.is_truthy(info:find(method, 1, true), method)
    end
    assert.is_not_nil(messages.ok['diagnósticos (namespace asp_includes): includes WARN, missing_page WARN, '
      .. 'undeclared ERROR, unknown_call WARN'])
    require('asp').options.diagnostics = false
    require('asp.health').check_server()
    assert.is_not_nil(messages.info['diagnósticos apagados (setup({ diagnostics = false }))'])
    require('asp').options.diagnostics = previous
  end)

  it('recomienda instalar los parsers ausentes', function()
    vim.treesitter.language.add = function()
      return original_add('asp_parser_inexistente')
    end
    require('asp.health').check()
    for lang, level in pairs(parsers) do
      local message = ('parser %s no encontrado'):format(lang)
      local advice = messages[level][message]
      assert.is_not_nil(advice, message)
      local command = (lang == 'aspclassic' or lang == 'vbscript')
        and 'make parsers' or ':TSInstall ' .. lang
      assert.is_truthy(table.concat(advice, '\n'):find(command, 1, true), message)
    end
  end)

  it('muestra el error de carga de un parser instalado sin pedir instalarlo', function()
    vim.treesitter.language.add = function(lang)
      error('Failed to load parser ' .. lang .. ': uv_dlopen: invalid file', 0)
    end
    require('asp.health').check()
    for lang, level in pairs(parsers) do
      local message = ('parser %s instalado pero no carga: Failed to load parser %s: uv_dlopen: invalid file')
        :format(lang, lang)
      assert.are.same({}, messages[level][message], message)
      assert.is_nil(messages[level]['parser ' .. lang .. ' no encontrado'])
    end
  end)

  it('muestra el error de ABI y las alternativas compatibles con Neovim 0.10', function()
    vim.treesitter.language.add = function(lang)
      error('ABI version mismatch for ' .. lang .. '.so: supported between 13 and 14, found 15', 0)
    end
    require('asp.health').check()
    for lang, level in pairs(parsers) do
      local message = ('parser %s instalado pero no carga: ABI version mismatch for %s.so: supported between 13 and 14, found 15')
        :format(lang, lang)
      assert.are.same({
        'Neovim 0.10 solo carga ABI 13–14: instalalo con nvim-treesitter rama `master`, '
          .. 'o compilá con `tree-sitter generate --abi 14`; o pasá a Neovim 0.11+',
      }, messages[level][message], message)
      assert.is_nil(messages[level]['parser ' .. lang .. ' no encontrado'])
    end
  end)
end)

describe('asp.health: plegado e indentación', function()
  local original_health, messages

  before_each(function()
    original_health, messages = {}, {}
    for _, level in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
      original_health[level] = vim.health[level]
      messages[level] = {}
      vim.health[level] = function(message, advice)
        messages[level][message] = advice or {}
      end
    end
  end)

  after_each(function()
    for level, original in pairs(original_health) do vim.health[level] = original end
    require('asp').options.indent = nil
    require('asp').options.folds = nil
    vim.cmd('silent! %bwipeout!')
  end)

  local function page()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '/pagina.asp')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '<% x = 1 %>' })
    vim.bo[buf].filetype = 'asp'
    return buf
  end

  it('informa HtmlIndent y el foldexpr e indentexpr activos del buffer asp', function()
    page()
    vim.wo.foldmethod = 'expr'
    require('asp.health').check_layout()
    assert.is_not_nil(messages.ok['HtmlIndent() disponible (indent/html.vim): indenta las líneas HTML'])
    assert.is_not_nil(messages.ok['plegado por tree-sitter activo en pagina.asp'])
    assert.is_not_nil(messages.ok['indentexpr de asp.nvim activo en pagina.asp'])
  end)

  it('desde la ventana de :checkhealth informa el buffer asp anterior', function()
    page()
    vim.cmd('tabnew')
    require('asp.health').check_layout()
    assert.is_not_nil(messages.ok['indentexpr de asp.nvim activo en pagina.asp'])
    vim.cmd('tabclose')
  end)

  it('sugiere foldmethod=expr cuando foldexpr está fijado pero no se pliega', function()
    page()
    vim.wo.foldmethod = 'manual'
    require('asp.health').check_layout()
    local advice = messages.info['foldexpr de tree-sitter fijado en pagina.asp, pero foldmethod=manual']
    assert.is_truthy(table.concat(advice, '\n'):find('setlocal foldmethod=expr', 1, true))
  end)

  it('avisa cuando setup apagó la indentación', function()
    require('asp').setup({ indent = false })
    page()
    require('asp.health').check_layout()
    assert.is_nil(messages.ok['indentexpr de asp.nvim activo en pagina.asp'])
    assert.is_not_nil(messages.info['indentexpr de pagina.asp no es el de asp.nvim: '])
  end)

  it('sin buffer asp pide abrir uno', function()
    vim.cmd('enew')
    require('asp.health').check_layout()
    assert.is_not_nil(messages.info['abrí un .asp para ver si el plegado y la indentación están activos'])
  end)
end)
