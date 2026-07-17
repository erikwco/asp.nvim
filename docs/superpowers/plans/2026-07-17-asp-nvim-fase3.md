# asp.nvim — Fase 3: LSP in-process (documentSymbol + definition) — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Al abrir un `.asp`, un servidor LSP in-process (`asp-ls`) se adjunta automáticamente y ofrece `textDocument/documentSymbol` (outline con clases anidadas) y `textDocument/definition` (case-insensitive, con precedencia local→página) dentro del archivo actual.

**Architecture:** Dos módulos Lua nuevos: `lua/asp/symbols.lua` (extracción pura de definiciones desde los árboles vbscript inyectados, vía una query tree-sitter dedicada) y `lua/asp/lsp.lua` (servidor LSP como función — `vim.lsp.start` con `cmd` funcional, sin proceso externo — que delega en symbols). `plugin/asp.lua` arranca el servidor en el mismo autocmd FileType que ya arranca treesitter. El contrato del servidor in-process fue validado hoy con un probe en el nvim 0.12 real (attach, negociación `positionEncoding=utf-8`, round-trip de documentSymbol via `buf_request_sync`).

**Tech Stack:** Lua (Neovim ≥0.10, validado en 0.12), tree-sitter queries sobre la gramática `vbscript` de la Fase 2, plenary (tests).

## Global Constraints

- Alcance Fase 3 = **archivo actual solamente**; el grafo de includes es Fase 4 (spec).
- Comparación de identificadores **case-insensitive** (VBScript); orden de resolución: (1) local a la función actual, (2) nivel de página (spec: "Semántica de resolución").
- El servidor declara `positionEncoding = 'utf-8'` en capabilities (validado: el cliente negocia `offset_encoding=utf-8`), así las columnas byte de tree-sitter son válidas tal cual.
- Nombre del servidor LSP: **`asp-ls`**. Sin dependencias externas ni procesos.
- Nodos de la gramática vbscript disponibles (Fase 2): `sub_statement`/`function_statement`/`property_statement` (primer `identifier` hijo directo = nombre; los siguientes hijos `identifier` directos = parámetros, porque `_arg_list`/`_arg` son reglas ocultas), `class_statement` con `field('name', identifier)`, `dim_statement`/`const_statement` con uno o más `identifier`.
- Los handlers del servidor JAMÁS deben lanzar error (envolver en pcall y responder `callback(err_msg, nil)` si algo falla): un error tumba el cliente.
- Degradación suave: con árboles parciales (código con errores de sintaxis) los símbolos que sí parsean deben seguir funcionando.
- La suite plenary previa completa (`make clean && make test`) debe seguir verde en cada task; no hardcodear conteos globales de specs de otras tasks.
- Fixture nuevo público y anonimizado: `tests/fixtures/symbols.asp`. Los `asp/*.asp` propietarios NUNCA se commitean (solo verificación local en la Task 5).

---

### Task 1: Módulo de símbolos (extracción tree-sitter pura)

**Files:**
- Create: `lua/asp/symbols.lua`
- Create: `tests/fixtures/symbols.asp`
- Test: `tests/spec/symbols_spec.lua`

**Interfaces:**
- Consumes: parser `aspclassic` + injection `vbscript` (Fase 2); `vim.treesitter.get_parser`.
- Produces: `require('asp.symbols').collect(bufnr)` → lista de entradas `{ name=string, kind=number (LSP SymbolKind), range={r0,c0,r1,c1} (statement), selection={r0,c0,r1,c1} (identificador), decl_id=userdata, class_id=userdata|nil (class_statement ancestro), scope_id=userdata|nil (sub/function/property ancestro) }`. Las Tasks 3 y 4 consumen exactamente esta forma.

- [ ] **Step 1: Fixture y test que falla**

`tests/fixtures/symbols.asp`:

```asp
<%@ Language="VBScript" %>
<html><body>
<%
Option Explicit
Dim total, nombre
Const IVA = 12

Class Pedido
  Private m_total
  Public Sub Agregar(monto)
    m_total = m_total + monto
  End Sub
End Class

Function CalcularTotal(base)
  Dim recargo
  recargo = base * IVA
  CalcularTotal = base + recargo
End Function

Sub Mostrar()
  Response.Write CalcularTotal(total)
End Sub

nombre = "cliente"
mostrar
%>
</body></html>
```

