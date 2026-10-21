local M = {}

local intrinsics = require('asp.intrinsics')
local symbols = require('asp.symbols')
local com = require('asp.com')
local signature_info = require('asp.signature_info')

function M.help(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local context = require('asp.call_context')
  local call = context.active(context.line(bufnr, position))
  if not call then return nil end
  local object, member = call.name:match('^([%w_]+)%.([%w_]+)$')
  local info
  if object then
    info = intrinsics.member(object, member)
    if not info then
      local obj = require('asp.types').infer(bufnr, position, object)
      info = obj and com.member(obj.id, member)
    end
  else
    info = require('asp.vbscript_builtins').lookup(call.name)
    if not info or info.group ~= 'functions' then
      info = symbols.named(bufnr, position, call.name)
    end
  end
  if not info or not info.signature or not info.signature:find('(', 1, true) then return nil end
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
  return {
    signatures = { { label = info.signature, parameters = parameters,
      documentation = { kind = 'markdown', value = doc } } },
    activeSignature = 0, activeParameter = call.parameter,
  }
end

return M
