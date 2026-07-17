local M = {}

-- Handlers por método; las Tasks 3-4 agregan entradas aquí.
-- Cada handler recibe (params) y retorna el resultado (o nil).
M.handlers = {}

M.handlers['textDocument/documentSymbol'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.symbols').document_symbols(bufnr)
end

M.handlers['textDocument/definition'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.symbols').definition(bufnr, params.position)
end

M.handlers['textDocument/references'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.symbols').references(bufnr, params.position)
end

M.handlers['workspace/symbol'] = function(params)
  local client = vim.lsp.get_clients({ name = 'asp-ls' })[1]
  local root = client and client.config.root_dir or vim.fn.getcwd()
  return require('asp.symbols').workspace_symbols(params.query, root)
end

M.handlers['textDocument/hover'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.hover').hover(bufnr, params.position)
end

M.handlers['textDocument/completion'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.completion').complete(bufnr, params.position)
end

local function server(dispatchers)
  local closing = false
  return {
    request = function(method, params, callback)
      if method == 'initialize' then
        callback(nil, {
          capabilities = {
            documentSymbolProvider = true,
            definitionProvider = true,
            referencesProvider = true,
            workspaceSymbolProvider = true,
            hoverProvider = true,
            completionProvider = { triggerCharacters = { '.' } },
            positionEncoding = 'utf-8',
          },
          serverInfo = { name = 'asp-ls', version = '0.3.0' },
        })
      elseif method == 'shutdown' then
        callback(nil, nil)
      elseif M.handlers[method] then
        local ok, result = pcall(M.handlers[method], params)
        if ok then
          callback(nil, result)
        else
          callback({ code = -32603, message = tostring(result) }, nil)
        end
      else
        callback(nil, nil)
      end
      return true, 1
    end,
    notify = function(method, _params)
      if method == 'exit' then
        closing = true
      end
      return false
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

---@param bufnr integer
function M.start(bufnr)
  -- root_dir unificado con la raíz de includes: virtual_root_for ya honra
  -- setup({virtual_root}) y prefiere el web.config más cercano sobre el
  -- .git más cercano (ver comentario en asp.includes.M.virtual_root_for).
  -- El fallback extra a `.git` a secas cubre proyectos sin web.config.
  local root_dir = require('asp.includes').virtual_root_for(vim.api.nvim_buf_get_name(bufnr))
    or vim.fs.root(bufnr, { '.git' })
    or vim.fn.getcwd()
  return vim.lsp.start({
    name = 'asp-ls',
    cmd = server,
    root_dir = root_dir,
  }, { bufnr = bufnr })
end

return M
