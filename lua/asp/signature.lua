local M = {}

local intrinsics = require('asp.intrinsics')
local symbols = require('asp.symbols')
local com = require('asp.com')
local signature_info = require('asp.signature_info')

-- SignatureInformation de una firma nativa, intrínseca, COM o del usuario.
local function information(info)
  local params = info.params or signature_info.parameters(info.signature)
  local parameters = {}
  -- Offsets [inicio, fin) en bytes del label, como el positionEncoding
  -- utf-8 del servidor. Con el nombre suelto, el cliente resalta su primera
  -- aparición tras el paréntesis, como la `a` de `ByVal` en `(ByVal a)`.
  local from = (info.signature:find('(', 1, true) or 0) + 1
  for _, param in ipairs(params) do
    local name = vim.pesc(param.name)
    local s, e = info.signature:find('%f[%w_]' .. name .. '%f[^%w_]', from)
    local label = param.name
    if s then label, from = { s - 1, e }, e + 1 end
    parameters[#parameters + 1] = { label = label, documentation = param.doc }
  end
  local doc = info.doc or ''
  if info.returns then doc = doc .. '\n\nRetorno: ' .. info.returns .. '.' end
  if info.file then doc = doc .. '\n\nArchivo: `' .. vim.fn.fnamemodify(info.file, ':t') .. '`.' end
  return { label = info.signature, parameters = parameters,
    documentation = { kind = 'markdown', value = doc } }
end

local function callable(info)
  return info and info.signature and info.signature:find('(', 1, true) and info or nil
end

function M.help(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local context = require('asp.call_context')
  local call = context.active(context.line(bufnr, position))
  if not call then return nil end
  local object, member = call.name:match('^([%w_]+)%.([%w_]+)$')
  local info, shadowed
  if object then
    info = intrinsics.member(object, member)
    if not info then
      local obj = require('asp.types').infer(bufnr, position, object)
      info = obj and com.member(obj.id, member)
    end
  else
    -- Una Sub o Function del usuario homónima sombrea a la nativa: va
    -- primero y la nativa queda como segunda firma.
    local native = require('asp.vbscript_builtins').lookup(call.name)
    native = native and native.group == 'functions' and native or nil
    info = callable(symbols.named(bufnr, position, call.name))
    if info then shadowed = native else info = native end
  end
  info = callable(info)
  if not info then return nil end
  local active = call.parameter
  -- Los argumentos de más de una variádica (`Array(1, 2, 3, `) caen en su
  -- último parámetro; en las demás se dejan fuera de rango.
  local count = #(info.params or signature_info.parameters(info.signature))
  if info.variadic and count > 0 and active >= count then active = count - 1 end
  local signatures = { information(info) }
  if shadowed then signatures[2] = information(shadowed) end
  return { signatures = signatures, activeSignature = 0, activeParameter = active }
end

return M
