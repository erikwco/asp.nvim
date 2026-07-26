# asp.nvim — Fase 1: resaltado de las tres capas — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Al abrir un archivo `.asp` en Neovim, las tres capas (plantilla ASP, HTML, VBScript vía la gramática VBA) se parsean con tree-sitter y se resaltan correctamente, sin depender de nvim-treesitter para nuestras gramáticas.

**Architecture:** Monorepo `asp-neovim` con: (1) gramática `tree-sitter-aspclassic` en `grammars/aspclassic/` que separa bloques `<% %>`/`<%= %>`/`<%@ %>`, el nodo `include_directive` y contenido; (2) plugin Lua que registra el filetype `asp`, carga los parsers compilados desde `parser/` en el runtimepath y arranca `vim.treesitter.start` — todo con APIs core de Neovim (≥0.10), sin nvim-treesitter; (3) Makefile que genera/compila los parsers (aspclassic, vba, html) y corre los tests.

**Tech Stack:** tree-sitter CLI, C (cc), Lua (Neovim ≥0.10), plenary.nvim (tests), Make.

**Fases futuras:** las fases 2–5 del spec (`docs/superpowers/specs/2026-07-16-asp-neovim-design.md`) tendrán cada una su propio plan al terminar la anterior.

## Global Constraints

- Neovim ≥ **0.10** (APIs core de treesitter: `vim.treesitter.start`, injections, `language.register`).
- tree-sitter CLI ≥ **0.24** y Node.js ≥ 18 (solo para `tree-sitter generate` en desarrollo).
- Compilador C (`cc`) y `git` disponibles.
- Nombre del plugin: **asp.nvim**; nombre del parser/lenguaje tree-sitter: **`aspclassic`**; filetype: **`asp`** (aplica a `.asp` y `.inc`).
- Parser de VBScript en Fase 1 = `vba` sin modificar, desde `https://github.com/arrmee-wt/tree-sitter-vba`.
- Licencia MIT.
- Los directorios `parser/`, `build/` y `grammars/aspclassic/src/` son artefactos generados: van en `.gitignore`.
- Los parsers de HTML/JS/CSS en uso real vienen de la instalación del usuario (nvim-treesitter); el Makefile compila `html` solo para que los tests sean autocontenidos.

---

### Task 1: Scaffold del repo, filetype y arnés de tests

**Files:**
- Create: `.gitignore`
- Create: `Makefile`
- Create: `tests/minimal_init.lua`
- Create: `tests/fixtures/basic.asp`
- Create: `tests/spec/filetype_spec.lua`
- Create: `plugin/asp.lua`

**Interfaces:**
- Consumes: nada (primera task).
- Produces: `make test` (corre plenary sobre `tests/spec/`); `make build/plenary.nvim`; filetype `asp` para `*.asp`/`*.inc`; fixture `tests/fixtures/basic.asp`; `plugin/asp.lua` como punto de entrada del plugin (las tasks 4–6 lo extienden).

- [ ] **Step 1: Crear scaffold y test que falla**

`.gitignore`:

```gitignore
parser/
build/
grammars/aspclassic/src/
grammars/aspclassic/node_modules/
```

`Makefile`:

```make
NVIM ?= nvim

build/plenary.nvim:
	mkdir -p build
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim build/plenary.nvim

.PHONY: test
test: build/plenary.nvim
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }"
```

`tests/minimal_init.lua`:

```lua
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root .. '/build/plenary.nvim')
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime! plugin/plenary.vim')
vim.cmd('runtime! plugin/asp.lua')
```

`tests/fixtures/basic.asp`:

```asp
<%@ Language="VBScript" %>
<!--#include file="lib/helpers.asp" -->
<html>
  <head>
    <script type="text/javascript">
      function saludar() { alert("hola"); }
    </script>
  </head>
  <body>
    <% Dim nombre
       nombre = "mundo"
       Response.Write "Hola, " & nombre %>
    <p>Total: <%= 2 + 2 %></p>
  </body>
</html>
```

`tests/spec/filetype_spec.lua`:

