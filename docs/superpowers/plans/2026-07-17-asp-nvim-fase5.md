# asp.nvim — Fase 5: hover/completion de intrínsecos, :help, CI y publicación — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cerrar el plugin para publicación: hover y completion de los objetos intrínsecos de ASP (`Response`, `Request`, `Server`, `Session`, `Application`) y de los símbolos del proyecto, documentación `:help`, CI en GitHub Actions, y un README/health listos para v0.5.

**Architecture:** Un módulo de datos puro `lua/asp/intrinsics.lua` (tabla de objetos intrínsecos y sus miembros con firma y doc, más lookups case-insensitive). Dos módulos de comportamiento delgados: `lua/asp/hover.lua` (resuelve el identificador bajo el cursor a doc de intrínseco o firma de símbolo de usuario) y `lua/asp/completion.lua` (miembros tras `Objeto.` o símbolos del grafo). Se registran como handlers `textDocument/hover` y `textDocument/completion` en el servidor `asp-ls` existente y se anuncian en capabilities. Cierre: `doc/asp.txt` (`:help asp`), workflow de GitHub Actions, y bump de versión/README.

**Tech Stack:** Lua (Neovim ≥0.10, validado 0.12), gramática vbscript (Fase 2), plenary, GitHub Actions.

## Global Constraints

- Objetos intrínsecos cubiertos (spec, fila hover/completion): **Response, Request, Server, Session, Application**.
- Comparación case-insensitive en TODO (nombres de objeto y de miembro) — VBScript.
- Handlers JAMÁS lanzan (el dispatch de `lua/asp/lsp.lua` ya envuelve en pcall y responde `-32603`; aun así cada handler retorna `nil`/`{}` en vez de propagar).
- Detección de miembro: `member_expression` = `primary_expression (identifier)` [objeto] seguido de `identifier` [miembro] (verificado). Para completion, el input puede estar incompleto (`Response.` sin miembro aún) → usar el TEXTO de la línea hasta el cursor con patrón `([%w_]+)%.([%w_]*)$`, NO el árbol (que no parsea input parcial).
- Reutilizar la maquinaria de Fase 3-4: `require('asp.symbols').definition/collect/collect_file`, `require('asp.includes').buffer_graph`; NO duplicar el lookup de nodo confinado a la capa vbscript.
- `bump` de `serverInfo.version` a `'0.5.0'` en `lua/asp/lsp.lua` (hoy `'0.3.0'`).
- Suite previa completa verde en cada task (`make clean && make test`); no hardcodear conteos globales.
- Los `asp/*.asp` propietarios: solo verificación local, nunca commiteados.

---

### Task 1: Módulo de datos de intrínsecos

**Files:**
- Create: `lua/asp/intrinsics.lua`
- Test: `tests/spec/intrinsics_spec.lua`

**Interfaces:**
- Consumes: nada.
- Produces: `require('asp.intrinsics').object(name)` → `{ name=string, doc=string, members=table }|nil` (case-insensitive); `.member(obj_name, member_name)` → `{ name=string, signature=string, doc=string }|nil` (case-insensitive); `.object_names()` → lista de nombres canónicos (`{'Response','Request',...}`); `.members_of(obj_name)` → lista de member tables o `{}`. Tasks 2-3 consumen esto.

- [ ] **Step 1: Tests que fallan**

`tests/spec/intrinsics_spec.lua`:

```lua
describe('asp.intrinsics', function()
  local I = nil
  before_each(function() I = require('asp.intrinsics') end)

  it('resuelve objetos case-insensitive', function()
    assert.are.equal('Response', I.object('response').name)
    assert.are.equal('Server', I.object('SERVER').name)
    assert.is_nil(I.object('NoExiste'))
  end)

  it('cada objeto tiene doc no vacío', function()
    for _, name in ipairs(I.object_names()) do
      assert.is_true(#I.object(name).doc > 0, 'sin doc: ' .. name)
    end
  end)

  it('resuelve miembros case-insensitive con firma y doc', function()
    local m = I.member('Response', 'write')
    assert.are.equal('Write', m.name)
    assert.is_true(m.signature:find('Write') ~= nil)
    assert.is_true(#m.doc > 0)
    assert.is_nil(I.member('Response', 'NoExiste'))
  end)

  it('expone los 5 objetos del spec', function()
    local names = I.object_names()
    table.sort(names)
    assert.are.same(
      { 'Application', 'Request', 'Response', 'Server', 'Session' }, names)
  end)

  it('members_of devuelve la lista o vacío', function()
    assert.is_true(#I.members_of('Server') >= 3)
    assert.are.same({}, I.members_of('NoExiste'))
  end)
end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — `module 'asp.intrinsics' not found`.

- [ ] **Step 3: Implementar**

`lua/asp/intrinsics.lua`:

```lua
local M = {}

