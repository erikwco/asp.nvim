local M = {}

-- Handlers por método. Cada handler recibe (params) y retorna el resultado
-- (o nil), o nil y un error LSP {code, message} para que el cliente lo
-- muestre. Su respuesta se entrega SIEMPRE de forma diferida
-- (vim.schedule, ver `request` abajo) — no agregues un handler que
-- necesite responder sincrónicamente.
M.handlers = {}

M.handlers['textDocument/documentSymbol'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local syms = require('asp.symbols').document_symbols(bufnr)
  -- Funciones y clases JS de los <script> (detail = 'javascript'), después
  -- de las de VBScript.
  vim.list_extend(syms, require('asp.js').document_symbols(bufnr) or {})
  return syms
end

-- definition y references encadenan capas con `or`, en orden fijo
-- (VBScript → JavaScript de cliente → páginas): cada capa devuelve nil cuando la
-- posición no es suya y nunca lanza.
M.handlers['textDocument/definition'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local pos = params.position
  return require('asp.symbols').definition(bufnr, pos)
    or require('asp.js').definition(bufnr, pos)
    or require('asp.pages').definition(bufnr, pos)
end

-- asp.symbols.references devuelve {} (no nil) cuando la posición no es
-- VBScript: se normaliza a nil para que el `or` pase a la capa siguiente.
local function nonempty(list)
  if list and #list > 0 then return list end
  return nil
end

-- Si ninguna capa resuelve, {} como antes de encadenarlas (no nil).
M.handlers['textDocument/references'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local pos = params.position
  return nonempty(require('asp.symbols').references(bufnr, pos))
    or require('asp.js').references(bufnr, pos)
    or require('asp.pages').references(bufnr, pos)
    or {}
end

M.handlers['textDocument/documentHighlight'] = function(params)
  local ok, result = pcall(function()
    local uri = params.textDocument.uri
    local bufnr = vim.uri_to_bufnr(uri)
    local pos = params.position
    local symbols, js = require('asp.symbols'), require('asp.js')
    local refs, binding = symbols.references(bufnr, pos, { buffer_only = true })
    local definition
    if #refs > 0 then
      if binding then
        local s = binding.selection
        definition = {
          uri = uri,
          range = {
            start = { line = s[1], character = s[2] },
            ['end'] = { line = s[3], character = s[4] },
          },
        }
      else
        definition = symbols.definition(bufnr, pos)
      end
    else
      refs, definition = js.references(bufnr, pos, { buffer_only = true })
      if not refs or #refs == 0 then return {} end
      definition = definition or js.definition(bufnr, pos)
      if not definition then return {} end
    end
    local kinds = vim.lsp.protocol.DocumentHighlightKind
    local highlights = {}
    for _, ref in ipairs(refs) do
      if ref.uri == uri then
        local kind = kinds.Text
        if definition then
          local declaration = definition.uri == uri and vim.deep_equal(definition.range, ref.range)
          kind = declaration and kinds.Write or kinds.Read
        end
        table.insert(highlights, { range = ref.range, kind = kind })
      end
    end
    return highlights
  end)
  return ok and result or {}
end

M.handlers['workspace/symbol'] = function(params)
  local client = vim.lsp.get_clients({ name = 'asp-ls' })[1]
  local root = client and client.config.root_dir or vim.fn.getcwd()
  return require('asp.symbols').workspace_symbols(params.query, root)
end

M.handlers['textDocument/hover'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.hover').hover(bufnr, params.position)
    or require('asp.js_help').hover(bufnr, params.position)
end

M.handlers['textDocument/completion'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  if require('asp.js').region_at(bufnr, params.position) then
    return require('asp.js_help').complete(bufnr, params.position) or {}
  end
  return require('asp.completion').complete(bufnr, params.position)
end

-- prepareRename y rename responden con un error (InvalidParams y el motivo)
-- cuando no se puede renombrar: ver asp.rename.
M.handlers['textDocument/prepareRename'] = function(params)
  local rename = require('asp.rename')
  local bufnr, err = rename.buffer_for(params.textDocument.uri)
  if not bufnr then return nil, err end
  return rename.prepare(bufnr, params.position)
end

M.handlers['textDocument/rename'] = function(params)
  local rename = require('asp.rename')
  local bufnr, err = rename.buffer_for(params.textDocument.uri)
  if not bufnr then return nil, err end
  return rename.rename(bufnr, params.position, params.newName)
end

M.handlers['textDocument/signatureHelp'] = function(params)
  local ok, result = pcall(function()
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    return require('asp.signature').help(bufnr, params.position)
      or require('asp.js_help').signature(bufnr, params.position)
  end)
  return ok and result or nil
end

-- Tokens semánticos (asp.semantic_tokens): nunca lanzan, y sin parser
-- responden { data = {} }.
M.handlers['textDocument/semanticTokens/full'] = function(params)
  return require('asp.semantic_tokens').full(vim.uri_to_bufnr(params.textDocument.uri))
end

M.handlers['textDocument/semanticTokens/range'] = function(params)
  return require('asp.semantic_tokens').range(vim.uri_to_bufnr(params.textDocument.uri), params.range)
end

---Capacidades del servidor. `setup({ semantic_tokens = false })` no
---anuncia los tokens semánticos.
---@return table
function M.capabilities()
  local caps = {
    documentSymbolProvider = true,
    definitionProvider = true,
    referencesProvider = true,
    documentHighlightProvider = true,
    workspaceSymbolProvider = true,
    hoverProvider = true,
    completionProvider = { triggerCharacters = { '.' } },
    signatureHelpProvider = {
      triggerCharacters = { '(', ',' }, retriggerCharacters = { ',' },
    },
    renameProvider = { prepareProvider = true },
    positionEncoding = 'utf-8',
  }
  if require('asp').options.semantic_tokens ~= false then
    -- El servidor lee el buffer y no usa didOpen ni didChange, pero Neovim
    -- pide los tokens a partir de ellos: 0.10 fija la versión del
    -- documento en el didOpen (sin él no los pide hasta la primera
    -- edición) y 0.12 los vuelve a pedir con cada didChange.
    caps.textDocumentSync = { openClose = true, change = 2 }
    caps.semanticTokensProvider = {
      legend = require('asp.semantic_tokens').legend, full = true, range = true,
    }
  end
  return caps
end

local function server(dispatchers)
  local closing = false
  local request_id = 0
  local function close()
    if closing then return end
    closing = true
    vim.schedule(function() dispatchers.on_exit(0, 0) end)
  end
  return {
    request = function(method, params, callback, notify_reply_callback)
      request_id = request_id + 1
      local id = request_id
      local function respond(err, result)
        if notify_reply_callback then notify_reply_callback(id) end
        callback(err, result, id)
      end
      if method == 'initialize' then
        respond(nil, {
          capabilities = M.capabilities(),
          serverInfo = { name = 'asp-ls', version = '0.7.0' },
        })
      elseif method == 'shutdown' then
        respond(nil, nil)
      elseif M.handlers[method] then
        local ok, result, err = pcall(M.handlers[method], params)
        -- Respuesta diferida (como un servidor LSP real, que contesta async
        -- por un pipe). Si se contesta sincrónicamente, la maquinaria de
        -- completion de Neovim llama vim.fn.complete() dentro de un contexto
        -- donde no se permite cambiar texto → E565. vim.schedule mueve el
        -- callback al siguiente tick del event loop, fuera de ese contexto.
        vim.schedule(function()
          if ok and err ~= nil then
            respond(err, nil)
          elseif ok then
            respond(nil, result)
          else
            respond({ code = -32603, message = tostring(result) }, nil)
          end
        end)
      else
        respond(nil, nil)
      end
      return true, id
    end,
    -- true: la notificación llegó (Neovim dispara LspNotify, que usan los
    -- tokens semánticos). Su contenido no se usa.
    notify = function(method, _params)
      if method == 'exit' then
        close()
      end
      return not closing
    end,
    is_closing = function()
      return closing
    end,
    terminate = close,
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