```lua
describe('filetype', function()
  it('detecta .asp como filetype asp', function()
    vim.cmd.edit('tests/fixtures/basic.asp')
    assert.are.equal('asp', vim.bo.filetype)
  end)

  it('detecta .inc como filetype asp', function()
    vim.cmd.edit('tests/fixtures/dummy.inc')
    assert.are.equal('asp', vim.bo.filetype)
  end)
end)
```

Crear también un fixture vacío para el segundo test:

```bash
touch tests/fixtures/dummy.inc
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

Run: `make test`
Expected: FAIL — Neovim detecta `.asp` como `aspvbs` (detección builtin), no `asp`. El test de `.inc` también falla.

- [ ] **Step 3: Implementación mínima — plugin/asp.lua con filetype**

`plugin/asp.lua`:

```lua
if vim.g.loaded_asp_nvim then
  return
end
vim.g.loaded_asp_nvim = true

vim.filetype.add({
  extension = {
    asp = 'asp',
    inc = 'asp',
  },
})
```

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `make test`
Expected: PASS (2 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add .gitignore Makefile tests plugin
git commit -m "feat: scaffold del plugin, filetype asp y arnés de tests con plenary"
```

---

### Task 2: Gramática tree-sitter-aspclassic — bloques de código y contenido

**Files:**
- Create: `grammars/aspclassic/grammar.js`
- Create: `grammars/aspclassic/tree-sitter.json`
- Create: `grammars/aspclassic/package.json`
- Create: `grammars/aspclassic/test/corpus/template.txt`

**Interfaces:**
- Consumes: nada (la gramática es independiente del plugin).
- Produces: nodos `template`, `code_directive`, `output_directive`, `page_directive`, `code`, `directive_attributes`, `content` — las queries de la Task 5 y el corpus de la Task 3 dependen de estos nombres exactos.

- [ ] **Step 1: Escribir el corpus de tests (fallará)**

`grammars/aspclassic/test/corpus/template.txt`:

```
==================
bloque de codigo
==================
<% Response.Write "hola" %>
---

(template
  (code_directive
    (code))
  (content))

==================
bloque de salida
==================
<%= total %>
---

(template
  (output_directive
    (code))
  (content))

==================
directiva de pagina
==================
<%@ Language="VBScript" %>
---

(template
  (page_directive
    (directive_attributes))
  (content))

==================
codigo entre html
==================
<p><% x = 1 %></p>
---

(template
  (content)
  (content)
  (code_directive
    (code))
  (content)
  (content))
```

Nota: cada entrada del corpus termina en newline, que la gramática parsea como un `(content)` final. El nodo `content` se fragmenta en cada `<` que no abre un bloque ASP (por eso `<p>` produce dos `(content)`); las injections combinadas de la Task 5 los unen. Si el árbol real difiere en fragmentación de `content` al correr los tests, inspeccionar con `tree-sitter parse`, y solo si el árbol es correcto, regenerar expectativas con `tree-sitter test --update`.

`grammars/aspclassic/package.json`:

```json
{
  "name": "tree-sitter-aspclassic",
  "version": "0.1.0",
  "description": "Tree-sitter grammar for Classic ASP templates",
  "license": "MIT",
  "main": "bindings/node",
  "dependencies": {}
}
```

`grammars/aspclassic/tree-sitter.json`:

```json
{
  "grammars": [
    {
      "name": "aspclassic",
      "camelcase": "AspClassic",
      "scope": "source.aspclassic",
      "file-types": ["asp", "inc"],
      "injection-regex": "^asp"
    }
  ],
  "metadata": {
    "version": "0.1.0",
    "license": "MIT",
    "description": "Tree-sitter grammar for Classic ASP templates"
  }
}
```

Crear un `grammar.js` mínimo (solo contenido) para que el corpus falle por las razones correctas:

```js
module.exports = grammar({
  name: 'aspclassic',

  extras: () => [],

  rules: {
    template: $ => repeat($.content),

    content: () => token(prec(-1, choice(/[^<]+/, '<'))),
  },
});
```

- [ ] **Step 2: Generar y correr el corpus para verificar que falla**

```bash
cd grammars/aspclassic
tree-sitter generate
tree-sitter test
```

