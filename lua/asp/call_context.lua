local M = {}

-- Texto hasta el cursor dentro del bloque ASP actual. La máscara conserva
-- columnas en bytes, pero oculta strings (incluido "") y detecta comentarios.
function M.line(bufnr, position)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'aspclassic')
  if not ok or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end
  local root = tree:root()
  local row, col = position.line, position.character
  local node = root:named_descendant_for_range(row, col, row, col)
  if (not node or node:type() ~= 'code') and col > 0 then
    node = root:named_descendant_for_range(row, col - 1, row, col - 1)
  end
  if not node or node:type() ~= 'code' then return nil end
  local sr, sc = node:start()
  local offset = sr == row and sc or 0
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local text = line:sub(offset + 1, col)
  local mask, string_start, last_word = {}, nil, nil
  local i, statement_start = 1, true
  while i <= #text do
    local char = text:sub(i, i)
    if string_start then
      mask[i] = ' '
      if char == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          mask[i + 1], i = ' ', i + 1
        else
          string_start = nil
        end
      end
    elseif char == '"' then
      string_start, mask[i], statement_start = i, ' ', false
    elseif char == "'" then
      return nil
    elseif char:match('[%a_]') then
      local word = text:sub(i):match('^[%w_]+')
      local lower = word:lower()
      if lower == 'rem' and (statement_start or last_word == 'then' or last_word == 'else') then
        return nil
      end
      for j = i, i + #word - 1 do mask[j] = text:sub(j, j) end
      i, last_word, statement_start = i + #word - 1, lower, false
    else
      mask[i] = char
      if char == ':' then
        statement_start, last_word = true, nil
      elseif not char:match('%s') then
        statement_start, last_word = false, nil
      end
    end
    i = i + 1
  end
  return { text = text, mask = table.concat(mask), string_start = string_start, offset = offset }
end

local function callee(text)
  local start, _, name = text:find('([%a_][%w_]*%s*%.%s*[%a_][%w_]*)%s*$')
  if not start then start, _, name = text:find('([%a_][%w_]*)%s*$') end
  if not start then return nil end
  local preceding = text:sub(1, start - 1)
  if preceding:match('%.%s*$') or preceding:match('[%w_]$') then return nil end
  local prefix = text:sub(1, start - 1):lower()
  if prefix:match('%f[%a]function%s+$') or prefix:match('%f[%a]sub%s+$')
    or prefix:match('%f[%a]property%s+%a+%s+$') or prefix:match('%f[%a]dim%s+$') then
    return nil
  end
  return (name:gsub('%s', ''))
end

function M.active(context)
  if not context then return nil end
  local mask = context.mask
  local depth, commas = 0, 0
  for i = #mask, 1, -1 do
    local char = mask:sub(i, i)
    if char == ')' then
      depth = depth + 1
    elseif char == '(' then
      if depth == 0 then
        local name = callee(mask:sub(1, i - 1))
        return name and { name = name, parameter = commas, open = i } or nil
      end
      depth = depth - 1
    elseif char == ',' and depth == 0 then
      commas = commas + 1
    elseif char == ':' then
      break
    end
  end

  -- Sin paréntesis, solo al comienzo de una sentencia (también tras `:`).
  local start = 1
  for i in mask:gmatch('():') do start = i + 1 end
  local statement = mask:sub(start)
  statement = statement:gsub('^%s*[Cc][Aa][Ll][Ll]%s+', '')
  local name, rest = statement:match('^%s*([%a_][%w_]*%s*%.%s*[%a_][%w_]*)%s+(.*)$')
  if not name then name, rest = statement:match('^%s*([%a_][%w_]*)%s+(.*)$') end
  if not name or rest:match('^%s*=') or (commas == 0 and rest:match('^%s*%(')) then return nil end
  return { name = name:gsub('%s', ''), parameter = commas }
end

return M
