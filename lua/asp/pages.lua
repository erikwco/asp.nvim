local M = {}

local EXTENSIONS = { asp = true, inc = true, htm = true, html = true, js = true, css = true }
local SOURCE_EXTENSIONS = { asp = true, inc = true, htm = true, html = true, js = true }
local file_cache = {}

local function candidate_for(text, from_abs, root)
  local path = vim.trim(text:match('^[^?#]*')):gsub('\\', '/')
  local lower = path:lower()
  if lower:match('^https?://') or lower:match('^//')
    or lower:match('^mailto:') or lower:match('^javascript:') then
    return nil
  end
  if not EXTENSIONS[lower:match('%.(%w+)$')] then return nil end
  if not from_abs or from_abs == '' then return nil end
  return require('asp.includes').candidate_for({
    kind = path:sub(1, 1) == '/' and 'virtual' or 'file',
    path_text = path,
  }, from_abs, root)
end

---@param text string
---@param from_abs string
---@return string|nil ruta absoluta de un archivo existente
function M.resolve(text, from_abs)
  local ok, result = pcall(function()
    local candidate = candidate_for(text, from_abs)
    if not candidate then return nil end
    local stat = vim.uv.fs_stat(candidate)
    return (stat and stat.type == 'file') and candidate or nil
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
local function include_references(content, from_abs, root)
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
        local target = require('asp.includes').candidate_for({
          kind = kind, path_text = path:gsub('\\', '/'),
        }, from_abs, root)
        if target then
          -- `include` separa las directivas de los literales: asp.site arma
          -- con ellas el grafo de includes del sitio sin volver a leer nada.
          table.insert(refs, { target_abs = target, first = first, last = last, include = true })
        end
        offset = last + 1
      else
        offset = first + 1
      end
    end
  end
  return refs, spans
end

local function scan_file(content, from_abs, root)
  local refs, includes = include_references(content, from_abs, root)
  local left, left_quote, inc = nil, nil, 1
  -- Cada par de comillas vecinas del mismo tipo equivale a literal_at.
  -- No se emparejan desde el inicio de la línea: eso perdería href=""x.asp""
  -- en Response.Write y strings JS dentro de atributos HTML.
  for right, quote in content:gmatch('()(["\'])') do
    if left and left_quote == quote then
      while includes[inc] and includes[inc].last < left do inc = inc + 1 end
      local span = includes[inc]
      local text = content:sub(left + 1, right - 1)
      local ext = text:match('^[^?#]*'):match('%.(%w+)%s*$')
      if ext and EXTENSIONS[ext:lower()]
        and (not span or right < span.first) and not text:find('\n', 1, true) then
        local target = candidate_for(text, from_abs, root)
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
      end_lnum = end_row, end_col = end_col, include = ref.include,
    })
  end
  return entries
end

