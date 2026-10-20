local M = {}

local EXTENSIONS = { asp = true, inc = true, htm = true, html = true, js = true, css = true }
local SOURCE_EXTENSIONS = { asp = true, inc = true, htm = true, html = true, js = true }
local file_cache = {}

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
  if line:sub(col, col):match('["\']') then return nil end
  local left = line:sub(1, col - 1):match('.*()["\']')
  local right = line:find('["\']', col)
  if left and right and line:sub(left, left) == line:sub(right, right) then
    return line:sub(left + 1, right - 1)
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

-- Las directivas usan su kind, no la barra inicial: virtual="includes/x"
-- también parte de la raíz. Se excluyen de los literales para no duplicarlas
-- ni resolverlas por error como rutas relativas. Dentro de <% %> son texto.
local function include_references(content, from_abs)
  local refs, spans = {}, {}
  local offset = 1
  while true do
    local first = content:find('<', offset, true)
    if not first then break end
    if content:sub(first, first + 1) == '<%' then
      local close = content:find('%>', first + 2, true)
      if not close then break end
      offset = close + 2
    else
      local _, last, kind, quote, path = content:find(
        '^<!%-%-#include%s+(%a+)%s*=%s*(["\'])(.-)%2%s*%-%->', first)
      if last and (kind == 'file' or kind == 'virtual') and not path:find(quote, 1, true) then
        table.insert(spans, { first = first, last = last })
        local target = require('asp.includes').resolve_one({
          kind = kind, path_text = path:gsub('\\', '/'),
        }, from_abs)
        if target then
          table.insert(refs, { target_abs = target, first = first, last = last })
        end
        offset = last + 1
      else
        offset = first + 1
      end
    end
  end
  return refs, spans
end

local function scan_file(content, from_abs)
  local refs, includes = include_references(content, from_abs)
  local left, left_quote, inc = nil, nil, 1
  -- Cada par de comillas vecinas del mismo tipo equivale a literal_at.
  -- No se emparejan desde el inicio de la línea: eso perdería href=""x.asp""
  -- en Response.Write y strings JS dentro de atributos HTML.
  for right, quote in content:gmatch('()(["\'])') do
    if left and left_quote == quote then
      while includes[inc] and includes[inc].last < left do inc = inc + 1 end
      local span = includes[inc]
      local text = content:sub(left + 1, right - 1)
      if (not span or right < span.first) and not text:find('\n', 1, true) then
        local target = M.resolve(text, from_abs)
        if target then
          table.insert(refs, { target_abs = target, first = left + 1, last = right - 1 })
        end
      end
    end
    left, left_quote = right, quote
  end
  table.sort(refs, function(a, b) return a.first < b.first end)

  local lnum, line_start = 0, 1
  local newline = content:find('\n', 1, true)
  local function position(offset)
    while newline and newline < offset do
      lnum, line_start = lnum + 1, newline + 1
      newline = content:find('\n', line_start, true)
    end
    return lnum, offset - line_start
  end
  local entries = {}
  for _, ref in ipairs(refs) do
    local row, col = position(ref.first)
    local end_row, end_col = position(ref.last + 1)
    table.insert(entries, {
      target_abs = ref.target_abs, lnum = row, col = col,
      end_lnum = end_row, end_col = end_col,
    })
  end
  return entries
end

local function collect_file(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    file_cache[path] = nil
    return {}
  end
  local mtime = stat.mtime.sec .. ':' .. stat.mtime.nsec
  local root = require('asp.includes').virtual_root_for(path)
  local hit = file_cache[path]
  if hit and hit.mtime == mtime and hit.root == root then return hit.entries end
  local f = io.open(path, 'r')
  if not f then return {} end
  local content = f:read('*a')
  f:close()
  if not content then return {} end
  local entries = scan_file(content, path)
  file_cache[path] = { mtime = mtime, root = root, entries = entries }
  return entries
end

---@param abs_path string
function M.invalidate(abs_path)
  if type(abs_path) == 'string' then file_cache[vim.fs.normalize(abs_path)] = nil end
end

---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return table[]|nil Location[] ordenadas por archivo, línea y columna
function M.references(bufnr, position)
  local ok, result = pcall(function()
    local from = vim.api.nvim_buf_get_name(bufnr)
    local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, true)[1]
    local text = literal_at(line, position.character + 1)
    local target = text and M.resolve(text, from)
    if not target then
      -- Un literal irresoluble no pregunta por el buffer por accidente.
      if text then return nil end
      local ext = from:lower():match('%.(%w+)$')
      if ext ~= 'asp' and ext ~= 'inc' then return nil end
      target = vim.fs.normalize(from)
    end
    local root = require('asp.includes').virtual_root_for(from)
    if not root then return nil end
    local files = {}
    local function walk(dir)
      local handle = vim.uv.fs_scandir(dir)
      if not handle then return end
      while true do
        local name, kind = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if name:sub(1, 1) ~= '.' then
          local path = dir .. '/' .. name
          if kind == 'directory' and name ~= 'node_modules' and name ~= 'build' then
            walk(path)
          elseif kind == 'file' and SOURCE_EXTENSIONS[name:lower():match('%.(%w+)$')] then
            table.insert(files, path)
          end
        end
      end
    end
    walk(root)
    table.sort(files)
    local out = {}
    for _, file in ipairs(files) do
      for _, ref in ipairs(collect_file(file)) do
        if ref.target_abs == target then
          table.insert(out, {
            uri = vim.uri_from_fname(file),
            range = {
              start = { line = ref.lnum, character = ref.col },
              ['end'] = { line = ref.end_lnum, character = ref.end_col },
            },
          })
        end
      end
    end
    return #out > 0 and out or nil
  end)
  return ok and result or nil
end

---@param text string
---@return string
function M.includeexpr(text)
  local ok, result = pcall(function()
    -- Conservar el texto deja que gf use 'path' si no es una página local.
    return M.resolve(text, vim.api.nvim_buf_get_name(0)) or text
  end)
  return ok and result or text
end

return M
