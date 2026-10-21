local M = {}

-- Conserva los bytes para reconocer llamadas incompletas. El árbol ya
-- cacheado distingue regex de división; el escaneo de comillas cubre
-- strings sin cerrar que tree-sitter recupera como ERROR. De un template
-- se enmascara el texto y cada `${...}` se recorre como código, también
-- en un template sin cerrar.
function M.mask(ctx)
  local source, cursor, opaque_at = ctx.source, ctx.byte, ctx.opaque()
  local parts = {}
  local function blank(n) parts[#parts + 1] = string.rep(' ', n) end
  -- `code` devuelve CURSOR al llegar al cursor; nil si quedó en un string
  -- o un comentario.
  local CURSOR = {}
  local code

  -- Template desde su backtick en `i`. Devuelve el byte siguiente a su
  -- cierre, CURSOR si el cursor quedó en una sustitución o nil si quedó en
  -- el texto.
  local function template(i)
    blank(1)
    i = i + 1
    while i < cursor do
      local char = source:sub(i + 1, i + 1)
      if char == '`' then
        blank(1)
        return i + 1
      elseif char == '$' and source:sub(i + 2, i + 2) == '{' and i + 2 <= cursor then
        blank(2)
        local after = code(i + 2, true)
        if after == nil or after == CURSOR then return after end
        i = after
      else
        local step = char == '\\' and 2 or 1
        blank(math.min(step, cursor - i))
        i = i + step
      end
    end
    return nil
  end

  -- Código desde `i`. En una sustitución (`closing`) termina en la `}`
  -- que la cierra y devuelve el byte siguiente.
  code = function(i, closing)
    local depth = 0
    while i < cursor do
      local opaque = opaque_at[i]
      local char, pair = source:sub(i + 1, i + 1), source:sub(i + 1, i + 2)
      if opaque and opaque.kind ~= 'template_string' then
        if opaque.stop > cursor then return nil end
        if opaque.kind == 'comment' and opaque.stop == cursor then
          if pair == '//' or source:sub(cursor - 1, cursor) ~= '*/' then return nil end
        end
        blank(opaque.stop - i)
        i = opaque.stop
      elseif char == '`' then
        local after = template(i)
        if after == nil or after == CURSOR then return after end
        i = after
      elseif char == '"' or char == "'" then
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
          elseif char == '\n' then
            -- Un string simple no cruza líneas: sin cerrar, termina en la
            -- suya y no se traga el resto del script.
            closed = true
            break
          else
            i = i + 1
          end
        end
        if not closed then return nil end
        blank(i - start)
      elseif pair == '//' or pair == '/*' or source:sub(i + 1, i + 4) == '<!--' then
        -- `<!--` también abre un comentario de línea (Anexo B de ECMAScript,
        -- habitual en páginas antiguas): el árbol lo marca como html_comment.
        local block, stop = pair == '/*', nil
        if block then
          stop = source:find('*/', i + 3, true)
        else
          stop = source:find('\n', i + 3, true)
        end
        if not stop then return nil end
        stop = block and stop + 1 or stop - 1
        if stop >= cursor then return nil end
        blank(stop - i)
        i = stop
      elseif closing and char == '}' and depth == 0 then
        blank(1)
        return i + 1
      else
        if char == '{' then
          depth = depth + 1
        elseif char == '}' then
          depth = depth - 1
        end
        parts[#parts + 1], i = char, i + 1
      end
    end
    return CURSOR
  end

  if code(ctx.range[3], false) ~= CURSOR then return nil end
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
      if frame.name then
        -- Llaves abiertas entre la llamada y el cursor: el llamador decide
        -- si alguna es el cuerpo de un callback (ver asp.js_help).
        frame.braces = {}
        for j = i + 1, #stack do
          if stack[j].open == '{' then table.insert(frame.braces, stack[j].offset) end
        end
        return frame
      end
    end
  end
end

return M