-- Datos de los objetos intrínsecos de Classic ASP. Firmas y descripciones
-- basadas en la documentación pública de ASP (dominio de conocimiento común).
local DATA = {
  Response = {
    doc = 'Envía la salida al cliente (cabeceras, cuerpo, cookies).',
    members = {
      { 'Write', 'Response.Write(variant)', 'Escribe una cadena en la respuesta HTTP.' },
      { 'Redirect', 'Response.Redirect(url)', 'Redirige al cliente a otra URL.' },
      { 'End', 'Response.End()', 'Detiene el procesamiento y envía lo ya bufferizado.' },
      { 'Clear', 'Response.Clear()', 'Borra el buffer de respuesta (sin cabeceras).' },
      { 'Flush', 'Response.Flush()', 'Envía el buffer actual inmediatamente.' },
      { 'Buffer', 'Response.Buffer [= bool]', 'Controla si la respuesta se bufferiza.' },
      { 'ContentType', 'Response.ContentType [= string]', 'Tipo MIME de la respuesta.' },
      { 'Expires', 'Response.Expires [= minutos]', 'Minutos hasta que la página caduque en caché.' },
      { 'ExpiresAbsolute', 'Response.ExpiresAbsolute [= fecha]', 'Fecha/hora absoluta de caducidad.' },
      { 'AddHeader', 'Response.AddHeader(nombre, valor)', 'Agrega una cabecera HTTP.' },
      { 'Cookies', 'Response.Cookies(nombre)', 'Colección de cookies de salida.' },
      { 'Status', 'Response.Status [= string]', 'Línea de estado HTTP (ej. "404 Not Found").' },
      { 'CacheControl', 'Response.CacheControl [= string]', 'Cabecera Cache-Control.' },
      { 'BinaryWrite', 'Response.BinaryWrite(datos)', 'Escribe datos binarios sin conversión.' },
    },
  },
  Request = {
    doc = 'Accede a los datos enviados por el cliente en la petición HTTP.',
    members = {
      { 'QueryString', 'Request.QueryString(clave)', 'Valores de la cadena de consulta (GET).' },
      { 'Form', 'Request.Form(clave)', 'Valores enviados por POST.' },
      { 'ServerVariables', 'Request.ServerVariables(nombre)', 'Variables de servidor/entorno.' },
      { 'Cookies', 'Request.Cookies(nombre)', 'Cookies enviadas por el cliente.' },
      { 'TotalBytes', 'Request.TotalBytes', 'Bytes totales del cuerpo de la petición.' },
      { 'BinaryRead', 'Request.BinaryRead(cuenta)', 'Lee datos binarios del cuerpo POST.' },
      { 'ClientCertificate', 'Request.ClientCertificate(clave)', 'Campos del certificado de cliente.' },
    },
  },
  Server = {
    doc = 'Utilidades del servidor: creación de objetos, rutas y codificación.',
    members = {
      { 'CreateObject', 'Server.CreateObject(progID)', 'Instancia un componente COM por su ProgID.' },
      { 'MapPath', 'Server.MapPath(ruta)', 'Convierte una ruta virtual en física.' },
      { 'HTMLEncode', 'Server.HTMLEncode(string)', 'Escapa caracteres HTML.' },
      { 'URLEncode', 'Server.URLEncode(string)', 'Codifica una cadena para URL.' },
      { 'Execute', 'Server.Execute(ruta)', 'Ejecuta otra página ASP y vuelve.' },
      { 'Transfer', 'Server.Transfer(ruta)', 'Transfiere la ejecución a otra página.' },
      { 'ScriptTimeout', 'Server.ScriptTimeout [= segundos]', 'Tiempo máximo de ejecución del script.' },
      { 'GetLastError', 'Server.GetLastError()', 'Devuelve el objeto ASPError del último error.' },
    },
  },
  Session = {
    doc = 'Estado por usuario, persistente entre peticiones de una sesión.',
    members = {
      { 'SessionID', 'Session.SessionID', 'Identificador único de la sesión.' },
      { 'Timeout', 'Session.Timeout [= minutos]', 'Minutos de inactividad antes de expirar.' },
      { 'Abandon', 'Session.Abandon()', 'Destruye la sesión al terminar la petición.' },
      { 'Contents', 'Session.Contents(clave)', 'Colección de variables de sesión.' },
      { 'StaticObjects', 'Session.StaticObjects(clave)', 'Objetos declarados con <object> scope=session.' },
      { 'CodePage', 'Session.CodePage [= entero]', 'Página de códigos para la sesión.' },
      { 'LCID', 'Session.LCID [= entero]', 'Identificador de configuración regional.' },
    },
  },
  Application = {
    doc = 'Estado compartido por todos los usuarios de la aplicación.',
    members = {
      { 'Contents', 'Application.Contents(clave)', 'Colección de variables de aplicación.' },
      { 'StaticObjects', 'Application.StaticObjects(clave)', 'Objetos <object> scope=application.' },
      { 'Lock', 'Application.Lock()', 'Bloquea el objeto Application para escritura segura.' },
      { 'Unlock', 'Application.Unlock()', 'Libera el bloqueo de Application.' },
    },
  },
}