`tests/spec/symbols_spec.lua`:

```lua
describe('asp.symbols', function()
  before_each(function()
    vim.cmd.edit('tests/fixtures/symbols.asp')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  local function by_name(entries, name)
    local hits = {}
    for _, e in ipairs(entries) do
      if e.name:lower() == name:lower() then table.insert(hits, e) end
    end
    return hits
  end

  it('extrae subs, functions, class, dims y consts con su kind', function()
    local entries = require('asp.symbols').collect(0)
    assert.are.equal(5, by_name(entries, 'Pedido')[1].kind)          -- Class
    assert.are.equal(12, by_name(entries, 'CalcularTotal')[1].kind)  -- Function
    assert.are.equal(12, by_name(entries, 'Mostrar')[1].kind)        -- Function
    assert.are.equal(13, by_name(entries, 'total')[1].kind)          -- Variable
    assert.are.equal(14, by_name(entries, 'IVA')[1].kind)            -- Constant
  end)

  it('registra scopes: recargo es local a CalcularTotal, total es de página', function()
    local entries = require('asp.symbols').collect(0)
    local recargo = by_name(entries, 'recargo')[1]
    local total = by_name(entries, 'total')[1]
    local fn = by_name(entries, 'CalcularTotal')[1]
    assert.is_not_nil(recargo.scope_id)
    assert.are.equal(fn.decl_id, recargo.scope_id)
    assert.is_nil(total.scope_id)
  end)

  it('registra membresía de clase y parámetros', function()
    local entries = require('asp.symbols').collect(0)
    local agregar = by_name(entries, 'Agregar')[1]
    local pedido = by_name(entries, 'Pedido')[1]
    local monto = by_name(entries, 'monto')[1]
    assert.are.equal(pedido.decl_id, agregar.class_id)
    assert.are.equal(agregar.decl_id, monto.scope_id)
    assert.are.equal(13, monto.kind)
  end)
end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — `module 'asp.symbols' not found`.

- [ ] **Step 3: Implementar el módulo**

`lua/asp/symbols.lua`:

```lua
local M = {}

-- SymbolKind (LSP): Class=5, Property=7, Function=12, Variable=13, Constant=14
local QUERY = [[
(sub_statement . (identifier) @name) @decl
(function_statement . (identifier) @name) @decl
(class_statement name: (identifier) @name) @decl
(property_statement (identifier) @name) @decl
(dim_statement (identifier) @name) @decl
(const_statement (identifier) @name) @decl
(sub_statement (identifier) @name) @decl
(function_statement (identifier) @name) @decl
]]
-- Patrones 1-6: nombres de declaraciones (anclados donde aplica).
-- Patrones 7-8: hijos identifier directos de sub/function — capturan nombre
-- Y parámetros (los _arg son reglas ocultas); el nombre se descarta por
-- dedupe (ya visto por 1-2) y quedan solo los parámetros, kind Variable.
local PATTERN_KINDS = { 12, 12, 5, 7, 13, 14, 13, 13 }

local SCOPE_TYPES = {
  sub_statement = true,
  function_statement = true,
  property_statement = true,
}

local function nearest_ancestor(node, types)
  local cur = node:parent()
  while cur do
    if types[cur:type()] then return cur end
    cur = cur:parent()
  end
  return nil
end

