local M = {}

local EXTENSIONS = { asp = true, inc = true, htm = true, html = true, js = true, css = true }

---@param text string
---@param from_abs string
---@return string|nil ruta absoluta de un archivo existente
function M.resolve(text, from_abs)
  local ok, result = pcall(function()
    local path = vim.trim(text:match('^[^?#]*')):gsub('\\', '/')
    local lower = path:lower()
    if lower:match('^https?://') or lower:match('^//')
      or lower:match('^mailto:') or lower:match('^javascript:') then
      return nil
    end
    if not EXTENSIONS[lower:match('%.(%w+)$')] then return nil end
    if not from_abs or from_abs == '' then return nil end
    return require('asp.includes').resolve_one({
      kind = path:sub(1, 1) == '/' and 'virtual' or 'file',
      path_text = path,
    }, from_abs)
  end)
  return ok and result or nil
end

-- Leer la línea evita depender de las tres gramáticas y de las regiones
-- VBScript fusionadas cuando hay varios <%= %> en una misma línea.
local function literal_at(line, col)
  local i = 1
  while i <= #line do
    local start = line:find('["\']', i)
    if not start then return nil end
    local quote = line:sub(start, start)
    i = start + 1
    while i <= #line do
      local char, next_char = line:sub(i, i), line:sub(i + 1, i + 1)
      -- Sin saltar escapes JS y comillas dobles de VBScript, una comilla
      -- interior convertiría el resto de la línea en falsos literales.
      if (char == '\\' and (next_char == quote or next_char == '\\'))
        or (char == quote and next_char == quote) then
        i = i + 2
      elseif char == quote then
        if col > start and col < i then return line:sub(start + 1, i - 1) end
        i = i + 1
        break
      else
        i = i + 1
      end
    end
  end
end

---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return table|nil Location
function M.definition(bufnr, position)
  local ok, result = pcall(function()
    local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, true)[1]
    local text = literal_at(line, position.character + 1)
    if not text then return nil end
    local path = M.resolve(text, vim.api.nvim_buf_get_name(bufnr))
    if not path then return nil end
    return {
      uri = vim.uri_from_fname(path),
      range = {
        start = { line = 0, character = 0 },
        ['end'] = { line = 0, character = 0 },
      },
    }
  end)
  return ok and result or nil
end

---@param text string
---@return string|nil
function M.includeexpr(text)
  local ok, result = pcall(function()
    -- Conservar el texto deja que gf use 'path' si no es una página local.
    return M.resolve(text, vim.api.nvim_buf_get_name(0)) or text
  end)
  return ok and result or nil
end

return M