-- Índice interno normalizado: lowercase → objeto con members indexados.
local index = {}
for name, obj in pairs(DATA) do
  local members_by_key = {}
  local members_list = {}
  for _, m in ipairs(obj.members) do
    local entry = { name = m[1], signature = m[2], doc = m[3] }
    members_by_key[m[1]:lower()] = entry
    table.insert(members_list, entry)
  end
  index[name:lower()] = {
    name = name, doc = obj.doc,
    members = members_by_key, members_list = members_list,
  }
end

---@param name string
---@return table|nil
function M.object(name)
  if type(name) ~= 'string' then return nil end
  return index[name:lower()]
end

---@param obj_name string
---@param member_name string
---@return table|nil
function M.member(obj_name, member_name)
  local obj = M.object(obj_name)
  if not obj or type(member_name) ~= 'string' then return nil end
  return obj.members[member_name:lower()]
end

---@return string[]
function M.object_names()
  local out = {}
  for _, obj in pairs(index) do table.insert(out, obj.name) end
  return out
end

---@param obj_name string
---@return table[]
function M.members_of(obj_name)
  local obj = M.object(obj_name)
  return obj and obj.members_list or {}
end

return M
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS (5 specs nuevos + suite previa).

- [ ] **Step 5: Commit**

```bash
git add lua/asp/intrinsics.lua tests/spec/intrinsics_spec.lua
git commit -m "feat(intrinsics): datos de los objetos intrínsecos de ASP"
```

---

### Task 2: textDocument/hover

**Files:**
- Create: `lua/asp/hover.lua`
- Modify: `lua/asp/lsp.lua` (handler + capability)
- Test: `tests/spec/lsp_spec.lua` (describe nuevo)

**Interfaces:**
- Consumes: `asp.intrinsics` (Task 1); `asp.symbols` (`collect`) — para la firma de símbolos de usuario in-file.
- Produces: `require('asp.hover').hover(bufnr, position)` → `{ contents = { kind = 'markdown', value = string } }|nil`. Handler `textDocument/hover`; capability `hoverProvider = true`.

- [ ] **Step 1: Specs que fallan**

Añadir a `tests/spec/lsp_spec.lua` un `describe` nuevo:

