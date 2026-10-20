local M = {}

local INCLUDE_QUERY = [[
(include_directive
  kind: (include_kind) @kind
  path: (quoted_path) @path) @inc
]]

local function norm(path)
  return (vim.fs.normalize(path):gsub('//+', '/'))
end

---Raíz virtual del sitio para resolver includes `virtual="/..."`: honra
---`setup({virtual_root})` si se fijó, si no busca el `web.config` más
---cercano hacia arriba desde `abs_path`, y si no existe cae al `.git` más
---cercano. Pública (además de M.includes_of/M.graph/M.buffer_graph) porque
---lsp.lua M.start la reutiliza para calcular `root_dir`: la raíz de
---includes y la raíz del workspace LSP deben coincidir — si difirieran, un
---archivo bajo `proyecto/web.config` attachearía con root_dir del repo
---mientras sus includes virtual= resuelven contra `proyecto/`.
---@param abs_path string
---@return string|nil
function M.virtual_root_for(abs_path)
  local opts = require('asp').options
  if opts.virtual_root and opts.virtual_root ~= '' then
    return norm(opts.virtual_root)
  end
  return vim.fs.root(abs_path, { 'web.config' })
    or vim.fs.root(abs_path, { '.git' })
end

-- Extrae los includes de UNA fuente ya parseada (top layer aspclassic;
-- las injections no se tocan: los include_directive viven en la plantilla).
local function extract(root_node, source)
  local query = vim.treesitter.query.parse('aspclassic', INCLUDE_QUERY)
  local out = {}
  for _, match in query:iter_matches(root_node, source) do
    local item = {}
    for id, nodes in pairs(match) do
      if type(nodes) ~= 'table' then nodes = { nodes } end
      local cap = query.captures[id]
      local node = nodes[#nodes]
      if cap == 'kind' then
        item.kind = vim.treesitter.get_node_text(node, source):lower()
      elseif cap == 'path' then
        local raw = vim.treesitter.get_node_text(node, source)
        item.path_text = raw:sub(2, -2):gsub('\\', '/')
      elseif cap == 'inc' then
        local lnum, col, _end_row, end_col = node:range()
        item.lnum, item.col, item.end_col = lnum, col, end_col
      end
    end
    table.insert(out, item)
  end
  table.sort(out, function(a, b) return a.lnum < b.lnum end)
  return out
end

---Normaliza la ruta sin exigir que el destino exista todavía.
---@param item table {kind, path_text} con separadores ya normalizados
---@param from_abs string
---@param root? string|false raíz virtual ya calculada; false si no hay
---@return string|nil
function M.candidate_for(item, from_abs, root)
  if item.kind == 'virtual' then
    if root == nil then root = M.virtual_root_for(from_abs) end
    if not root then return nil end
    return norm(root .. '/' .. item.path_text)
  end
  return norm(vim.fs.dirname(from_abs) .. '/' .. item.path_text)
end

-- Tope de archivos en file_cache; al pasarlo se expulsa el usado hace más
-- tiempo (LRU). Cada entrada es sólo la lista de directivas de un archivo
-- (unos pocos items de cinco campos), así que 512 cuestan poco y cubren
-- el grafo de muchas páginas a la vez; el tope sólo evita que la caché
-- crezca con cada archivo visitado en una sesión larga.
local FILE_CACHE_MAX = 512

-- ruta normalizada → {stamp, used, items}. `items` son las directivas SIN
-- resolver ({kind, path_text, lnum, col, end_col}): el destino de un
-- include puede aparecer o desaparecer sin que cambie el archivo que lo
-- incluye, así que `resolved` se calcula en cada consulta. `used` es el
-- valor de `clock` en el último uso de la entrada.
local file_cache = {}
local cached = 0
local clock = 0
-- Valor de `clock` al empezar la consulta en curso (graph, buffer_graph o
-- un includes_of suelto): las entradas usadas desde entonces son de esa
-- consulta y no se expulsan. Si no, un grafo de más de FILE_CACHE_MAX
-- archivos se recorrería en el mismo orden en cada consulta y cada archivo
-- saldría antes de volver a usarse: todo se releería de disco. El tope
-- efectivo es el mayor entre FILE_CACHE_MAX y el tamaño del grafo.
local walk_start = 0

local function forget(path)
  if file_cache[path] then
    file_cache[path] = nil
    cached = cached - 1
  end
end

---Clave de caché de un archivo: mtime y tamaño (el tamaño cubre los
---sistemas de archivos con mtime de un segundo), como asp.js.
local function stamp_of(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. ':' .. st.mtime.nsec .. ':' .. st.size) or nil
end

local function remember(path, entry)
  if not file_cache[path] then cached = cached + 1 end
  file_cache[path] = entry
  while cached > FILE_CACHE_MAX do
    local lru
    for p, e in pairs(file_cache) do
      if e.used < walk_start and (not lru or e.used < file_cache[lru].used) then lru = p end
    end
    if not lru then return end
    forget(lru)
  end
end

-- Abre una consulta: lo que se use desde ahora no se expulsa de file_cache
-- (ver walk_start). Devuelve el memo de raíces virtuales de la consulta
-- (ver resolved_includes).
local function begin_walk()
  walk_start = clock + 1
  return {}
end

---Directivas de un archivo de disco, sin resolver, cacheadas por mtime y
---tamaño. Lanza si el archivo no se puede leer o parsear (lo atrapa
---resolved_includes): un fallo no se cachea.
---@param path string ruta normalizada
---@return table[]
local function directives_of(path)
  local stamp = stamp_of(path)
  if not stamp then
    -- Borrado o inaccesible: su entrada ya no sirve.
    forget(path)
    return {}
  end
  clock = clock + 1
  local hit = file_cache[path]
  if hit and hit.stamp == stamp then
    hit.used = clock
    return hit.items
  end
  local f = io.open(path, 'r')
  if not f then return {} end
  local content = f:read('*a')
  f:close()
  local parser = vim.treesitter.get_string_parser(content, 'aspclassic')
  local items = extract(parser:parse()[1]:root(), content)
  remember(path, { stamp = stamp, used = clock, items = items })
  return items
end

---@param item table {kind, path_text} con separadores ya normalizados
---@param from_abs string
---@param root? string|false raíz virtual ya calculada (ver candidate_for)
---@return string|nil
function M.resolve_one(item, from_abs, root)
  local candidate = M.candidate_for(item, from_abs, root)
  if not candidate then return nil end
  local stat = vim.uv.fs_stat(candidate)
  if stat and stat.type == 'file' then return candidate end
  -- El destino ya no existe: si estaba en la caché (un include borrado),
  -- sale ahora. Sin esto quedaría hasta que lo expulse el LRU, porque un
  -- destino que no resuelve nunca vuelve a pasar por directives_of.
  forget(candidate)
  return nil
end

---Olvida las directivas cacheadas de un archivo (BufWritePost). La caché
---ya se valida por mtime y tamaño en cada consulta; esto sólo lo adelanta.
---@param abs_path string
function M.invalidate(abs_path)
  forget(norm(abs_path))
end

-- Para los tests: el tope y las rutas de file_cache.
M._FILE_CACHE_MAX = FILE_CACHE_MAX
function M._cached_files()
  return vim.tbl_keys(file_cache)
end

-- Cuerpo de M.includes_of, con `abs_path` ya normalizada y `roots`, el memo
-- de raíces virtuales de la consulta (directorio → raíz|false). La raíz
-- depende sólo del directorio (y de la opción virtual_root) y calcularla
-- sube por el árbol haciendo un fs_stat por nivel (16 µs bajo un
-- web.config, ~50 sin él), así que en un recorrido del grafo se calcula una
-- vez por directorio, como en asp.pages.
local function resolved_includes(abs_path, bufnr, roots)
  local ok, items = pcall(function()
    local out
    if bufnr then
      local parser = vim.treesitter.get_parser(bufnr, 'aspclassic')
      out = extract(parser:parse()[1]:root(), bufnr)
      abs_path = norm(vim.api.nvim_buf_get_name(bufnr))
    else
      -- Copias: el llamador recibe tablas propias y les agrega `resolved`
      -- sin tocar la caché.
      out = vim.deepcopy(directives_of(abs_path))
    end
    for _, item in ipairs(out) do
      local root
      if item.kind == 'virtual' then
        local dir = vim.fs.dirname(abs_path)
        if roots[dir] == nil then roots[dir] = M.virtual_root_for(abs_path) or false end
        root = roots[dir]
      end
      item.resolved = M.resolve_one(item, abs_path, root)
    end
    return out
  end)
  return ok and items or {}
end

---Directivas de include de un archivo, con su destino resuelto. Las de
---disco salen de una caché por archivo (ver directives_of); las de un
---buffer se extraen de su árbol, que ya mantiene el propio buffer.
---@param abs_path string|nil ruta en disco (nil si se pasa bufnr)
---@param bufnr integer|nil buffer cuyo contenido usar en lugar del disco
---@return table[] lista {kind, path_text, resolved, lnum, col, end_col}
function M.includes_of(abs_path, bufnr)
  return resolved_includes(abs_path and norm(abs_path), bufnr, begin_walk())
end

-- Declaración adelantada: walk_from_disk y process_items se llaman entre sí
-- (mutua recursión al bajar por el árbol de includes).
local walk_from_disk
local process_items

-- Procesa la lista cruda de includes de UN archivo (`from_abs`), clasificando
-- cada uno en unresolved/cycle/order y, para los nuevos resueltos,
-- recorriendo su contenido en disco. Compartida por graph() y
-- buffer_graph(): ambas difieren solo en cómo obtienen los items del primer
-- nivel (disco vs. buffer); todo lo que sigue —clasificar, cortar ciclos,
-- bajar por los includes resueltos— es idéntico, así que vive aquí una
-- única vez en lugar de duplicarse en cada wrapper.
--
-- `visited` acumula TODO archivo ya procesado alguna vez (para nunca leerlo
-- ni recorrerlo dos veces); `on_stack` marca solo los archivos en la rama
-- DFS activa ahora mismo (se limpia al volver de walk_from_disk). Un
-- include a un nodo `on_stack` es un ciclo real (hay un camino de vuelta
-- desde el destino hasta el origen). Un include a un nodo `visited` pero
-- NO `on_stack` es un diamante — dos ramas independientes que comparten un
-- include común (p. ej. A incluye B y C, y C también incluye B) — y se
-- debe deduplicar en silencio: no es un ciclo, no vuelve a aparecer en
-- `order`, y no se re-recorre. `roots` es el memo de raíces virtuales de
-- la consulta (ver resolved_includes).
process_items = function(items, from_abs, visited, on_stack, g, roots)
  for _, item in ipairs(items) do
    if not item.resolved then
      table.insert(g.unresolved, {
        text = item.path_text,
        kind = item.kind,
        from = from_abs,
        lnum = item.lnum,
        col = item.col,
        end_col = item.end_col,
      })
    elseif on_stack[item.resolved] then
      table.insert(g.cycles, { from = from_abs, to = item.resolved })
    elseif visited[item.resolved] then
      -- diamante: ya se recorrió por otra rama y no está en la pila actual;
      -- se omite en silencio (sin duplicar order, sin cycles, sin recursión).
    else
      table.insert(g.order, item.resolved)
      walk_from_disk(item.resolved, visited, on_stack, g, roots)
    end
  end
end

-- Recorre disco puro a partir de `abs`: siempre lee `abs` del disco (vía
-- resolved_includes(abs, nil), con la caché de directivas) y delega en
-- process_items. Usada para todo nivel de recursión posterior al primero,
-- tanto desde graph() como desde buffer_graph() — los archivos incluidos
-- siempre se leen de disco, nunca de un buffer abierto.
walk_from_disk = function(abs, visited, on_stack, g, roots)
  visited[abs] = true
  on_stack[abs] = true
  local items = resolved_includes(abs, nil, roots)
  process_items(items, abs, visited, on_stack, g, roots)
  on_stack[abs] = nil
end

---@param abs_path string
---@return table { order, unresolved, cycles }
function M.graph(abs_path)
  abs_path = norm(abs_path)
  local g = { order = {}, unresolved = {}, cycles = {} }
  local visited = { [abs_path] = true }
  local on_stack = { [abs_path] = true }
  local roots = begin_walk()
  local items = resolved_includes(abs_path, nil, roots)
  process_items(items, abs_path, visited, on_stack, g, roots)
  on_stack[abs_path] = nil
  return g
end

---@param bufnr integer
---@return table { order, unresolved, cycles }
function M.buffer_graph(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local abs = norm(vim.api.nvim_buf_get_name(bufnr))
  local g = { order = {}, unresolved = {}, cycles = {} }
  local visited = { [abs] = true }
  local on_stack = { [abs] = true }
  local roots = begin_walk()
  local items = resolved_includes(nil, bufnr, roots)
  process_items(items, abs, visited, on_stack, g, roots)
  on_stack[abs] = nil
  return g
end

return M
