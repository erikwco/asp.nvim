local M = {}

-- Grafo de includes de todo el sitio, en los dos sentidos, armado con las
-- directivas que ya detecta el barrido de asp.pages (texto, sin
-- tree-sitter). Lo usa asp.symbols para buscar los usos de un símbolo de
-- página en las páginas que incluyen la librería donde está declarado.

-- raíz real → índice. `sources` guarda la tabla de entradas de cada fuente
-- con que se armó: asp.pages devuelve la misma tabla mientras el archivo
-- no cambie, así que comparar esas tablas dice si el índice sigue vigente
-- sin releer nada, aunque otra consulta haya barrido el sitio entre medio.
local indexes = {}

-- Ruta real de un archivo existente, o nil (como asp.includes.resolve_one,
-- un directorio no es un include). `memo` evita repetir las llamadas al
-- sistema cuando muchas páginas incluyen el mismo archivo.
local function realpath(path, memo)
  if memo[path] == nil then
    local stat = vim.uv.fs_stat(path)
    memo[path] = stat and stat.type == 'file' and vim.uv.fs_realpath(path) or false
  end
  return memo[path] or nil
end

local function current(index, files, entries)
  if not index or index.count ~= #files then return false end
  for _, file in ipairs(files) do
    if index.sources[file] ~= entries[file] then return false end
  end
  return true
end

-- Rearma las aristas con los destinos ya resueltos en `memo`.
local function link(index, memo)
  index.includes, index.includers, index.resolved = {}, {}, memo
  for _, file in ipairs(index.files) do
    for _, candidate in ipairs(index.targets[file] or {}) do
      local target = memo[candidate]
      if target then
        index.includes[file] = index.includes[file] or {}
        table.insert(index.includes[file], target)
        index.includers[target] = index.includers[target] or {}
        table.insert(index.includers[target], file)
      end
    end
  end
end

---Índice de includes del sitio bajo `root`: `includes[archivo]` son los
---archivos que incluye y `includers[archivo]` los que lo incluyen, todos
---con su ruta real. Solo cuenta destinos que existen. El barrido de
---asp.pages lee únicamente las fuentes nuevas o cambiadas y las directivas
---se reagrupan solo si alguna fuente cambió, apareció o desapareció.
---
---Como en asp.includes, las directivas se guardan sin resolver: un
---destino puede aparecer, desaparecer o cambiar de ruta real sin que
---cambie ninguna fuente, por ejemplo un include fuera de la raíz del
---barrido. Por eso cada llamada vuelve a resolver los destinos, una vez
---por ruta distinta y sin leer archivos, y rearma las aristas solo si
---alguno cambió.
---@param root string raíz de asp.pages.scan_root_for
---@param contents? table<string, string> ver asp.pages.sweep
---@return table { includes, includers, sources, count }
function M.index(root, contents)
  local files, entries = require('asp.pages').sweep(root, contents)
  local key = vim.uv.fs_realpath(root) or root
  local index = indexes[key]
  if not current(index, files, entries) then
    -- `targets[archivo]` son los destinos normalizados de sus directivas
    -- y `candidates`, cada destino distinto una sola vez.
    index = { files = files, sources = {}, targets = {}, candidates = {}, count = #files }
    local seen = {}
    for _, file in ipairs(files) do
      index.sources[file] = entries[file]
      for _, ref in ipairs(entries[file]) do
        if ref.include then
          index.targets[file] = index.targets[file] or {}
          table.insert(index.targets[file], ref.target_abs)
          if not seen[ref.target_abs] then
            seen[ref.target_abs] = true
            table.insert(index.candidates, ref.target_abs)
          end
        end
      end
    end
    indexes[key] = index
  end

  -- Las rutas de `files` ya son reales (el barrido parte de la raíz real y
  -- no sigue symlinks); los destinos se llevan a su ruta real para que una
  -- raíz virtual por symlink o un nombre con otras mayúsculas en un
  -- filesystem que no las distingue apunten al mismo archivo.
  local memo, stale = {}, index.resolved == nil
  for _, candidate in ipairs(index.candidates) do
    realpath(candidate, memo)
    if not stale and memo[candidate] ~= index.resolved[candidate] then stale = true end
  end
  if stale then link(index, memo) end
  return index
end

---Archivos donde un símbolo de página de `starts` es la misma variable
---global: cada archivo de `starts`, los que lo incluyen directa o
---transitivamente, y todo lo que incluye cada uno de ellos (un include
---hermano de la librería ve sus globales a través de la página).
---
---Hacia arriba solo se conocen incluidores dentro de la raíz del barrido.
---Hacia abajo, un include fuera de esa raíz no está en el índice y se
---recorre con asp.includes.graph.
---
---`edits` reemplaza los includes de disco de algunos archivos (por ruta
---real) por los de su buffer sin guardar, en los dos sentidos: un include
---borrado en el buffer no vuelve a sumarse por el índice y uno agregado
---cuenta aunque no se haya guardado.
---@param index table de M.index
---@param starts string[] rutas reales
---@param edits? table<string, string[]> ruta real → destinos reales
---@return string[] rutas reales, ordenadas
function M.closure(index, starts, edits)
  edits = edits or {}
  local added = {}
  for file, targets in pairs(edits) do
    for _, target in ipairs(targets) do
      added[target] = added[target] or {}
      table.insert(added[target], file)
    end
  end
  local seen, list = {}, {}
  local function add(path)
    if not seen[path] then
      seen[path] = true
      table.insert(list, path)
    end
  end
  for _, start in ipairs(starts) do add(start) end
  local i = 1
  while list[i] do
    for _, includer in ipairs(index.includers[list[i]] or {}) do
      if not edits[includer] then add(includer) end
    end
    for _, includer in ipairs(added[list[i]] or {}) do add(includer) end
    i = i + 1
  end
  local memo = {}
  i = 1
  while list[i] do
    local path = list[i]
    if edits[path] then
      for _, target in ipairs(edits[path]) do add(target) end
    elseif index.sources[path] then
      for _, target in ipairs(index.includes[path] or {}) do add(target) end
    else
      for _, target in ipairs(require('asp.includes').graph(path).order) do
        local real = realpath(target, memo)
        if real then add(real) end
      end
    end
    i = i + 1
  end
  table.sort(list)
  return list
end

return M