```lua
describe('asp-ls hover', function()
  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')

  before_each(function()
    vim.cmd.edit(FIX .. '/default.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)
  after_each(function() vim.cmd('bwipeout!') end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do return r.result end
  end
  local function pos_of(text)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      local c = line:find(text, 1, true)
      if c then return { line = i - 1, character = c - 1 } end
    end
    error('no encontrado: ' .. text)
  end
  local function hover_at(pos)
    return request('textDocument/hover', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos,
    })
  end

  it('hover sobre un objeto intrínseco (Response)', function()
    local h = hover_at(pos_of('Response'))
    assert.is_not_nil(h)
    assert.are.equal('markdown', h.contents.kind)
    assert.is_true(h.contents.value:find('Response') ~= nil)
  end)

  it('hover sobre un miembro intrínseco (Server.CreateObject)', function()
    local p = pos_of('CreateObject')
    local h = hover_at(p)
    assert.is_true(h.contents.value:find('CreateObject') ~= nil)
    assert.is_true(h.contents.value:find('ProgID') ~= nil)
  end)

  it('hover sobre un símbolo de usuario muestra su declaración', function()
    -- default.asp usa FormatearMoneda (definido en include); en el buffer
    -- actual hay 'totalPagina' (Dim de página) — hover muestra su línea.
    local h = hover_at(pos_of('totalPagina'))
    assert.is_not_nil(h)
    assert.is_true(h.contents.value:lower():find('totalpagina') ~= nil)
  end)

  it('hover sobre algo desconocido devuelve nil', function()
    local h = hover_at(pos_of('<html>'))
    assert.is_nil(h)
  end)
end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — handler inexistente, `h` nil.

- [ ] **Step 3: Implementar**

`lua/asp/hover.lua`:

```lua
local M = {}

local intrinsics = require('asp.intrinsics')

-- Nodo identifier bajo el cursor, confinado a la capa vbscript.
-- (misma técnica que asp.symbols; se reimplementa mínima aquí para no
-- exportar internals — es un lookup de lectura, barato.)
local function node_at(bufnr, position)
  local pok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not pok or not parser then return nil end
  parser:parse(true)
  local vbscript = parser:children().vbscript
  if not vbscript then return nil end
  for _, tree in ipairs(vbscript:trees()) do
    local root = tree:root()
    local sr, _, er = root:range()
    if position.line >= sr and position.line <= er then
      return root:named_descendant_for_range(
        position.line, position.character, position.line, position.character)
    end
  end
  return nil
end

local function md(value)
  return { contents = { kind = 'markdown', value = value } }
end

-- ¿El nodo es el MIEMBRO de un member_expression? Devuelve el texto del
-- objeto (primary_expression.identifier) si lo es.
local function object_of_member(node, bufnr)
  local parent = node:parent()
  if not parent or parent:type() ~= 'member_expression' then return nil end
  -- primer hijo con nombre: primary_expression que envuelve el objeto
  local obj = parent:named_child(0)
  if not obj then return nil end
  if obj:type() == 'primary_expression' then obj = obj:named_child(0) end
  if not obj or obj:type() ~= 'identifier' then return nil end
  -- el node debe ser el segundo identifier (miembro), no el objeto
  if obj:id() == node:id() then return nil end
  return vim.treesitter.get_node_text(obj, bufnr)
end

