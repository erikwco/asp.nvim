local M = {}
local js = require('asp.js')
local dom = require('asp.dom')
local context = require('asp.js_context')
local info = require('asp.js_info')

local keywords = {
  'function', 'return', 'const', 'let', 'var', 'if', 'else', 'for', 'while',
  'do', 'switch', 'case', 'default', 'break', 'continue', 'try', 'catch',
  'finally', 'throw', 'new', 'this', 'true', 'false', 'null', 'undefined',
  'typeof', 'instanceof', 'delete', 'void', 'in', 'of', 'class', 'extends',
  'super', 'static', 'import', 'export', 'yield', 'async', 'await',
  'debugger', 'with',
}

-- Parámetro implícito de los atributos on*: el navegador envuelve su valor
-- en `function (event) { ... }`.
local EVENT = {
  name = 'event', kind = 6, detail = 'event',
  doc = 'Evento que disparó el manejador: el parámetro implícito de los atributos on*.',
}

-- Constructores cuyas instancias tienen miembros en el catálogo.
local INSTANCES = { XMLHttpRequest = 'XMLHttpRequest.prototype' }

---Ruta del catálogo para `path`, o nil si un binding del usuario la
---sombrea. Un binding declarado como `var x = new XMLHttpRequest()` toma
---los miembros de su prototipo; solo se mira esa primera línea de la
---declaración, sin seguir asignaciones posteriores. `object` indica que
---`path` es el objeto cuyos miembros se piden, no un miembro.
local function catalog_path(bufnr, position, path, object)
  local root, rest = path:match('^([^.]+)(.*)$')
  local binding = js.named(bufnr, position, root)
  if not binding then return path end
  if rest == '' and not object then return nil end
  local class = (binding.detail or ''):match('^[^=]*=%s*new%s+([%w_$]+)%f[^%w_$]')
  return INSTANCES[class] and INSTANCES[class] .. rest or nil
end

local function catalog(bufnr, position, path)
  path = catalog_path(bufnr, position, path)
  return path and dom.lookup(path) or nil
end

---¿La región es el valor de un atributo on*? Las demás son <script> o
---URLs `javascript:`, precedidas por `>` o por el prefijo.
local function in_handler(ctx)
  local before = ctx.source:sub(math.max(1, ctx.range[3] - 64), ctx.range[3]):lower()
  return before:match('%f[%w]on%a+%s*=%s*["\']?$') ~= nil
end

local function hover(bufnr, position)
  local ctx = js.region_at(bufnr, position)
  local node = ctx and ctx.node
  if not node then return nil end
  local kind = node:type()
  if kind ~= 'identifier' and kind ~= 'property_identifier'
    and kind ~= 'shorthand_property_identifier' and kind ~= 'shorthand_property_identifier_pattern' then
    return nil
  end
  local entry = js.named(bufnr, position)
  if not entry then
    local target = node
    if kind == 'property_identifier' then
      local parent = node:parent()
      if not parent or parent:type() ~= 'member_expression' then return nil end
      target = parent
    end
    local path = context.path(vim.treesitter.get_node_text(target, ctx.source))
    entry = path and catalog(bufnr, position, path)
  end
  if entry then return { contents = { kind = 'markdown', value = info.markdown(entry) } } end
end

local function complete(bufnr, position)
  local ctx = js.region_at(bufnr, position)
  if not ctx then return nil end
  local mask = context.mask(ctx)
  if not mask then return {} end
  local prefix = mask:match('([%w_$\128-\255]*)$') or ''
  local before = mask:sub(1, #mask - #prefix)
  local out, seen = {}, {}
  local function add(entry)
    if seen[entry.name] then return end
    seen[entry.name] = true
    if entry.name:sub(1, #prefix) ~= prefix then return end
    out[#out + 1] = {
      label = entry.name, kind = entry.kind, detail = entry.detail,
      documentation = { kind = 'markdown', value = info.markdown(entry) },
      sortText = ('%05d'):format(#out + 1),
    }
  end
  if before:match('%.%s*$') then
    local path = context.path((before:gsub('%.%s*$', '')))
    path = path and catalog_path(bufnr, position, path, true)
    if not path then return {} end
    for _, entry in ipairs(dom.members(path) or {}) do add(entry) end
    return out
  end
  for _, entry in ipairs(js.visible(bufnr, position) or {}) do add(entry) end
  if in_handler(ctx) then add(EVENT) end
  for _, entry in ipairs(dom.globals) do add(entry) end
  if #prefix >= 2 then
    for _, word in ipairs(keywords) do add({ name = word, kind = 14, detail = word }) end
  end
  return out
end

local function signature(bufnr, position)
  local ctx = js.region_at(bufnr, position)
  if not ctx then return nil end
  local call = context.active(context.mask(ctx))
  if not call then return nil end
  -- Resuelve en el scope donde se abre la llamada, no en el de un
  -- callback que el cursor pueda estar escribiendo entre sus argumentos.
  local before = ctx.source:sub(ctx.range[3] + 1, ctx.range[3] + call.offset - 1)
  local _, rows = before:gsub('\n', '')
  position = { line = ctx.range[1] + rows,
    character = rows == 0 and ctx.range[2] + #before or #before - before:match('.*()\n') }
  local entry
  if not call.name:find('.', 1, true) then entry = js.named(bufnr, position, call.name) end
  entry = entry or catalog(bufnr, position, call.name)
  if not entry or not entry.signature then return nil end
  -- Los argumentos de más caen en un rest final (`...args`). Fuera de la
  -- lista, Neovim 0.12 no resalta ninguno y la spec LSP elige el primero.
  local active, last = call.parameter, entry.parameters[#entry.parameters]
  if last and active >= #entry.parameters
    and entry.signature:sub(last.label[1] + 1, last.label[2]):match('^%.%.%.') then
    active = #entry.parameters - 1
  end
  return {
    signatures = { { label = entry.signature, parameters = entry.parameters,
      documentation = { kind = 'markdown', value = info.markdown(entry) } } },
    activeSignature = 0, activeParameter = active,
  }
end

local function safe(fn, bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local ok, result = pcall(fn, bufnr, position)
  return ok and result or nil
end

function M.hover(bufnr, position) return safe(hover, bufnr, position) end
function M.complete(bufnr, position) return safe(complete, bufnr, position) end
function M.signature(bufnr, position) return safe(signature, bufnr, position) end

return M