---Contenido de una fuente con las columnas UTF-8 que tendrá su buffer: sin
---BOM y convertido de latin1 si no es UTF-8 válido. Lo comparten el
---barrido de páginas y las ocurrencias VBScript de disco (asp.symbols),
---para que ambos den las mismas columnas que el buffer abierto.
---@param path string
---@return string|nil
function M.read(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  if not content then return nil end
  content = content:gsub('^\239\187\191', '')
  if content:find('[\128-\255]') then
    -- iconv sustituye los bytes UTF-8 inválidos; la ida y vuelta los detecta.
    local utf16 = vim.iconv(content, 'utf-8', 'utf-16le')
    if utf16 and vim.iconv(utf16, 'utf-16le', 'utf-8') ~= content then
      content = vim.iconv(content, 'latin1', 'utf-8') or content
    end
  end
  return content
end

local function collect_file(path, root, contents)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    file_cache[path] = nil
    return {}
  end
  local mtime = stat.mtime.sec .. ':' .. stat.mtime.nsec
  local hit = file_cache[path]
  if hit and hit.mtime == mtime and hit.size == stat.size and hit.root == root then
    return hit.entries, false
  end
  local content = M.read(path)
  if not content then return {}, false end
  if contents then contents[path] = content end
  local entries = scan_file(content, path, root)
  file_cache[path] = { mtime = mtime, size = stat.size, root = root, entries = entries }
  return entries, true
end

---@param abs_path string
function M.invalidate(abs_path)
  if type(abs_path) ~= 'string' then return end
  file_cache[vim.fs.normalize(abs_path)] = nil
  -- El barrido guarda rutas reales: un buffer abierto a través de un
  -- symlink también tiene que invalidar la suya.
  local real = vim.uv.fs_realpath(abs_path)
  if real then file_cache[real] = nil end
end

---El barrido abarca el sitio exterior; /virtual conserva la raíz más cercana.
---@param abs_path string
---@return string|nil
function M.scan_root_for(abs_path)
  local configured = require('asp').options.virtual_root
  if configured and configured ~= '' then return vim.fs.normalize(configured) end
  local outer
  for dir in vim.fs.parents(abs_path) do
    if vim.uv.fs_stat(dir .. '/web.config') then outer = dir end
  end
  return outer or vim.fs.root(abs_path, { '.git' })
end

---Recorre las fuentes del sitio bajo `root` y devuelve sus entradas
---(literales y directivas `include`) desde la caché por archivo: solo lee
---las fuentes nuevas o cambiadas. Purga de la caché las fuentes de esa raíz
---que ya no aparecen. Lo comparten M.references y asp.site, así que ambos
---ven el mismo sitio con un único escáner y una única caché.
---
---Una entrada sin cambios conserva su tabla entre barridos: asp.site
---compara esas tablas para saber si su índice de includes sigue vigente.
---
---Si se pasa `contents`, recibe el contenido de cada fuente que este
---barrido leyó, por ruta real: asp.symbols lo reutiliza durante la misma
---consulta para no volver a leer esos archivos. Sin `contents` no se
---retiene ningún contenido.
---@param root string raíz de scan_root_for
---@param contents? table<string, string>
---@return string[] files rutas reales, ordenadas
---@return table<string, table[]> entries por archivo
---@return integer read fuentes leídas de disco en este barrido
function M.sweep(root, contents)
  root = vim.uv.fs_realpath(root) or root
  local files, dirs, next_dir = {}, { root }, 1
  while next_dir <= #dirs do
    local dir = dirs[next_dir]
    next_dir = next_dir + 1
    for name, kind in vim.fs.dir(dir) do
      if name:sub(1, 1) ~= '.' then
        local path = dir .. '/' .. name
        -- En 0.10 scandir puede omitir el tipo. Hay que recuperarlo antes
        -- de decidir si descender; lstat conserva los symlinks como links.
        if kind == nil then
          local stat = vim.uv.fs_lstat(path)
          kind = stat and stat.type
        end
        if kind == 'directory' and name ~= 'node_modules' and name ~= 'build' then
          table.insert(dirs, path)
        elseif kind == 'file' and SOURCE_EXTENSIONS[name:lower():match('%.(%w+)$')] then
          table.insert(files, path)
        end
      end
    end
  end
  table.sort(files)
  local entries, roots, read = {}, {}, 0
  for _, file in ipairs(files) do
    local dir = vim.fs.dirname(file)
    if roots[dir] == nil then roots[dir] = require('asp.includes').virtual_root_for(file) or false end
    local fresh
    entries[file], fresh = collect_file(file, roots[dir], contents)
    if fresh then read = read + 1 end
  end
  local prefix = root:gsub('/$', '') .. '/'
  for path in pairs(file_cache) do
    if path:sub(1, #prefix) == prefix and not entries[path] then file_cache[path] = nil end
  end
  return files, entries, read
end

---Aviso INFO de una consulta que recorrió el sitio: si leyó de disco
---2.000 archivos o más, o si tardó un segundo desde `started`
---(vim.uv.hrtime()). No depende del tamaño del sitio: con la caché
---caliente, una consulta rápida no avisa.
---@param count integer archivos recorridos
---@param read integer archivos leídos de disco en la consulta
---@param started number
function M.notify_slow(count, read, started)
  if read >= 2000 or vim.uv.hrtime() - started >= 1e9 then
    vim.notify(('asp: se recorrieron %d archivos; las siguientes consultas usan la caché.'):format(count),
      vim.log.levels.INFO)
  end
end

---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return table[]|nil Location[] ordenadas por archivo, línea y columna
function M.references(bufnr, position)
  local ok, result = pcall(function()
    local started = vim.uv.hrtime()
    local from = vim.api.nvim_buf_get_name(bufnr)
    local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, true)[1]
    local text = literal_at(line, position.character + 1)
    local ext = text and text:match('^[^?#]*'):match('%.(%w+)%s*$')
    if not ext or not EXTENSIONS[ext:lower()] then text = nil end
    local target = text and M.resolve(text, from)
    if not target then
      -- Un literal irresoluble no pregunta por el buffer por accidente.
      if text then return nil end
      local ext = from:lower():match('%.(%w+)$')
      if ext ~= 'asp' and ext ~= 'inc' then return nil end
      target = vim.fs.normalize(from)
    end
    local root = M.scan_root_for(from)
    if not root then return nil end
    local target_real = vim.uv.fs_realpath(target) or target
    local base, memo = target_real:lower():match('[^/]+$'), {}
    local function same(candidate)
      if candidate == target then return true end
      if candidate:lower():match('[^/]+$') ~= base then return false end
      if memo[candidate] == nil then memo[candidate] = vim.uv.fs_realpath(candidate) or false end
      return memo[candidate] == target_real
    end
    local files, entries, read = M.sweep(root)
    local out = {}
    for _, file in ipairs(files) do
      for _, ref in ipairs(entries[file]) do
        if same(ref.target_abs) then
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
    M.notify_slow(#files, read, started)
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