---@param bufnr integer
---@param position table {line, character}
---@return table|nil hover
function M.hover(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local node = node_at(bufnr, position)
  if not node or node:type() ~= 'identifier' then return nil end
  local text = vim.treesitter.get_node_text(node, bufnr)

  -- 1. ¿miembro de un objeto intrínseco?
  local obj_text = object_of_member(node, bufnr)
  if obj_text then
    local m = intrinsics.member(obj_text, text)
    if m then
      return md(('```vbscript\n%s\n```\n\n%s'):format(m.signature, m.doc))
    end
  end

  -- 2. ¿objeto intrínseco?
  local obj = intrinsics.object(text)
  if obj then
    return md(('**%s** (objeto intrínseco ASP)\n\n%s'):format(obj.name, obj.doc))
  end

  -- 3. símbolo de usuario del buffer: mostrar la primera línea de su
  -- declaración.
  local wanted = text:lower()
  for _, e in ipairs(require('asp.symbols').collect(bufnr)) do
    if e.name:lower() == wanted then
      local line = vim.api.nvim_buf_get_lines(bufnr, e.range[1], e.range[1] + 1, false)[1] or ''
      return md(('```vbscript\n%s\n```'):format(vim.trim(line)))
    end
  end
  return nil
end

return M
```

En `lua/asp/lsp.lua`: añadir `hoverProvider = true` a capabilities y el handler:

```lua
M.handlers['textDocument/hover'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.hover').hover(bufnr, params.position)
end
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/hover.lua lua/asp/lsp.lua tests/spec/lsp_spec.lua
git commit -m "feat(lsp): hover de intrínsecos ASP y símbolos de usuario"
```

---

### Task 3: textDocument/completion

**Files:**
- Create: `lua/asp/completion.lua`
- Modify: `lua/asp/lsp.lua` (handler + capability con triggerCharacters)
- Test: `tests/spec/lsp_spec.lua` (describe nuevo)

**Interfaces:**
- Consumes: `asp.intrinsics`; `asp.symbols` (`collect`, `collect_file`); `asp.includes` (`buffer_graph`).
- Produces: `require('asp.completion').complete(bufnr, position)` → `CompletionItem[]`. Handler `textDocument/completion`; capability `completionProvider = { triggerCharacters = { '.' } }`.

- [ ] **Step 1: Specs que fallan**

Añadir a `tests/spec/lsp_spec.lua`:

```lua
describe('asp-ls completion', function()
  local FIX = vim.fn.fnamemodify('tests/fixtures/proyecto', ':p'):gsub('/$', '')
  after_each(function() vim.cmd('bwipeout!') end)

  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do return r.result end
  end

  local function complete_line(text_line)
    -- crea un buffer asp con una sola línea de código y pide completion
    -- al final de la línea
    vim.cmd.edit(FIX .. '/scratch_complete.asp')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '<%', text_line, '%>' })
    vim.bo.filetype = 'asp'
    require('asp.lsp').start(0)
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
    local items = request('textDocument/completion', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = { line = 1, character = #text_line },
    })
    return items and (items.items or items) or {}
  end

  local function labels(items)
    local out = {}
    for _, it in ipairs(items) do out[it.label] = true end
    return out
  end

  it('tras Response. ofrece los miembros del objeto', function()
    local items = complete_line('Response.')
    local l = labels(items)
    assert.is_true(l['Write'], 'esperaba Write')
    assert.is_true(l['Redirect'], 'esperaba Redirect')
    assert.is_nil(l['CreateObject']) -- ese es de Server
  end)

  it('tras Server.Cr filtra por prefijo case-insensitive', function()
    local items = complete_line('Server.cr')
    local l = labels(items)
    assert.is_true(l['CreateObject'])
    assert.is_nil(l['MapPath'])
  end)

  it('sin punto ofrece objetos intrínsecos y símbolos', function()
    local items = complete_line('Res')
    local l = labels(items)
    assert.is_true(l['Response'])
  end)
end)
```

Nota: `scratch_complete.asp` no existe en disco; `vim.cmd.edit` sobre una ruta inexistente crea un buffer nuevo con ese nombre (no se escribe a disco a menos que `:w`). El test no debe escribir el archivo. Si el `edit` de una ruta inexistente incomoda a algún check, usar `vim.cmd('enew')` + `vim.api.nvim_buf_set_name(0, FIX..'/scratch_complete.asp')`.

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — handler inexistente.

- [ ] **Step 3: Implementar**

`lua/asp/completion.lua`:

```lua
local M = {}

local intrinsics = require('asp.intrinsics')

-- CompletionItemKind (LSP): Method=2, Field=5, Function=3, Variable=6,
-- Class=7, Constant=21, Module=9.
local KIND_METHOD = 2
local KIND_MODULE = 9

-- Mapa de SymbolKind (documentSymbol) → CompletionItemKind.
local SYM_TO_COMPL = {
  [5] = 7,   -- Class → Class
  [7] = 3,   -- Property → Function
  [12] = 3,  -- Function → Function
  [13] = 6,  -- Variable → Variable
  [14] = 21, -- Constant → Constant
}

local function item(label, kind, detail, doc)
  return {
    label = label, kind = kind, detail = detail,
    documentation = doc and { kind = 'markdown', value = doc } or nil,
  }
end