Expected: FAIL — los cuatro casos producen solo nodos `(content)`; no existen `code_directive`/`output_directive`/`page_directive`.

- [ ] **Step 3: Implementar la gramática completa de bloques**

`grammars/aspclassic/grammar.js` (reemplazo completo):

```js
module.exports = grammar({
  name: 'aspclassic',

  extras: () => [],

  rules: {
    template: $ => repeat(choice(
      $.page_directive,
      $.output_directive,
      $.code_directive,
      $.content,
    )),

    code_directive: $ => seq('<%', optional($.code), '%>'),

    output_directive: $ => seq('<%=', optional($.code), '%>'),

    page_directive: $ => seq(
      '<%@',
      optional(alias($.code, $.directive_attributes)),
      '%>',
    ),

    // Todo lo que hay dentro de <% ... %>: cualquier char salvo un
    // '%' seguido de '>'.
    code: () => token(prec(-1, repeat1(choice(/[^%]+/, /%[^>]/)))),

    // Todo lo que hay fuera de los bloques. El '<' suelto cubre los
    // '<' de HTML que no abren un bloque ASP; el lexer prefiere los
    // tokens más largos ('<%', '<%=', '<%@') cuando aplican.
    content: () => token(prec(-1, choice(/[^<]+/, '<'))),
  },
});
```

- [ ] **Step 4: Regenerar y verificar que el corpus pasa**

```bash
cd grammars/aspclassic
tree-sitter generate
tree-sitter test
```

Expected: PASS en los cuatro casos (ajustar expectativas de fragmentación de `content` con `--update` solo tras verificar el árbol a mano con `tree-sitter parse ../../tests/fixtures/basic.asp`).

- [ ] **Step 5: Commit**

```bash
git add grammars/aspclassic
git commit -m "feat(grammar): gramática aspclassic con bloques <% %>, <%= %> y <%@ %>"
```

---

### Task 3: Gramática — nodo include_directive

**Files:**
- Modify: `grammars/aspclassic/grammar.js`
- Create: `grammars/aspclassic/test/corpus/includes.txt`

**Interfaces:**
- Consumes: gramática de la Task 2.
- Produces: nodo `include_directive` con campos `kind` (nodo `include_kind`) y `path` (nodo `quoted_path`) — el resaltado de la Task 5 y el grafo de includes de la Fase 4 dependen de estos nombres exactos.

- [ ] **Step 1: Escribir el corpus de includes (fallará)**

`grammars/aspclassic/test/corpus/includes.txt`:

```
==================
include file
==================
<!--#include file="lib/db.asp" -->
---

(template
  (include_directive
    kind: (include_kind)
    path: (quoted_path))
  (content))

==================
include virtual con comillas simples
==================
<!--#include virtual='/comun/header.inc'-->
---

(template
  (include_directive
    kind: (include_kind)
    path: (quoted_path))
  (content))

==================
comentario html normal no es include
==================
<!-- hola -->
---

(template
  (content)
  (content))
```

- [ ] **Step 2: Correr el corpus y verificar que falla**

```bash
cd grammars/aspclassic && tree-sitter test
```

Expected: FAIL — los dos primeros casos parsean como `(content)`.

- [ ] **Step 3: Agregar las reglas de include**

En `grammars/aspclassic/grammar.js`, agregar `$.include_directive` como primera opción del `choice` de `template`:

```js
    template: $ => repeat(choice(
      $.include_directive,
      $.page_directive,
      $.output_directive,
      $.code_directive,
      $.content,
    )),
```

y agregar estas reglas después de `page_directive`:

```js
    include_directive: $ => seq(
      '<!--#include',
      /\s+/,
      field('kind', alias(choice('file', 'virtual'), $.include_kind)),
      optional(/\s+/),
      '=',
      optional(/\s+/),
      field('path', $.quoted_path),
      optional(/\s+/),
      '-->',
    ),

    quoted_path: () => token(choice(/"[^"]*"/, /'[^']*'/)),
```

- [ ] **Step 4: Regenerar y verificar que el corpus completo pasa**

```bash
cd grammars/aspclassic
tree-sitter generate
tree-sitter test
```

Expected: PASS — los 7 casos (template.txt + includes.txt). El caso "comentario html normal" debe seguir siendo `(content)`.

