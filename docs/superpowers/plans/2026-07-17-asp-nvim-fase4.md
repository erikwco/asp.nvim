# asp.nvim — Fase 4: grafo de includes (navegación cross-file y diagnósticos) — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `definition`, `references` y `workspace/symbol` funcionan a través de `<!--#include file/virtual="..."-->` (recursivo, con ciclos cortados), y los includes irresolubles producen diagnósticos en la línea del include.

**Architecture:** Dos módulos nuevos: `lua/asp/includes.lua` (extrae los nodos `include_directive` de la capa aspclassic — sin parsear injections —, resuelve rutas `file=` relativas al archivo y `virtual=` relativas a una raíz autodetectada por marcador, y construye el grafo DFS con detección de ciclos) y `lua/asp/diagnostics.lua` (namespace `vim.diagnostic` para includes rotos/ciclos). `lua/asp/symbols.lua` gana `collect_file(path)`: parseo de archivos **desde disco sin abrirlos** usando string parsers con `set_included_ranges` sobre los nodos `(code)` — parsea SOLO la capa vbscript (nada de html/js/regex), que es además la técnica que evita el coste de 33s del backlog para la indexación. `definition` gana el tier cross-file; `references` y `workspace/symbol` son handlers nuevos.

**Tech Stack:** Lua (Neovim ≥0.10, validado 0.12), tree-sitter string parsers + included_ranges, vim.diagnostic, plenary.

**Fixtures:** `tests/fixtures/proyecto/` (ya commiteado, verificado 0 errores en ambas capas): `default.asp` (include file anidado + include virtual), `includes/helpers.asp` → `constantes.inc`, `lib/db.inc` (target virtual), `ciclo_a.asp` ↔ `ciclo_b.asp`, `roto.asp` (2 includes irresolubles), `web.config` (marcador de raíz virtual).

## Global Constraints