---@param bufnr integer
---@return table[] entries
function M.collect(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return {} end
  parser:parse(true)
  local child = parser:children().vbscript
  if not child then return {} end

  local query = vim.treesitter.query.parse('vbscript', QUERY)
  local entries = {}
  local seen = {}

  for _, tree in ipairs(child:trees()) do
    for pattern, match in query:iter_matches(tree:root(), bufnr) do
      local name_nodes, decl_node
      for id, nodes in pairs(match) do
        if type(nodes) ~= 'table' then nodes = { nodes } end
        local cap = query.captures[id]
        if cap == 'name' then name_nodes = nodes end
        if cap == 'decl' then decl_node = nodes[#nodes] end
      end
      for _, name_node in ipairs(name_nodes or {}) do
        if not seen[name_node:id()] then
          seen[name_node:id()] = true
          local class_anc = nearest_ancestor(name_node, { class_statement = true })
          local scope_anc = nearest_ancestor(name_node, SCOPE_TYPES)
          -- Para patrones 7-8 el scope del parámetro es el propio sub/function
          -- que lo declara; nearest_ancestor ya lo devuelve (es su padre).
          local r0, c0, r1, c1 = decl_node:range()
          local sr0, sc0, sr1, sc1 = name_node:range()
          table.insert(entries, {
            name = vim.treesitter.get_node_text(name_node, bufnr),
            kind = PATTERN_KINDS[pattern],
            range = { r0, c0, r1, c1 },
            selection = { sr0, sc0, sr1, sc1 },
            decl_id = decl_node:id(),
            class_id = class_anc and class_anc:id() or nil,
            scope_id = scope_anc and scope_anc:id() or nil,
          })
        end
      end
    end
  end
  return entries
end

return M
```

Nota de implementación: para los patrones 1-2 (nombre de sub/function), `nearest_ancestor` del identificador-nombre devuelve el propio `sub_statement` — para una declaración de página eso haría `scope_id ≠ nil`. Corregir tras construir la entrada: si `decl_id == scope_id` del ancestro encontrado (es decir, el scope hallado ES la propia declaración), poner `scope_id` del ancestro siguiente (o nil). Implementarlo dentro del loop:

```lua
          if scope_anc and scope_anc:id() == decl_node:id() then
            scope_anc = nearest_ancestor(scope_anc, SCOPE_TYPES)
          end
```

(colocar ANTES de construir la entrada, y lo mismo para `class_anc` con `class_statement`). Los tests del Step 1 verifican exactamente esta semántica (`Mostrar` y `CalcularTotal` deben quedar con `scope_id = nil`; el parámetro `monto` con `scope_id = Agregar`).

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS — los 3 specs nuevos + la suite previa completa.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/symbols.lua tests/fixtures/symbols.asp tests/spec/symbols_spec.lua
git commit -m "feat(lsp): módulo de símbolos sobre los árboles vbscript inyectados"
```

---

### Task 2: Servidor LSP in-process y arranque automático

**Files:**
- Create: `lua/asp/lsp.lua`
- Modify: `plugin/asp.lua` (autocmd FileType)
- Test: `tests/spec/lsp_spec.lua`

**Interfaces:**
- Consumes: nada de symbols aún (los handlers de documentSymbol/definition llegan en Tasks 3-4 y aquí responden `nil`).
- Produces: `require('asp.lsp').start(bufnr)` → arranca/reusa el cliente `asp-ls` para el buffer; servidor con `initialize`/`shutdown`/`exit` y capabilities `{ documentSymbolProvider=true, definitionProvider=true, positionEncoding='utf-8' }`. Tasks 3-4 agregan ramas al dispatch de `srv.request`.

- [ ] **Step 1: Test que falla**

`tests/spec/lsp_spec.lua`:

```lua
describe('asp-ls', function()
  before_each(function()
    vim.cmd.edit('tests/fixtures/symbols.asp')
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' }) > 0
    end)
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  it('se adjunta automáticamente a buffers asp', function()
    local clients = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })
    assert.are.equal(1, #clients)
  end)

  it('negocia utf-8 y anuncia sus capacidades', function()
    local client = vim.lsp.get_clients({ bufnr = 0, name = 'asp-ls' })[1]
    assert.are.equal('utf-8', client.offset_encoding)
    assert.is_true(client.server_capabilities.documentSymbolProvider)
    assert.is_true(client.server_capabilities.definitionProvider)
  end)
end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — ningún cliente `asp-ls` se adjunta (timeout del wait → 0 clientes).

- [ ] **Step 3: Implementar servidor y arranque**

`lua/asp/lsp.lua` (esqueleto validado hoy por probe en nvim 0.12: attach, `offset_encoding=utf-8`, round-trip con `buf_request_sync`):

```lua
local M = {}

-- Handlers por método; las Tasks 3-4 agregan entradas aquí.
-- Cada handler recibe (params) y retorna el resultado (o nil).
M.handlers = {}

local function server(dispatchers)
  local closing = false
  return {
    request = function(method, params, callback)
      if method == 'initialize' then
        callback(nil, {
          capabilities = {
            documentSymbolProvider = true,
            definitionProvider = true,
            positionEncoding = 'utf-8',
          },
          serverInfo = { name = 'asp-ls', version = '0.3.0' },
        })
      elseif method == 'shutdown' then
        callback(nil, nil)
      elseif M.handlers[method] then
        local ok, result = pcall(M.handlers[method], params)
        if ok then
          callback(nil, result)
        else
          callback({ code = -32603, message = tostring(result) }, nil)
        end
      else
        callback(nil, nil)
      end
      return true, 1
    end,
    notify = function(method, _params)
      if method == 'exit' then
        closing = true
      end
      return false
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

---@param bufnr integer
function M.start(bufnr)
  return vim.lsp.start({
    name = 'asp-ls',
    cmd = server,
    root_dir = vim.fs.root(bufnr, { '.git', 'web.config' }) or vim.fn.getcwd(),
  }, { bufnr = bufnr })
end

return M
```

En `plugin/asp.lua`, dentro del callback del autocmd FileType existente, añadir tras el `pcall(vim.treesitter.start, ...)`:

```lua
    pcall(function()
      require('asp.lsp').start(args.buf)
    end)
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS — 2 specs nuevos + suite previa.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/lsp.lua plugin/asp.lua tests/spec/lsp_spec.lua
git commit -m "feat(lsp): servidor asp-ls in-process con arranque automático"
```

---

### Task 3: textDocument/documentSymbol jerárquico

**Files:**
- Modify: `lua/asp/symbols.lua` (nueva función `document_symbols`)
- Modify: `lua/asp/lsp.lua` (registrar handler)
- Test: `tests/spec/lsp_spec.lua` (specs nuevos)

**Interfaces:**
- Consumes: `symbols.collect(bufnr)` (Task 1); `M.handlers` de `asp.lsp` (Task 2).
- Produces: `require('asp.symbols').document_symbols(bufnr)` → `DocumentSymbol[]` jerárquico (miembros de clase como `children`; los locales de función NO aparecen en el outline). Registrado como handler de `textDocument/documentSymbol`.

- [ ] **Step 1: Specs que fallan**

Añadir a `tests/spec/lsp_spec.lua` (mismo `describe`, aprovecha el `before_each`):

```lua
  local function request(method, params)
    local resp = vim.lsp.buf_request_sync(0, method, params, 3000)
    for _, r in pairs(resp or {}) do
      return r.result
    end
    return nil
  end

  it('documentSymbol devuelve outline jerárquico', function()
    local syms = request('textDocument/documentSymbol', {
      textDocument = vim.lsp.util.make_text_document_params(),
    })
    assert.is_not_nil(syms)
    local by_name = {}
    for _, s in ipairs(syms) do by_name[s.name] = s end
    assert.are.equal(5, by_name['Pedido'].kind)
    assert.are.equal(12, by_name['CalcularTotal'].kind)
    assert.are.equal(13, by_name['total'].kind)
    local children = {}
    for _, c in ipairs(by_name['Pedido'].children or {}) do children[c.name] = c end
    assert.is_not_nil(children['Agregar'])
    assert.is_not_nil(children['m_total'])
    -- locales de función fuera del outline:
    assert.is_nil(by_name['recargo'])
    assert.is_nil(by_name['monto'])
  end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — el handler no existe, `syms` es nil.

- [ ] **Step 3: Implementar**

Añadir a `lua/asp/symbols.lua`:

```lua
local function to_lsp_range(r)
  return {
    start = { line = r[1], character = r[2] },
    ['end'] = { line = r[3], character = r[4] },
  }
end

---@param bufnr integer
---@return table[] DocumentSymbol[]
function M.document_symbols(bufnr)
  local entries = M.collect(bufnr)
  local roots, by_decl = {}, {}

  for _, e in ipairs(entries) do
    local sym = {
      name = e.name,
      kind = e.kind,
      range = to_lsp_range(e.range),
      selectionRange = to_lsp_range(e.selection),
      children = {},
    }
    by_decl[e.decl_id] = sym
    e._sym = sym
  end

  for _, e in ipairs(entries) do
    if e.scope_id and not e.class_id then
      -- local de función: fuera del outline
    elseif e.class_id and by_decl[e.class_id] then
      if not e.scope_id then
        table.insert(by_decl[e.class_id].children, e._sym)
      end
      -- (con scope_id dentro de clase = local de método: fuera)
    else
      table.insert(roots, e._sym)
    end
  end
  return roots
end
```

Nota: los campos de clase (`Private m_total`) tienen `class_id` y `scope_id = nil` → hijos de la clase. Los parámetros/locales de métodos tienen `scope_id ≠ nil` → excluidos. Los `dim` de página no tienen ninguno → raíz.

En `lua/asp/lsp.lua`, después de la tabla `M.handlers = {}` añadir:

```lua
M.handlers['textDocument/documentSymbol'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.symbols').document_symbols(bufnr)
end
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/symbols.lua lua/asp/lsp.lua tests/spec/lsp_spec.lua
git commit -m "feat(lsp): documentSymbol jerárquico"
```

---

### Task 4: textDocument/definition (case-insensitive, local→página)

**Files:**
- Modify: `lua/asp/symbols.lua` (nueva función `definition`)
- Modify: `lua/asp/lsp.lua` (registrar handler)
- Test: `tests/spec/lsp_spec.lua` (specs nuevos)

**Interfaces:**
- Consumes: `symbols.collect(bufnr)`; `M.handlers`.
- Produces: `require('asp.symbols').definition(bufnr, position)` → `Location|nil` (`position` = `{line, character}` LSP utf-8). Registrado como handler de `textDocument/definition`.

- [ ] **Step 1: Specs que fallan**

Añadir a `tests/spec/lsp_spec.lua` (dentro del mismo `describe`; usa el helper `request` de la Task 3):

```lua
  local function pos_of(text, occurrence)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local n = 0
    for i, line in ipairs(lines) do
      local col = line:find(text, 1, true)
      if col then
        n = n + 1
        if n == (occurrence or 1) then
          return { line = i - 1, character = col - 1 }
        end
      end
    end
    error('texto no encontrado en fixture: ' .. text)
  end

  local function line_of(text)
    return pos_of(text).line
  end

  local function definition_at(pos)
    return request('textDocument/definition', {
      textDocument = vim.lsp.util.make_text_document_params(),
      position = pos,
    })
  end

  it('definition salta a la Function desde su llamada', function()
    local loc = definition_at(pos_of('CalcularTotal(total)'))
    assert.is_not_nil(loc)
    assert.are.equal(line_of('Function CalcularTotal'), loc.range.start.line)
  end)

  it('definition es case-insensitive', function()
    local loc = definition_at(pos_of('mostrar'))
    assert.are.equal(line_of('Sub Mostrar'), loc.range.start.line)
  end)

  it('definition prefiere el scope local y cae a página', function()
    -- 'recargo' usado dentro de CalcularTotal → Dim recargo local
    local loc = definition_at(pos_of('recargo = base'))
    assert.are.equal(line_of('Dim recargo'), loc.range.start.line)
    -- 'total' usado dentro de Mostrar → Dim de página
    local loc2 = definition_at(pos_of('CalcularTotal(total)'))
    -- (posiciona sobre 'total' dentro del paréntesis:)
    local p = pos_of('CalcularTotal(total)')
    p.character = p.character + #('CalcularTotal(')
    local loc3 = definition_at(p)
    assert.are.equal(line_of('Dim total'), loc3.range.start.line)
    assert.is_not_nil(loc2)
  end)
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `make test`
Expected: FAIL — handler inexistente, `loc` nil.

- [ ] **Step 3: Implementar**

Añadir a `lua/asp/symbols.lua`:

```lua
---@param bufnr integer
---@param position table {line, character} (utf-8)
---@return table|nil Location
function M.definition(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local node = vim.treesitter.get_node({
    bufnr = bufnr,
    pos = { position.line, position.character },
  })
  if not node or node:type() ~= 'identifier' then return nil end
  local wanted = vim.treesitter.get_node_text(node, bufnr):lower()

  local cursor_scope = nearest_ancestor(node, SCOPE_TYPES)
  local cursor_scope_id = cursor_scope and cursor_scope:id() or nil

  local entries = M.collect(bufnr)
  local local_hit, page_hit, any_hit
  for _, e in ipairs(entries) do
    if e.name:lower() == wanted and e.decl_id ~= node:id() then
      any_hit = any_hit or e
      if cursor_scope_id and e.scope_id == cursor_scope_id then
        local_hit = local_hit or e
      elseif not e.scope_id then
        page_hit = page_hit or e
      end
    end
  end
  local best = local_hit or page_hit or any_hit
  if not best then return nil end
  return {
    uri = vim.uri_from_bufnr(bufnr),
    range = {
      start = { line = best.selection[1], character = best.selection[2] },
      ['end'] = { line = best.selection[3], character = best.selection[4] },
    },
  }
end
```

(Nota: `nearest_ancestor` y `SCOPE_TYPES` ya existen como locales del módulo desde la Task 1 — `definition` debe declararse en el mismo archivo debajo de ellos.)

En `lua/asp/lsp.lua`:

```lua
M.handlers['textDocument/definition'] = function(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  return require('asp.symbols').definition(bufnr, params.position)
end
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/symbols.lua lua/asp/lsp.lua tests/spec/lsp_spec.lua
git commit -m "feat(lsp): definition case-insensitive con precedencia local→página"
```

---

### Task 5: Cierre de fase — health, README y verificación con ASP real

**Files:**
- Modify: `lua/asp/health.lua`
- Modify: `README.md`
- Test: `tests/spec/health_spec.lua` (spec nuevo)

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: `:checkhealth asp` reporta el estado del LSP; README documenta la navegación. La Fase 4 parte de aquí.

- [ ] **Step 1: Spec que falla**

Añadir a `tests/spec/health_spec.lua`:

```lua
  it('el modulo lsp expone start y handlers', function()
    local lsp = require('asp.lsp')
    assert.is_function(lsp.start)
    assert.is_function(lsp.handlers['textDocument/documentSymbol'])
    assert.is_function(lsp.handlers['textDocument/definition'])
  end)
```

Run: `make test`
Expected: PASS de la suite previa pero FAIL de este spec **solo si** las Tasks 3-4 no registraron los handlers; si pasa de inmediato, es la confirmación de integración esperada — continuar (el valor del spec es de regresión futura).

- [ ] **Step 2: Health check del LSP**

En `lua/asp/health.lua`, al final de `M.check()` añadir:

```lua
  local asp_clients = vim.lsp.get_clients({ name = 'asp-ls' })
  if #asp_clients > 0 then
    health.ok(('asp-ls activo (%d cliente(s))'):format(#asp_clients))
  else
    health.info('asp-ls se adjunta al abrir un archivo .asp (documentSymbol y definition)')
  end
```

- [ ] **Step 3: README**

En `README.md`, tras la sección de instalación, añadir:

```markdown
## Navegación (Fase 3)

Al abrir un `.asp` se adjunta el servidor in-process `asp-ls`:

- **Ir a definición**: `C-]` (vía tagfunc) o `vim.lsp.buf.definition()` —
  Functions, Subs, Classes, variables y constantes del archivo actual,
  case-insensitive, con precedencia local → página.
- **Símbolos del documento**: `vim.lsp.buf.document_symbol()` u outline de
  tu plugin favorito (aerial, Telescope `lsp_document_symbols`, ...).

La resolución a través de `<!--#include -->` llega en la Fase 4.
```

- [ ] **Step 4: Verificación completa y manual**

Run: `make clean && make test`
Expected: PASS total.

Verificación programática de cierre (pegar resultados en el reporte):

1. `nvim --headless -u tests/minimal_init.lua tests/fixtures/symbols.asp` + script que espere el attach y pida `textDocument/documentSymbol` y una `definition` (réplica de los specs, sanity end-to-end).
2. Con cada `asp/*.asp` propietario (local, sin commitear): abrir headless, esperar attach, pedir documentSymbol y reportar el conteo de símbolos (se espera > 0 en los tres) y una definition sobre un identificador conocido (elegir uno del propio archivo). Ningún error de handler en `:messages`.
3. `:checkhealth asp` headless → incluye la línea de asp-ls.

- [ ] **Step 5: Commit**

```bash
git add lua/asp/health.lua README.md tests/spec/health_spec.lua
git commit -m "feat: health y docs del LSP — cierre de Fase 3"
```