- [ ] **Step 5: Commit**

```bash
git add grammars/aspclassic
git commit -m "feat(grammar): nodo include_directive con campos kind y path"
```

---

### Task 4: Compilación de parsers y carga en Neovim

**Files:**
- Modify: `Makefile`
- Create: `tests/spec/parser_spec.lua`

**Interfaces:**
- Consumes: gramática de las Tasks 2–3.
- Produces: target `make parsers` que deja `parser/aspclassic.so`, `parser/vba.so`, `parser/html.so` y `queries/vba/` en el repo; `vim.treesitter.language.add('aspclassic'|'vba'|'html')` funciona con el plugin en el runtimepath. La Task 5 asume los tres `.so` presentes.

- [ ] **Step 1: Escribir el test de carga (fallará)**

`tests/spec/parser_spec.lua`:

```lua
describe('parsers', function()
  it('carga el parser aspclassic', function()
    assert.is_true((pcall(vim.treesitter.language.add, 'aspclassic')))
  end)

  it('carga el parser vba', function()
    assert.is_true((pcall(vim.treesitter.language.add, 'vba')))
  end)

  it('carga el parser html', function()
    assert.is_true((pcall(vim.treesitter.language.add, 'html')))
  end)
end)
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

Run: `make test`
Expected: FAIL — no existe `parser/*.so` en el runtimepath.

- [ ] **Step 3: Agregar los targets de compilación al Makefile**

Reemplazar el `Makefile` completo por:

```make
NVIM ?= nvim
CC ?= cc
CFLAGS ?= -Os -fPIC -shared

PARSERS := parser/aspclassic.so parser/vba.so parser/html.so

.PHONY: parsers test clean

parsers: $(PARSERS) queries/vba

build:
	mkdir -p build

parser:
	mkdir -p parser

build/plenary.nvim: | build
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

build/tree-sitter-vba: | build
	git clone --depth 1 https://github.com/arrmee-wt/tree-sitter-vba $@

build/tree-sitter-html: | build
	git clone --depth 1 https://github.com/tree-sitter/tree-sitter-html $@

grammars/aspclassic/src/parser.c: grammars/aspclassic/grammar.js
	cd grammars/aspclassic && tree-sitter generate

parser/aspclassic.so: grammars/aspclassic/src/parser.c | parser
	$(CC) $(CFLAGS) -Igrammars/aspclassic/src grammars/aspclassic/src/*.c -o $@

parser/vba.so: | build/tree-sitter-vba parser
	$(CC) $(CFLAGS) -Ibuild/tree-sitter-vba/src build/tree-sitter-vba/src/*.c -o $@

parser/html.so: | build/tree-sitter-html parser
	$(CC) $(CFLAGS) -Ibuild/tree-sitter-html/src build/tree-sitter-html/src/*.c -o $@

# Queries de resaltado de VBA, tomadas del propio repo de la gramática.
queries/vba: | build/tree-sitter-vba
	mkdir -p queries/vba
	cp build/tree-sitter-vba/queries/*.scm queries/vba/

test: parsers build/plenary.nvim
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }"

clean:
	rm -rf parser build grammars/aspclassic/src
```

Notas para el implementador:
- Si alguna gramática externa trae `src/scanner.cc` (C++) en lugar de `scanner.c`, el link con `cc` falla: compilar ese parser con `c++` en su lugar. A la fecha del plan ambas usan C.
- Neovim busca parsers en `parser/*.so` dentro del runtimepath; el plugin ya está en el runtimepath por `tests/minimal_init.lua`, así que no hace falta registrar rutas.
- Si las queries copiadas de `queries/vba/` usan capturas que el Neovim del usuario no conoce, Neovim las ignora sin romper; si alguna query no compila (predicados no soportados), eliminar ese archivo `.scm` y anotar el ajuste pendiente para la Fase 2.

- [ ] **Step 4: Compilar y verificar que los tests pasan**

Run: `make test`
Expected: compila los tres parsers y PASS (5 tests en total: 2 de filetype + 3 de parsers).

- [ ] **Step 5: Commit**

```bash
git add Makefile tests/spec/parser_spec.lua
git commit -m "feat(build): compilación de parsers aspclassic, vba y html con carga verificada"
```

---

### Task 5: Queries de highlights/injections y arranque automático

**Files:**
- Create: `queries/aspclassic/highlights.scm`
- Create: `queries/aspclassic/injections.scm`
- Modify: `plugin/asp.lua`
- Create: `tests/spec/injection_spec.lua`

**Interfaces:**
- Consumes: nodos de las Tasks 2–3 (`content`, `code`, `include_directive`, `include_kind`, `quoted_path`, `directive_attributes`); parsers de la Task 4.
- Produces: al abrir un buffer con filetype `asp`, treesitter queda activo con lenguaje `aspclassic` e injections `html` (contenido) y `vba` (código). La Task 6 y todas las fases futuras asumen este arranque.

- [ ] **Step 1: Escribir los tests (fallarán)**

`tests/spec/injection_spec.lua`:

```lua
describe('treesitter en buffers asp', function()
  before_each(function()
    vim.cmd.edit('tests/fixtures/basic.asp')
  end)

  after_each(function()
    vim.cmd('bwipeout!')
  end)

  it('arranca el parser aspclassic para el filetype asp', function()
    local ok, parser = pcall(vim.treesitter.get_parser, 0)
    assert.is_true(ok)
    assert.are.equal('aspclassic', parser:lang())
  end)

  it('inyecta html y vba', function()
    local parser = vim.treesitter.get_parser(0)
    parser:parse(true)
    local langs = {}
    for lang in pairs(parser:children()) do
      langs[lang] = true
    end
    assert.is_true(langs.html, 'esperaba injection html')
    assert.is_true(langs.vba, 'esperaba injection vba')
  end)

  it('las queries de aspclassic compilan', function()
    assert.is_not_nil(vim.treesitter.query.get('aspclassic', 'highlights'))
    assert.is_not_nil(vim.treesitter.query.get('aspclassic', 'injections'))
  end)
end)
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

Run: `make test`
Expected: FAIL — `get_parser` no resuelve lenguaje para el filetype `asp` (no está registrado) y no existen queries.

- [ ] **Step 3: Implementar queries y arranque**

`queries/aspclassic/highlights.scm`:

```scm
[
  "<%"
  "<%="
  "<%@"
  "%>"
] @keyword.directive

"<!--#include" @keyword.import

"-->" @keyword.import

(include_kind) @variable.parameter

(quoted_path) @string.special.path

(directive_attributes) @attribute
```

`queries/aspclassic/injections.scm`:

```scm
; Todo el contenido fuera de <% %> es HTML (un solo árbol combinado,
; para que el HTML partido por bloques ASP parse como documento único).
((content) @injection.content
  (#set! injection.combined)
  (#set! injection.language "html"))

; Todo el código de <% %> y <%= %> es VBScript (Fase 1: gramática vba).
; También combinado: patrones como <% If x Then %>...<% End If %>
; forman un solo programa.
((code) @injection.content
  (#set! injection.combined)
  (#set! injection.language "vba"))
```

`plugin/asp.lua` (reemplazo completo):

```lua
if vim.g.loaded_asp_nvim then
  return
end
vim.g.loaded_asp_nvim = true

vim.filetype.add({
  extension = {
    asp = 'asp',
    inc = 'asp',
  },
})

vim.treesitter.language.register('aspclassic', 'asp')

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'asp',
  group = vim.api.nvim_create_augroup('asp_nvim', { clear = true }),
  callback = function(args)
    -- pcall: si el parser no está compilado aún, no romper la apertura
    -- del buffer; :checkhealth asp (Task 6) diagnostica el motivo.
    pcall(vim.treesitter.start, args.buf, 'aspclassic')
  end,
})
```

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `make test`
Expected: PASS (8 tests en total).

- [ ] **Step 5: Commit**

```bash
git add queries/aspclassic plugin/asp.lua tests/spec/injection_spec.lua
git commit -m "feat: highlights e injections html/vba con arranque automático de treesitter"
```

---

### Task 6: Health check, setup(), README y verificación manual

**Files:**
- Create: `lua/asp/init.lua`
- Create: `lua/asp/health.lua`
- Create: `README.md`
- Test: `tests/spec/health_spec.lua`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: `require('asp').setup(opts)` (tabla `opts` opcional, hoy sin claves: es el punto de extensión para la raíz virtual de la Fase 4); `:checkhealth asp`; README con instalación vía lazy.nvim.

- [ ] **Step 1: Escribir el test (fallará)**

`tests/spec/health_spec.lua`:

```lua
describe('modulo asp', function()
  it('setup() no explota sin opciones', function()
    assert.is_true((pcall(require('asp').setup)))
  end)

  it('health.check existe', function()
    assert.is_function(require('asp.health').check)
  end)
end)
```

- [ ] **Step 2: Correr los tests y verificar que fallan**

Run: `make test`
Expected: FAIL — `module 'asp' not found`.

- [ ] **Step 3: Implementar los módulos**

`lua/asp/init.lua`:

```lua
local M = {}

M.options = {}

--- Configura asp.nvim. Hoy no hay opciones; la tabla se reserva para
--- la configuración de la raíz virtual de includes (Fase 4).
---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.options, opts or {})
end

return M
```

`lua/asp/health.lua`:

```lua
local M = {}

function M.check()
  local health = vim.health

  health.start('asp.nvim')

  if vim.fn.has('nvim-0.10') == 1 then
    health.ok('Neovim >= 0.10')
  else
    health.error('asp.nvim requiere Neovim >= 0.10')
  end

  for _, lang in ipairs({ 'aspclassic', 'vba', 'html' }) do
    if pcall(vim.treesitter.language.add, lang) then
      health.ok(('parser %s encontrado'):format(lang))
    else
      health.error(
        ('parser %s no encontrado'):format(lang),
        { 'Ejecuta `make parsers` en el directorio del plugin.' }
      )
    end
  end

  for _, lang in ipairs({ 'javascript', 'css' }) do
    if pcall(vim.treesitter.language.add, lang) then
      health.ok(('parser %s encontrado (resaltado dentro de <script>/<style>)'):format(lang))
    else
      health.warn(
        ('parser %s no encontrado'):format(lang),
        { 'Instálalo con nvim-treesitter (`:TSInstall ' .. lang .. '`) para resaltar el JavaScript/CSS del cliente.' }
      )
    end
  end
end

return M
```

`README.md`:

```markdown
# asp.nvim

Soporte de Classic ASP (VBScript + HTML + JavaScript) para Neovim:
resaltado por regiones vía tree-sitter. Fases futuras: go-to-definition
con resolución de `<!--#include -->` (ver `docs/superpowers/specs/`).

## Requisitos

- Neovim >= 0.10
- `cc` y `git` (para compilar los parsers)
- Parsers `javascript` y `css` instalados (p. ej. con nvim-treesitter)
  para el código de cliente dentro de `<script>`/`<style>`.

## Instalación (lazy.nvim)

```lua
{
  'erikwco/asp.nvim',
  build = 'make parsers',
  ft = 'asp',
  opts = {},
}
```

## Verificación

`:checkhealth asp`
```

- [ ] **Step 4: Correr los tests y verificar que pasan**

Run: `make test`
Expected: PASS (10 tests en total).

- [ ] **Step 5: Verificación manual de la fase completa**

```bash
nvim -u tests/minimal_init.lua tests/fixtures/basic.asp
```

Checklist dentro de Neovim:
1. `:Inspect` sobre `Response.Write` → debe mostrar capturas del lenguaje `vba`.
2. `:Inspect` sobre `<html>` → capturas del lenguaje `html`.
3. `:Inspect` sobre `<%` → captura `@keyword.directive` de `aspclassic`.
4. `:Inspect` sobre `"lib/helpers.asp"` → captura `@string.special.path`.
5. `:checkhealth asp` → todo `OK` salvo warns esperables de javascript/css.

Expected: los 5 puntos se cumplen; si alguno falla, es un bug de esta fase — no continuar sin resolverlo.

- [ ] **Step 6: Commit**

```bash
git add lua README.md tests/spec/health_spec.lua
git commit -m "feat: setup(), checkhealth y README — cierre de Fase 1"
```