- Semántica ASP real: `file=` relativo al **archivo que incluye**; `virtual=` relativo a la **raíz virtual** (autodetección: `vim.fs.root` con marcadores `web.config` y `.git`, en ese orden de preferencia; override con `require('asp').setup({ virtual_root = '/ruta' })`).
- `quoted_path` conserva las comillas (backlog Fase 2): pelar con `text:sub(2, -2)`. Normalizar `\` → `/` (rutas ASP legacy).
- Grafo: DFS en orden de documento, cada archivo visitado UNA vez (set por ruta absoluta normalizada); ciclo → se corta la recursión y se reporta (spec).
- Resolución de definición cross-file: tras agotar los tiers in-file de la Fase 3, recorrer `graph.order` y aceptar solo símbolos **de nivel de página** (`scope_id == nil` y `class_id == nil`) — los locales y miembros de clase de otros archivos no son visibles como identificadores sueltos. Case-insensitive siempre.
- Include no resuelto → diagnóstico **WARN** en la línea del include; ciclo → un WARN en el buffer con mención del archivo (spec: "se corta la recursión y se reporta"). Nunca errores fatales.
- Archivos de disco: leer con `io.open`; caché por ruta con invalidación por `mtime` (`vim.uv.fs_stat`); `BufWritePost` de un `.asp`/`.inc` invalida su entrada.
- Los handlers JAMÁS lanzan (pcall del dispatch de Fase 3 sigue siendo la red); degradación suave con árboles parciales.
- Suite previa completa verde en cada task (`make clean && make test`); no hardcodear conteos globales.
- Los `asp/*.asp` propietarios: solo verificación local en la Task 5, nunca commiteados.

---

### Task 1: Módulo includes — extracción, resolución de rutas y grafo con ciclos

**Files:**
- Create: `lua/asp/includes.lua`
- Test: `tests/spec/includes_spec.lua`

**Interfaces:**
- Consumes: gramática aspclassic (`include_directive` con fields `kind`/`path`); `require('asp').options` (Fase 1) para el override `virtual_root`.
- Produces: `require('asp.includes').graph(abs_path)` y `.buffer_graph(bufnr)` → `{ order = {abs,...} (DFS, sin el archivo inicial, únicos), unresolved = { {text=string, kind='file'|'virtual', lnum=0based, col=0based, end_col=0based, from=abs}, ... }, cycles = { {from=abs, to=abs}, ... } }`. También `.includes_of(abs_path_or_nil, bufnr_or_nil)` → lista cruda `{ {kind, path_text, resolved=abs|nil, lnum, col, end_col} }` del archivo/buffer dado. Tasks 3-5 consumen exactamente esto.

- [ ] **Step 1: Tests que fallan**

`tests/spec/includes_spec.lua`:

```lua
local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

describe('asp.includes', function()
  local includes = nil

  before_each(function()
    includes = require('asp.includes')
  end)

  it('resuelve el grafo completo de default.asp en orden DFS', function()
    local g = includes.graph(FIX .. '/default.asp')
    assert.are.same({
      FIX .. '/includes/helpers.asp',
      FIX .. '/includes/constantes.inc',
      FIX .. '/lib/db.inc',
    }, g.order)
    assert.are.same({}, g.unresolved)
    assert.are.same({}, g.cycles)
  end)

  it('reporta includes irresolubles con posición', function()
    local g = includes.graph(FIX .. '/roto.asp')
    assert.are.same({}, g.order)
    assert.are.equal(2, #g.unresolved)
    assert.are.equal('no_existe.inc', g.unresolved[1].text)
    assert.are.equal('file', g.unresolved[1].kind)
    assert.are.equal(0, g.unresolved[1].lnum)
    assert.are.equal('virtual', g.unresolved[2].kind)
    assert.are.equal(1, g.unresolved[2].lnum)
  end)

  it('corta y reporta ciclos sin colgarse', function()
    local g = includes.graph(FIX .. '/ciclo_a.asp')
    assert.are.same({ FIX .. '/ciclo_b.asp' }, g.order)
    assert.are.equal(1, #g.cycles)
    assert.are.equal(FIX .. '/ciclo_b.asp', g.cycles[1].from)
    assert.are.equal(FIX .. '/ciclo_a.asp', g.cycles[1].to)
  end)

  it('buffer_graph usa el contenido del buffer para el archivo inicial', function()
    vim.cmd.edit(FIX .. '/default.asp')
    local g = includes.buffer_graph(0)
    assert.are.equal(3, #g.order)
    vim.cmd('bwipeout!')
  end)
end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — `module 'asp.includes' not found`.

- [ ] **Step 3: Implementar**

`lua/asp/includes.lua`:

```lua
local M = {}

local INCLUDE_QUERY = [[
(include_directive
  kind: (include_kind) @kind
  path: (quoted_path) @path) @inc
]]

local function norm(path)
  return (vim.fs.normalize(path):gsub('//+', '/'))
end

local function virtual_root_for(abs_path)
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
        item.lnum, item.col, _, item.end_col = node:range()
      end
    end
    table.insert(out, item)
  end
  table.sort(out, function(a, b) return a.lnum < b.lnum end)
  return out
end

local function resolve_one(item, from_abs)
  local candidate
  if item.kind == 'virtual' then
    local root = virtual_root_for(from_abs)
    if not root then return nil end
    candidate = norm(root .. '/' .. item.path_text)
  else
    candidate = norm(vim.fs.dirname(from_abs) .. '/' .. item.path_text)
  end
  local stat = vim.uv.fs_stat(candidate)
  return (stat and stat.type == 'file') and candidate or nil
end

---@param abs_path string|nil ruta en disco (nil si se pasa bufnr)
---@param bufnr integer|nil buffer cuyo contenido usar en lugar del disco
---@return table[] lista {kind, path_text, resolved, lnum, col, end_col}
function M.includes_of(abs_path, bufnr)
  local ok, items = pcall(function()
    local root_node, source
    if bufnr then
      local parser = vim.treesitter.get_parser(bufnr, 'aspclassic')
      root_node = parser:parse()[1]:root()
      source = bufnr
      abs_path = norm(vim.api.nvim_buf_get_name(bufnr))
    else
      local f = io.open(abs_path, 'r')
      if not f then return {} end
      local content = f:read('*a')
      f:close()
      local parser = vim.treesitter.get_string_parser(content, 'aspclassic')
      root_node = parser:parse()[1]:root()
      source = content
    end
    local out = extract(root_node, source)
    for _, item in ipairs(out) do
      item.resolved = resolve_one(item, abs_path)
    end
    return out
  end)
  return ok and items or {}
end

local function walk(abs, visited, g, is_start, bufnr)
  visited[abs] = true
  local items = M.includes_of(is_start and bufnr and nil or abs,
    is_start and bufnr or nil)
  for _, item in ipairs(items) do
    if not item.resolved then
      table.insert(g.unresolved, {
        text = item.path_text, kind = item.kind, from = abs,
        lnum = item.lnum, col = item.col, end_col = item.end_col,
      })
    elseif visited[item.resolved] then
      table.insert(g.cycles, { from = abs, to = item.resolved })
    else
      table.insert(g.order, item.resolved)
      walk(item.resolved, visited, g, false, nil)
    end
  end
end

---@param abs_path string
function M.graph(abs_path)
  abs_path = norm(abs_path)
  local g = { order = {}, unresolved = {}, cycles = {} }
  walk(abs_path, {}, g, true, nil)
  return g
end

---@param bufnr integer
function M.buffer_graph(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local abs = norm(vim.api.nvim_buf_get_name(bufnr))
  local g = { order = {}, unresolved = {}, cycles = {} }
  local visited = {}
  visited[abs] = true
  local items = M.includes_of(nil, bufnr)
  for _, item in ipairs(items) do
    if not item.resolved then
      table.insert(g.unresolved, {
        text = item.path_text, kind = item.kind, from = abs,
        lnum = item.lnum, col = item.col, end_col = item.end_col,
      })
    elseif visited[item.resolved] then
      table.insert(g.cycles, { from = abs, to = item.resolved })
    else
      table.insert(g.order, item.resolved)
      -- los incluidos siempre se leen de disco
      local sub = { order = g.order, unresolved = g.unresolved, cycles = g.cycles }
      walk_from_disk(item.resolved, visited, sub)
    end
  end
  return g
end
```

Nota de implementación: el par `walk`/`buffer_graph` de arriba tiene una asimetría deliberada (el archivo inicial puede venir de buffer; los incluidos SIEMPRE de disco). Al implementar, unificar en una sola función auxiliar `walk_from_disk(abs, visited, g)` (recorre disco puro, usada por ambos) y dejar `graph`/`buffer_graph` como wrappers que procesan el primer nivel — el esqueleto de arriba muestra la estructura; el implementador debe eliminar la duplicación entre ambos wrappers extrayendo el bloque `for _, item in ipairs(items)` común a una función local `process_items(items, from_abs, visited, g)`. Los tests del Step 1 son el contrato.

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS — 4 specs nuevos + suite previa.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/includes.lua tests/spec/includes_spec.lua
git commit -m "feat(includes): grafo de includes con rutas file/virtual, ciclos e irresolubles"
```

---

### Task 2: symbols.collect_file — indexación desde disco parseando solo la capa vbscript

**Files:**
- Modify: `lua/asp/symbols.lua`
- Test: `tests/spec/symbols_spec.lua` (specs nuevos)

**Interfaces:**
- Consumes: la query/`extract` interna de `collect` (Fase 3) — refactorizar lo mínimo para compartir el recorrido de matches entre fuente-buffer y fuente-string.
- Produces: `require('asp.symbols').collect_file(abs_path)` → misma forma de entrada que `collect` MÁS `file = abs_path`; caché interna por ruta invalidada por mtime; `require('asp.symbols').invalidate(abs_path)` la limpia (la usará el autocmd de la Task 5). Tasks 3-4 consumen `collect_file`.

- [ ] **Step 1: Tests que fallan**

Añadir a `tests/spec/symbols_spec.lua`:

```lua
  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

  it('collect_file extrae símbolos de un archivo en disco', function()
    local entries = require('asp.symbols').collect_file(FIX .. '/includes/helpers.asp')
    local names = {}
    for _, e in ipairs(entries) do names[e.name] = e end
    assert.are.equal(12, names['FormatearMoneda'].kind)
    assert.are.equal(12, names['RespuestaRapida'].kind)
    assert.are.equal(FIX .. '/includes/helpers.asp', names['FormatearMoneda'].file)
    assert.is_nil(names['FormatearMoneda'].scope_id)
  end)

  it('collect_file extrae consts y dims de un .inc', function()
    local entries = require('asp.symbols').collect_file(FIX .. '/includes/constantes.inc')
    local names = {}
    for _, e in ipairs(entries) do names[e.name] = e end
    assert.are.equal(14, names['IVA'].kind)
    assert.are.equal(13, names['gConexion'].kind)
  end)

  it('collect_file cachea por mtime', function()
    local symbols = require('asp.symbols')
    local path = FIX .. '/lib/db.inc'
    local a = symbols.collect_file(path)
    local b = symbols.collect_file(path)
    assert.are.equal(a, b) -- misma tabla = cache hit
    symbols.invalidate(path)
    local c = symbols.collect_file(path)
    assert.are_not.equal(a, c)
    assert.are.equal(#a, #c)
  end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — `collect_file` no existe.

- [ ] **Step 3: Implementar**

En `lua/asp/symbols.lua`: extraer del cuerpo de `M.collect` el recorrido de matches a una función local `collect_from_roots(roots, source)` (recibe lista de root nodes vbscript y la fuente bufnr|string, devuelve entries — el código existente del loop `for _, tree in ipairs(child:trees())` pasa a iterar `roots`). `M.collect` queda como wrapper que obtiene los roots del parser del buffer. Añadir:

```lua
local CODE_QUERY = [[ (code) @code ]]

local file_cache = {}

local function mtime_of(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. ':' .. st.mtime.nsec) or nil
end

---@param abs_path string
function M.invalidate(abs_path)
  file_cache[vim.fs.normalize(abs_path)] = nil
end

---@param abs_path string
---@return table[] entries (con campo file)
function M.collect_file(abs_path)
  abs_path = vim.fs.normalize(abs_path)
  local mt = mtime_of(abs_path)
  if not mt then return {} end
  local hit = file_cache[abs_path]
  if hit and hit.mtime == mt then return hit.entries end

  local ok, entries = pcall(function()
    local f = assert(io.open(abs_path, 'r'))
    local content = f:read('*a')
    f:close()

    -- Capa plantilla: solo top layer, sin injections (barato).
    local tpl = vim.treesitter.get_string_parser(content, 'aspclassic')
    local troot = tpl:parse()[1]:root()
    local cq = vim.treesitter.query.parse('aspclassic', CODE_QUERY)
    local code_nodes = {}
    for _, node in cq:iter_captures(troot, content) do
      table.insert(code_nodes, node)
    end
    if #code_nodes == 0 then return {} end

    -- Capa vbscript SOLO en los rangos de código: nada de html/js/regex.
    local vp = vim.treesitter.get_string_parser(content, 'vbscript')
    vp:set_included_ranges(code_nodes)
    local vroot = vp:parse()[1]:root()

    local out = collect_from_roots({ vroot }, content)
    for _, e in ipairs(out) do
      e.file = abs_path
    end
    return out
  end)
  entries = ok and entries or {}
  file_cache[abs_path] = { mtime = mt, entries = entries }
  return entries
end
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS (3 specs nuevos; los specs previos de `collect` intactos — el refactor no cambia comportamiento).

- [ ] **Step 5: Commit**

```bash
git add lua/asp/symbols.lua tests/spec/symbols_spec.lua
git commit -m "feat(symbols): collect_file desde disco parseando solo la capa vbscript, con caché mtime"
```

---

### Task 3: definition cross-file

**Files:**
- Modify: `lua/asp/symbols.lua` (función `definition`, tier nuevo)
- Test: `tests/spec/lsp_spec.lua` (describe nuevo)

**Interfaces:**
- Consumes: `includes.buffer_graph(bufnr)` (Task 1), `symbols.collect_file` (Task 2), tiers in-file de Fase 3.
- Produces: `definition` devuelve Locations con `uri` de OTROS archivos cuando el símbolo vive en un include (solo símbolos de página: `scope_id == nil` y `class_id == nil`). Sin cambios de firma.

- [ ] **Step 1: Specs que fallan**

Añadir a `tests/spec/lsp_spec.lua` un `describe` nuevo (no reusar el before_each del fixture symbols.asp):

```lua
describe('asp-ls cross-file', function()
  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

  before_each(function()
    vim.cmd.edit(FIX .. '/default.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 5000)
    for _, r in pairs(resp or {}) do return r.result end
  end

  local function pos_of(text)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      local col = line:find(text, 1, true)
      if col then return { line = i - 1, character = col - 1 } end
    end
    error('texto no encontrado: ' .. text)
  end

  local function definition_at(pos)
    return request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos,
    })
  end

  it('salta a una Function definida en un include file', function()
    local loc = definition_at(pos_of('FormatearMoneda'))
    assert.is_not_nil(loc)
    assert.is_truthy(loc.uri:find('includes/helpers%.asp$'))
  end)

  it('salta a una Const definida en un include anidado', function()
    local loc = definition_at(pos_of('IVA'))
    assert.is_truthy(loc.uri:find('includes/constantes%.inc$'))
  end)

  it('salta a una Function de un include virtual', function()
    local loc = definition_at(pos_of('AbrirConexion'))
    assert.is_truthy(loc.uri:find('lib/db%.inc$'))
  end)

  it('cross-file es case-insensitive', function()
    local loc = definition_at(pos_of('respuestarapida'))
    assert.is_truthy(loc.uri:find('includes/helpers%.asp$'))
  end)

  it('sobrevive a un grafo con ciclo', function()
    vim.cmd('bwipeout!')
    vim.cmd.edit(FIX .. '/ciclo_a.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
    local loc = definition_at(pos_of('FuncionB()'))
    assert.is_truthy(loc.uri:find('ciclo_b%.asp$'))
  end)
end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — los 5 specs devuelven nil (no hay tier cross-file).

- [ ] **Step 3: Implementar**

En `lua/asp/symbols.lua`, dentro de `M.definition`, tras calcular `best` con los tiers in-file y **solo si `best == nil`**:

```lua
  if not best then
    local graph = require('asp.includes').buffer_graph(bufnr)
    for _, file in ipairs(graph.order) do
      for _, e in ipairs(M.collect_file(file)) do
        if e.name:lower() == wanted and not e.scope_id and not e.class_id then
          return {
            uri = vim.uri_from_fname(e.file),
            range = {
              start = { line = e.selection[1], character = e.selection[2] },
              ['end'] = { line = e.selection[3], character = e.selection[4] },
            },
          }
        end
      end
    end
    return nil
  end
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/symbols.lua tests/spec/lsp_spec.lua
git commit -m "feat(lsp): definition cross-file a través del grafo de includes"
```

---

### Task 4: references y workspace/symbol

**Files:**
- Modify: `lua/asp/symbols.lua` (funciones `references` y `workspace_symbols`)
- Modify: `lua/asp/lsp.lua` (2 handlers + capabilities)
- Test: `tests/spec/lsp_spec.lua` (specs en el describe cross-file)

**Interfaces:**
- Consumes: `includes.buffer_graph`, `collect_file`, y un escaneo de ocurrencias `(identifier)` por archivo.
- Produces: `symbols.references(bufnr, position)` → `Location[]`; `symbols.workspace_symbols(query_str, root_dir)` → `SymbolInformation[]` (`{name, kind, location}`). Handlers `textDocument/references` y `workspace/symbol`; capabilities `referencesProvider = true`, `workspaceSymbolProvider = true`.

- [ ] **Step 1: Specs que fallan**

Añadir al describe `asp-ls cross-file`:

```lua
  it('references encuentra usos y definición en todo el grafo', function()
    local refs = request('textDocument/references', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos_of('FormatearMoneda'),
      context = { includeDeclaration = true },
    })
    -- default.asp: 1 uso; helpers.asp: nombre en Function + asignación de retorno
    assert.are.equal(3, #refs)
    local files = {}
    for _, r in ipairs(refs) do
      files[r.uri:match('([^/]+)$')] = (files[r.uri:match('([^/]+)$')] or 0) + 1
    end
    assert.are.equal(1, files['default.asp'])
    assert.are.equal(2, files['helpers.asp'])
  end)

  it('workspace/symbol busca case-insensitive en todo el proyecto', function()
    local syms = request('workspace/symbol', { query = 'funcion' })
    local names = {}
    for _, s in ipairs(syms) do names[s.name] = s end
    assert.is_not_nil(names['FuncionA'])
    assert.is_not_nil(names['FuncionB'])
    assert.is_truthy(names['FuncionA'].location.uri:find('ciclo_a%.asp$'))
  end)
```

Nota: el `root_dir` del cliente en estos specs es la raíz del repo (cwd), así que `workspace/symbol` debe encontrar los fixtures bajo `tests/fixtures/proyecto/`; el escaneo debe excluir los directorios `build/`, `parser/` y `grammars/` para no perder tiempo.

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — handlers no registrados (result nil).

- [ ] **Step 3: Implementar**

En `lua/asp/symbols.lua`:

```lua
local IDENT_QUERY = [[ (identifier) @id ]]

-- Ocurrencias case-insensitive de `wanted` en un archivo de disco
-- (misma técnica de collect_file: solo capa vbscript).
local function occurrences_in_file(abs_path, wanted)
  local out = {}
  local ok = pcall(function()
    local f = assert(io.open(abs_path, 'r'))
    local content = f:read('*a')
    f:close()
    local tpl = vim.treesitter.get_string_parser(content, 'aspclassic')
    local troot = tpl:parse()[1]:root()
    local cq = vim.treesitter.query.parse('aspclassic', [[ (code) @code ]])
    local code_nodes = {}
    for _, node in cq:iter_captures(troot, content) do
      table.insert(code_nodes, node)
    end
    if #code_nodes == 0 then return end
    local vp = vim.treesitter.get_string_parser(content, 'vbscript')
    vp:set_included_ranges(code_nodes)
    local vroot = vp:parse()[1]:root()
    local iq = vim.treesitter.query.parse('vbscript', IDENT_QUERY)
    for _, node in iq:iter_captures(vroot, content) do
      if vim.treesitter.get_node_text(node, content):lower() == wanted then
        local r0, c0, r1, c1 = node:range()
        table.insert(out, {
          uri = vim.uri_from_fname(abs_path),
          range = {
            start = { line = r0, character = c0 },
            ['end'] = { line = r1, character = c1 },
          },
        })
      end
    end
  end)
  return ok and out or {}
end

---@param bufnr integer
---@param position table
---@return table[] Location[]
function M.references(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local node = -- mismo lookup confinado a la capa vbscript que usa
  -- M.definition (extraer ese bloque a una función local
  -- `identifier_at(bufnr, position)` y reutilizarla en ambos)
  identifier_at(bufnr, position)
  if not node then return {} end
  local wanted = vim.treesitter.get_node_text(node, bufnr):lower()

  local out = {}
  -- buffer actual: ocurrencias sobre sus árboles vbscript ya parseados
  local parser = vim.treesitter.get_parser(bufnr)
  parser:parse(true)
  local child = parser:children().vbscript
  if child then
    local iq = vim.treesitter.query.parse('vbscript', IDENT_QUERY)
    for _, tree in ipairs(child:trees()) do
      for _, n in iq:iter_captures(tree:root(), bufnr) do
        if vim.treesitter.get_node_text(n, bufnr):lower() == wanted then
          local r0, c0, r1, c1 = n:range()
          table.insert(out, {
            uri = vim.uri_from_bufnr(bufnr),
            range = {
              start = { line = r0, character = c0 },
              ['end'] = { line = r1, character = c1 },
            },
          })
        end
      end
    end
  end
  for _, file in ipairs(require('asp.includes').buffer_graph(bufnr).order) do
    vim.list_extend(out, occurrences_in_file(file, wanted))
  end
  return out
end

---@param query_str string
---@param root_dir string
---@return table[] SymbolInformation[]
function M.workspace_symbols(query_str, root_dir)
  local q = (query_str or ''):lower()
  local files = vim.fs.find(function(name, path)
    if path:find('/build/') or path:find('/parser/') or path:find('/grammars/') then
      return false
    end
    return name:match('%.asp$') ~= nil or name:match('%.inc$') ~= nil
  end, { path = root_dir, type = 'file', limit = math.huge })

  local out = {}
  for _, file in ipairs(files) do
    for _, e in ipairs(M.collect_file(file)) do
      if q == '' or e.name:lower():find(q, 1, true) then
        table.insert(out, {
          name = e.name,
          kind = e.kind,
          location = {
            uri = vim.uri_from_fname(e.file),
            range = {
              start = { line = e.selection[1], character = e.selection[2] },
              ['end'] = { line = e.selection[3], character = e.selection[4] },
            },
          },
        })
      end
    end
  end
  return out
end
```

(El comentario dentro de `M.references` es una instrucción: el bloque de `M.definition` que localiza el `identifier` bajo el cursor confinado a la capa vbscript se extrae a una local `identifier_at(bufnr, position)` reutilizada por ambos — no duplicarlo.)

En `lua/asp/lsp.lua`: añadir a capabilities `referencesProvider = true, workspaceSymbolProvider = true`, y los handlers:

```lua
M.handlers['textDocument/references'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.symbols').references(bufnr, params.position)
end

M.handlers['workspace/symbol'] = function(params)
  local client = vim.lsp.get_clients({ name = 'asp-ls' })[1]
  local root = client and client.config.root_dir or vim.fn.getcwd()
  return require('asp.symbols').workspace_symbols(params.query, root)
end
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/symbols.lua lua/asp/lsp.lua tests/spec/lsp_spec.lua
git commit -m "feat(lsp): references y workspace/symbol sobre el grafo de includes"
```

---

### Task 5: Diagnósticos de includes y cierre de fase

**Files:**
- Create: `lua/asp/diagnostics.lua`
- Modify: `plugin/asp.lua` (autocmds)
- Modify: `lua/asp/health.lua` (línea de diagnósticos)
- Modify: `README.md`
- Test: `tests/spec/diagnostics_spec.lua`

**Interfaces:**
- Consumes: `includes.buffer_graph`; `symbols.invalidate`.
- Produces: namespace `asp_includes` con WARNs; autocmds de refresco; cierre de Fase 4.

- [ ] **Step 1: Tests que fallan**

`tests/spec/diagnostics_spec.lua`:

```lua
local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

describe('diagnósticos de includes', function()
  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function diags_for(file)
    vim.cmd.edit(FIX .. '/' .. file)
    require('asp.diagnostics').refresh(0)
    return vim.diagnostic.get(0, { namespace = require('asp.diagnostics').ns })
  end

  it('marca includes irresolubles con WARN en su línea', function()
    local ds = diags_for('roto.asp')
    assert.are.equal(2, #ds)
    assert.are.equal(vim.diagnostic.severity.WARN, ds[1].severity)
    assert.are.equal(0, ds[1].lnum)
    assert.are.equal(1, ds[2].lnum)
    assert.is_truthy(ds[1].message:find('no_existe%.inc'))
  end)

  it('reporta ciclos con un WARN', function()
    local ds = diags_for('ciclo_a.asp')
    assert.are.equal(1, #ds)
    assert.is_truthy(ds[1].message:lower():find('ciclo'))
  end)

  it('un grafo sano no produce diagnósticos', function()
    local ds = diags_for('default.asp')
    assert.are.same({}, ds)
  end)
end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — `module 'asp.diagnostics' not found`.

- [ ] **Step 3: Implementar**

`lua/asp/diagnostics.lua`:

```lua
local M = {}

M.ns = vim.api.nvim_create_namespace('asp_includes')

---@param bufnr integer
function M.refresh(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local ok, g = pcall(require('asp.includes').buffer_graph, bufnr)
  if not ok then return end
  local diags = {}
  for _, u in ipairs(g.unresolved) do
    table.insert(diags, {
      lnum = u.lnum, col = u.col, end_col = u.end_col,
      severity = vim.diagnostic.severity.WARN,
      source = 'asp-ls',
      message = ('include %s="%s" no resuelve a ningún archivo'):format(u.kind, u.text),
    })
  end
  for _, c in ipairs(g.cycles) do
    table.insert(diags, {
      lnum = 0, col = 0,
      severity = vim.diagnostic.severity.WARN,
      source = 'asp-ls',
      message = ('ciclo de includes detectado: %s vuelve a incluir %s'):format(
        vim.fs.basename(c.from), vim.fs.basename(c.to)),
    })
  end
  vim.diagnostic.set(M.ns, bufnr, diags)
end

return M
```

En `plugin/asp.lua`, dentro del callback FileType existente, tras el arranque del LSP:

```lua
    vim.schedule(function()
      pcall(function()
        require('asp.diagnostics').refresh(args.buf)
      end)
    end)
```

y un autocmd nuevo en el mismo augroup:

```lua
vim.api.nvim_create_autocmd('BufWritePost', {
  pattern = { '*.asp', '*.inc' },
  group = vim.api.nvim_create_augroup('asp_nvim_writes', { clear = true }),
  callback = function(args)
    pcall(function()
      require('asp.symbols').invalidate(vim.api.nvim_buf_get_name(args.buf))
      if vim.bo[args.buf].filetype == 'asp' then
        require('asp.diagnostics').refresh(args.buf)
      end
    end)
  end,
})
```

En `lua/asp/health.lua`, tras la línea de asp-ls:

```lua
  health.ok('diagnósticos de includes activos (namespace asp_includes)')
```

En `README.md`, actualizar la sección de navegación: título a `## Navegación (Fases 3-4)`, y reemplazar la línea final ("La resolución a través de `<!--#include -->` llega en la Fase 4.") por:

```markdown
- **Cross-file**: definición y referencias siguen los
  `<!--#include file/virtual="..."-->` (recursivo, ciclos tolerados);
  `vim.lsp.buf.workspace_symbol()` busca en todo el proyecto.
- **Diagnósticos**: los includes que no resuelven se marcan con un
  warning en su línea. La raíz de los includes `virtual=` se autodetecta
  (`web.config` o `.git`) y puede fijarse con
  `require('asp').setup({ virtual_root = '/ruta/al/sitio' })`.
```

- [ ] **Step 4: Verificación completa y cierre**

Run: `make clean && make test`
Expected: PASS total.

Verificación programática de cierre (pegar resultados en el reporte):
1. Headless sobre `tests/fixtures/proyecto/default.asp`: definition de `FormatearMoneda`, `IVA` y `AbrirConexion` aterrizando en sus archivos; references de `FormatearMoneda` = 3; workspace/symbol 'funcion' = 2.
2. Con los `asp/*.asp` propietarios (local, sin commitear): abrir cada uno, `require('asp.diagnostics').refresh(0)` → 0 diagnósticos falsos (no tienen includes); documentSymbol sigue funcionando (conteos > 0, sin regresión).
3. `:checkhealth asp` → líneas de asp-ls y diagnósticos presentes.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/diagnostics.lua plugin/asp.lua lua/asp/health.lua README.md tests/spec/diagnostics_spec.lua
git commit -m "feat: diagnósticos de includes y cierre de Fase 4"
```