---@param bufnr integer
---@param position table {line, character}
---@return table[] CompletionItem[]
function M.complete(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1] or ''
  local before = line:sub(1, position.character)

  -- ¿contexto miembro? Objeto . prefijo
  local obj_name, prefix = before:match('([%w_]+)%.([%w_]*)$')
  if obj_name and intrinsics.object(obj_name) then
    local out = {}
    local pfx = prefix:lower()
    for _, m in ipairs(intrinsics.members_of(obj_name)) do
      if pfx == '' or m.name:lower():sub(1, #pfx) == pfx then
        table.insert(out, item(m.name, KIND_METHOD, m.signature, m.doc))
      end
    end
    return out
  end

  -- contexto general: objetos intrínsecos + símbolos del buffer y del grafo.
  local word = before:match('([%w_]*)$') or ''
  local pfx = word:lower()
  local seen = {}
  local out = {}
  local function add(label, kind, detail)
    local key = label:lower() .. ':' .. kind
    if seen[key] then return end
    if pfx ~= '' and label:lower():sub(1, #pfx) ~= pfx then return end
    seen[key] = true
    table.insert(out, item(label, kind, detail))
  end

  for _, name in ipairs(intrinsics.object_names()) do
    add(name, KIND_MODULE, 'objeto intrínseco ASP')
  end
  for _, e in ipairs(require('asp.symbols').collect(bufnr)) do
    add(e.name, SYM_TO_COMPL[e.kind] or 6, nil)
  end
  local ok, graph = pcall(require('asp.includes').buffer_graph, bufnr)
  if ok then
    for _, file in ipairs(graph.order) do
      for _, e in ipairs(require('asp.symbols').collect_file(file)) do
        if not e.scope_id and not e.class_id then
          add(e.name, SYM_TO_COMPL[e.kind] or 6, nil)
        end
      end
    end
  end
  return out
end

return M
```

En `lua/asp/lsp.lua`: capability `completionProvider = { triggerCharacters = { '.' } }` y el handler:

```lua
M.handlers['textDocument/completion'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.completion').complete(bufnr, params.position)
end
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/completion.lua lua/asp/lsp.lua tests/spec/lsp_spec.lua
git commit -m "feat(lsp): completion de miembros intrínsecos y símbolos del proyecto"
```

---

### Task 4: Documentación :help

**Files:**
- Create: `doc/asp.txt`
- Test: `tests/spec/help_spec.lua`

**Interfaces:**
- Consumes: nada.
- Produces: `:help asp` funciona (tags generados). El test valida estructura, no `:helptags` (que corre el usuario/CI vía `:helptags doc`).

- [ ] **Step 1: Test que falla**

`tests/spec/help_spec.lua`:

```lua
describe('doc/asp.txt', function()
  local text = nil
  before_each(function()
    local f = io.open('doc/asp.txt', 'r')
    text = f and f:read('*a') or nil
    if f then f:close() end
  end)

  it('existe y tiene el tag principal', function()
    assert.is_not_nil(text)
    assert.is_true(text:find('*asp.nvim*', 1, true) ~= nil)
  end)

  it('documenta setup y virtual_root', function()
    assert.is_true(text:find('*asp-setup*', 1, true) ~= nil)
    assert.is_true(text:find('virtual_root', 1, true) ~= nil)
  end)

  it('documenta las capacidades LSP', function()
    for _, cap in ipairs({ 'definition', 'references', 'hover', 'completion' }) do
      assert.is_true(text:find(cap, 1, true) ~= nil, 'falta: ' .. cap)
    end
  end)

  it('cierra cada línea dentro de 78 columnas', function()
    for ln in text:gmatch('[^\n]*') do
      assert.is_true(vim.fn.strdisplaywidth(ln) <= 78,
        'línea > 78: ' .. ln)
    end
  end)
end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — `doc/asp.txt` no existe.

- [ ] **Step 3: Escribir la documentación**

`doc/asp.txt` (respetar el ancho de 78 columnas en TODAS las líneas):

```
*asp.nvim*  Soporte de Classic ASP (VBScript + HTML + JavaScript)

==============================================================================
CONTENIDO                                                       *asp-contents*

  1. Introducción ............................ |asp-intro|
  2. Requisitos .............................. |asp-requisitos|
  3. Instalación ............................. |asp-instalacion|
  4. Configuración ........................... |asp-setup|
  5. Funcionalidades ......................... |asp-funcionalidades|
  6. Licencias ............................... |asp-licencias|

==============================================================================
1. Introducción                                                    *asp-intro*

asp.nvim da soporte de primera clase a Classic ASP, donde VBScript de
servidor, HTML y JavaScript de cliente conviven en un mismo archivo .asp:

  - Resaltado correcto de cada región vía tree-sitter.
  - Navegación LSP (ir a definición, referencias, símbolos) incluyendo
    los archivos referenciados con <!--#include -->.

==============================================================================
2. Requisitos                                                  *asp-requisitos*

  - Neovim >= 0.10
  - `cc` y `git` para compilar los parsers
  - Parsers `javascript` y `css` (p. ej. nvim-treesitter) para el código
    de cliente dentro de <script>/<style>.

==============================================================================
3. Instalación                                              *asp-instalacion*

Con lazy.nvim: >lua
  {
    'erik/asp.nvim',
    build = 'make parsers',
    ft = 'asp',
    opts = {},
  }
<
==============================================================================
4. Configuración                                                   *asp-setup*

                                                              *asp.setup()*
require('asp').setup({opts})

  Opciones ({opts}):

  virtual_root ~
      Ruta raíz para resolver los includes `virtual="/..."`. Si se
      omite, se autodetecta buscando hacia arriba un `web.config` y,
      en su defecto, un directorio `.git`. >lua
        require('asp').setup({ virtual_root = '/ruta/al/sitio' })
<
==============================================================================
5. Funcionalidades                                       *asp-funcionalidades*

El servidor in-process `asp-ls` se adjunta al abrir un .asp y ofrece:

  definition ~
      Ir a la definición de Functions, Subs, Classes, variables y
      constantes, en el archivo actual y a través del grafo de
      includes. Case-insensitive.

  references ~
      Todas las referencias de un símbolo en el buffer y el grafo.
      Los símbolos locales se limitan a su propio scope.

  documentSymbol ~
      Outline del archivo, con los miembros de clase anidados.

  workspace/symbol ~
      Búsqueda de símbolos en todo el proyecto.

  hover ~
      Documentación de los objetos intrínsecos (Response, Request,
      Server, Session, Application) y firma de los símbolos de usuario.

  completion ~
      Miembros de los objetos intrínsecos tras `Objeto.`, más los
      símbolos del proyecto.

  diagnósticos ~
      Los includes que no resuelven se marcan con un warning en su
      línea; los ciclos de includes se reportan.

Salud: >
  :checkhealth asp
<
==============================================================================
6. Licencias                                                    *asp-licencias*

El plugin (Lua, gramática aspclassic, queries) es MIT. El directorio
`grammars/vbscript/` es GPL-3.0 (fork de tree-sitter-vba); ver
`grammars/vbscript/NOTICE.md`.

 vim:tw=78:ts=8:ft=help:norl:
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS (4 specs). Si alguna línea excede 78 columnas, acortarla — el test lo detecta.

- [ ] **Step 5: Commit**

```bash
git add doc/asp.txt tests/spec/help_spec.lua
git commit -m "docs: ayuda :help asp"
```

---

### Task 5: CI (GitHub Actions)

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `Makefile` (target `helptags` para CI)

**Interfaces:**
- Consumes: `make parsers-test`, `make test` (Fase 1-2).
- Produces: workflow que compila parsers y corre la suite en Linux y macOS, contra Neovim estable y nightly.

- [ ] **Step 1: Añadir target de helptags al Makefile**

En `Makefile`, añadir (y a `.PHONY`):

```make
.PHONY: helptags
helptags:
	$(NVIM) --headless -c 'helptags doc' -c 'quit'
```

Verificar local:

Run: `make helptags && test -f doc/tags && echo OK`
Expected: `OK` (genera `doc/tags`). Añadir `doc/tags` a `.gitignore`.

- [ ] **Step 2: Escribir el workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ ubuntu-latest, macos-latest ]
        nvim: [ stable, nightly ]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      - name: Instalar Neovim
        uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: ${{ matrix.nvim }}

      - name: Instalar tree-sitter CLI
        run: npm install -g tree-sitter-cli@^0.25

      - name: Compilar parsers y correr la suite
        run: make test

      - name: Corpus de las gramáticas
        run: |
          (cd grammars/aspclassic && tree-sitter generate && tree-sitter test)
          (cd grammars/vbscript && tree-sitter generate && tree-sitter test)

      - name: Generar helptags
        run: make helptags
```

- [ ] **Step 3: Validar el YAML localmente**

Run: `nvim --headless -c "lua assert(pcall(function() return vim.fn.readfile('.github/workflows/ci.yml') end))" -c "quit" && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo YAML_OK`
Expected: `YAML_OK` (si no hay `python3` con pyyaml, al menos confirmar que el archivo es legible; el test real es que Actions lo acepte al hacer push).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml Makefile .gitignore
git commit -m "ci: GitHub Actions — parsers, suite y corpus en Linux/macOS, estable/nightly"
```

---

### Task 6: Cierre de publicación (README, versión, health)

**Files:**
- Modify: `README.md`
- Modify: `lua/asp/lsp.lua` (versión 0.5.0)
- Modify: `lua/asp/health.lua` (línea de hover/completion)
- Test: `tests/spec/health_spec.lua` (spec nuevo)

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: proyecto listo para v0.5 / publicación.

- [ ] **Step 1: Spec que falla**

Añadir a `tests/spec/health_spec.lua`:

```lua
  it('los módulos de hover y completion existen', function()
    assert.is_function(require('asp.hover').hover)
    assert.is_function(require('asp.completion').complete)
    assert.is_function(require('asp.intrinsics').object)
  end)
```

Run: `make test`
Expected: PASS de inmediato (integración de Tasks 2-3) — es un spec de regresión.

- [ ] **Step 2: Bump de versión**

En `lua/asp/lsp.lua`, cambiar `serverInfo = { name = 'asp-ls', version = '0.3.0' }` por `version = '0.5.0'`.

- [ ] **Step 3: Health**

En `lua/asp/health.lua`, en la sección del LSP, actualizar el texto informativo para listar el set completo de capacidades incluyendo hover y completion (buscar la línea `info`/`ok` de asp-ls de Fase 4 y añadir `hover`, `completion` a la enumeración).

- [ ] **Step 4: README**

En `README.md`:
- En la sección de navegación (título `## Navegación (Fases 3-4)`), renombrar a `## Navegación y ayuda al código` y añadir dos bullets:

```markdown
- **Hover**: documentación de los objetos intrínsecos de ASP
  (`Response`, `Request`, `Server`, `Session`, `Application`) y firma de
  tus propias funciones/subs.
- **Completion**: miembros de los intrínsecos tras `Objeto.` (con
  `triggerCharacters` en `.`) y los símbolos del proyecto.
```

- Añadir al final una sección:

```markdown
## Documentación y estado

- `:help asp` — referencia completa dentro de Neovim.
- `:checkhealth asp` — diagnóstico de parsers y del servidor.
- CI: la suite corre en Linux y macOS contra Neovim estable y nightly.

El plugin cubre las cinco fases del diseño: resaltado de las tres capas,
gramática VBScript propia, navegación LSP, grafo de includes cross-file, y
ayuda al código (hover/completion) con documentación y CI.
```

- [ ] **Step 5: Verificación final de la fase**

Run: `make clean && make test`
Expected: PASS total.

Verificación programática (pegar en el reporte):
1. Headless sobre `tests/fixtures/proyecto/default.asp`: hover de `Response` (contiene 'Response'), hover de `CreateObject` (contiene 'ProgID'), completion tras `Server.` (contiene 'CreateObject').
2. `make helptags` genera `doc/tags`; `:help asp.nvim` headless no da error.
3. `:checkhealth asp` headless lista asp-ls con hover/completion.
4. Con los `asp/*.asp` propietarios (local, sin commitear): abrir uno, completion tras un `Response.` real → miembros presentes; ningún error en `:messages`.

- [ ] **Step 6: Commit**

```bash
git add README.md lua/asp/lsp.lua lua/asp/health.lua tests/spec/health_spec.lua
git commit -m "feat: cierre de Fase 5 — versión 0.5.0, README y health de hover/completion"
```
