local M = {}

-- Los corchetes de la documentación indican parámetros opcionales, también
-- al principio de una firma como InStr([start, ]string1, string2[, compare]).
function M.parameters(signature, docs)
  local args = signature:match('%((.*)%)')
  if not args or args == '' then return {} end
  local out, depth = {}, 0
  for part in (args .. ','):gmatch('(.-),') do
    local name = vim.trim((part:gsub('[%[%]]', '')))
    local before = part:match('^(.-)[%w_]') or ''
    local _, opens = before:gsub('%[', '')
    local _, closes = before:gsub('%]', '')
    local optional = depth + opens - closes > 0
    local _, all_opens = part:gsub('%[', '')
    local _, all_closes = part:gsub('%]', '')
    depth = depth + all_opens - all_closes
    if name ~= '' then
      out[#out + 1] = { name = name, optional = optional, doc = docs and docs[#out + 1] or nil }
    end
  end
  return out
end

function M.markdown(info)
  local lines = { '```vbscript', info.signature, '```', '', info.doc or '' }
  for _, param in ipairs(info.params or {}) do
    if param.doc then
      lines[#lines + 1] = ('\n- `%s`%s: %s'):format(param.name,
        param.optional and ' (opcional)' or '', param.doc)
    end
  end
  if info.returns then lines[#lines + 1] = '\nRetorno: `' .. info.returns .. '`.' end
  return table.concat(lines, '\n')
end

return M
