local M = {}

-- Handlers por método; las Tasks 3-4 agregan entradas aquí.
-- Cada handler recibe (params) y retorna el resultado (o nil).
M.handlers = {}

local function server(dispatchers)
  local closing = false
  return {
    request = function(method, params, callback)
      if method == 'initialize' then
        callback(nil, {
          capabilities = {
            documentSymbolProvider = true,
            definitionProvider = true,
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
  return vim.lsp.start({
    name = 'asp-ls',
    cmd = server,
    root_dir = vim.fs.root(bufnr, { '.git', 'web.config' }) or vim.fn.getcwd(),
  }, { bufnr = bufnr })
end

return M
