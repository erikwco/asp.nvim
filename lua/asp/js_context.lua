local M = {}

-- Conserva los bytes para reconocer llamadas incompletas. El árbol ya
-- cacheado distingue regex de división y templates anidados; el escaneo
-- de comillas cubre strings sin cerrar que tree-sitter recupera como ERROR.
function M.mask(ctx)
  local source, cursor = ctx.source, ctx.byte
  local parts, i = {}, ctx.range[3]
  while i < cursor do
    local opaque = ctx.opaque[i]
    local char, pair = source:sub(i + 1, i + 1), source:sub(i + 1, i + 2)
    if opaque then
      if opaque.stop > cursor then return nil end
      if opaque.kind == 'comment' and opaque.stop == cursor then
        if pair == '//' or source:sub(cursor - 1, cursor) ~= '*/' then return nil end
      end
      parts[#parts + 1] = string.rep(' ', opaque.stop - i)
      i = opaque.stop
    elseif char == '"' or char == "'" or char == '`' then
      local start, quote = i, char
      i = i + 1
      local closed = false
      while i < cursor do
        char = source:sub(i + 1, i + 1)
        if char == '\\' then
          i = i + 2
        elseif char == quote then
          i, closed = i + 1, true
          break
        else
          i = i + 1
        end
      end
      if not closed then return nil end
      parts[#parts + 1] = string.rep(' ', i - start)
    elseif pair == '//' or pair == '/*' then
      local stop = pair == '//' and source:find('\n', i + 3, true) or source:find('*/', i + 3, true)
      if not stop then return nil end
      stop = pair == '//' and stop - 1 or stop + 1
      if stop >= cursor then return nil end
      parts[#parts + 1], i = string.rep(' ', stop - i), stop
    else
      parts[#parts + 1], i = char, i + 1
    end
  end
  return table.concat(parts)
end

-- Sólo rutas de identificadores, sin inferir objetos ni llamadas encadenadas.
function M.path(text)
  local start, _, name = text:find('([%a_$\128-\255][%w_$\128-\255]*)%s*$')
  if not start then return nil end
  local before = text:sub(1, start - 1)
  while before:match('%.%s*$') do
    before = before:gsub('%.%s*$', '')
    local s, _, object = before:find('([%a_$\128-\255][%w_$\128-\255]*)%s*$')
    if not s then return nil end
    name, before = object .. '.' .. name, before:sub(1, s - 1)
  end
  if before:match('[%w_$\128-\255]$') then return nil end
  return name
end

function M.active(mask)
  if not mask then return nil end
  local stack = {}
  for i = 1, #mask do
    local char = mask:sub(i, i)
    if char == '(' or char == '[' or char == '{' then
      stack[#stack + 1] = { open = char, offset = i, parameter = 0 }
    elseif char == ')' or char == ']' or char == '}' then
      local expected = ({ [')'] = '(', [']'] = '[', ['}'] = '{' })[char]
      if stack[#stack] and stack[#stack].open == expected then stack[#stack] = nil end
    elseif char == ',' and stack[#stack] then
      stack[#stack].parameter = stack[#stack].parameter + 1
    end
  end
  for i = #stack, 1, -1 do
    local frame = stack[i]
    if frame.open == '(' then
      local before = mask:sub(1, frame.offset - 1)
      -- Sólo se busca el nombre de los paréntesis que siguen abiertos.
      -- Hacerlo para cada llamada cerrada vuelve cuadrática la consulta.
      -- La keyword entera: `functionName(` y `myfunction(` son llamadas.
      if before:match('%f[%w_$\128-\255]function%f[^%w_$\128-\255]%s*%*?%s*[%w_$\128-\255]*%s*$') then
        return nil
      end
      frame.name = M.path(before)
      if frame.name then return frame end
    end
  end
end

return M
