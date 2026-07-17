# asp.nvim — Fase 2: gramática tree-sitter-vbscript (fork GPL) — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reemplazar la gramática VBA provisional por un fork `vbscript` que parsee VBScript real de Classic ASP (statements a nivel de script, `If` de una línea, argumentos omitidos, `Class`) con resaltado completo incluyendo keywords.

**Architecture:** Se vendoriza el `grammar.js` de arrmee-wt/tree-sitter-vba (GPL-3.0, 254 líneas, sin scanner externo) en `grammars/vbscript/` y se modifica mediante corpus TDD: cada task introduce casos de corpus derivados de ASP real (anonimizados) que fallan, y el cambio de gramática mínimo que los hace pasar. Al final se cambia la injection `vba`→`vbscript`, se elimina vba del build y se documenta el licenciamiento dividido (plugin MIT; `grammars/vbscript/` GPL-3.0).

**Tech Stack:** tree-sitter CLI 0.26, Lua/Neovim ≥0.10, plenary, Make.

**Diagnóstico que motiva este plan** (verificado el 2026-07-16 con `asp/default_bodega.asp`, 1228 líneas reales): la capa `aspclassic` parsea el archivo con 0 errores; el VBScript extraído colapsa en un ERROR único con la gramática VBA porque VBA solo admite declaraciones a nivel de módulo. Además la gramática VBA **carece de**: `Class`, `If ... Then stmt` de una línea y argumentos omitidos (`f a,,b`); y **le sobra** el tipado `As Type`.

## Global Constraints

- Nombre del parser/lenguaje nuevo: **`vbscript`**; vive en `grammars/vbscript/` del monorepo.
- **Licenciamiento dividido**: `grammars/vbscript/` es GPL-3.0 (fork de https://github.com/arrmee-wt/tree-sitter-vba — conservar LICENSE y atribución; declarar los cambios per GPL §5). El resto del plugin sigue MIT. Ambos README deben decirlo.
- La gramática upstream usa el helper `ci(word)` (regex case-insensitive) y NO tiene scanner externo ni campo `externals` — mantener así.
- Identificadores y keywords son **case-insensitive** (`option explicit` = `Option Explicit`).
- `parser/`, `build/`, `grammars/*/src/`, `node_modules/` son artefactos generados (gitignored). La carpeta `asp/` (código propietario del usuario para diagnóstico) también va gitignored y NUNCA se commitea; el corpus usa versiones anonimizadas.
- Flujo de corpus TDD para gramáticas (aplica a toda task de gramática): escribir el caso de corpus con un árbol esperado aproximado → `tree-sitter generate && tree-sitter test` para ver RED → editar la gramática → verificar con `tree-sitter parse` que el árbol contiene los **nodos obligatorios** del caso y ningún `ERROR`/`MISSING` → `tree-sitter test --update` → suite completa verde. Un caso solo se da por bueno si sus nodos obligatorios aparecen; nunca aceptar un árbol degenerado vía `--update`.
- Al terminar cada task: `make clean && make test` verde (la suite plenary completa de la Fase 1 más lo nuevo), sin hardcodear conteos de tests de tasks ajenas.
- Neovim ≥ 0.10; los fixes de Fase 1 se conservan (semántica `language.add` con segundo retorno; `ftdetect/`; `make parsers` sin html.so).

---

### Task 1: Vendorizar el fork GPL y compilarlo como `vbscript`

**Files:**
- Create: `grammars/vbscript/grammar.js` (copiado de `build/tree-sitter-vba/grammar.js`, renombrado)
- Create: `grammars/vbscript/LICENSE` (copia del GPL-3.0 upstream)
- Create: `grammars/vbscript/NOTICE.md`
- Create: `grammars/vbscript/tree-sitter.json`
- Create: `grammars/vbscript/package.json`
- Create: `grammars/vbscript/test/corpus/smoke.txt`
- Modify: `Makefile` (target `parser/vbscript.so`; NO tocar aún los targets de vba)
- Modify: `.gitignore` (añadir `asp/` y `grammars/vbscript/src/`)
- Test: `tests/spec/parser_spec.lua` (añadir spec de carga de `vbscript`)

**Interfaces:**
- Consumes: `build/tree-sitter-vba/` (lo clona `make parsers` si falta).
- Produces: lenguaje `vbscript` compilable y cargable; `grammars/vbscript/grammar.js` con `name: 'vbscript'` — todas las tasks siguientes editan ese archivo. El helper `ci(word)` (línea ~9) queda intacto hasta la Task 7.

- [ ] **Step 1: Test de carga que falla**

Añadir a `tests/spec/parser_spec.lua`, dentro del `describe('parsers', ...)` existente:

```lua
  it('carga el parser vbscript', function()
    local ok, added = pcall(vim.treesitter.language.add, 'vbscript')
    assert.is_true(ok and added == true)
  end)
```

Run: `make test`
Expected: FAIL — no existe `parser/vbscript.so`.

- [ ] **Step 2: Vendorizar la gramática**

```bash
make build/tree-sitter-vba
mkdir -p grammars/vbscript/test/corpus
cp build/tree-sitter-vba/grammar.js grammars/vbscript/grammar.js
cp build/tree-sitter-vba/LICENSE grammars/vbscript/LICENSE
```

En `grammars/vbscript/grammar.js`: cambiar `name: 'vba'` por `name: 'vbscript'` y añadir al tope del archivo (encima del comentario existente, sin borrarlo):

```js
// tree-sitter-vbscript — fork of arrmee-wt/tree-sitter-vba (GPL-3.0)
// adapted for VBScript as used in Classic ASP. Changes from upstream are
// tracked in NOTICE.md (GPL v3 §5). This directory is GPL-3.0; the rest
// of the asp.nvim repository is MIT.
```

`grammars/vbscript/NOTICE.md`:

```markdown
# NOTICE — tree-sitter-vbscript

Fork of [arrmee-wt/tree-sitter-vba](https://github.com/arrmee-wt/tree-sitter-vba)
(GPL-3.0). Modificaciones para VBScript/Classic ASP (GPL v3 §5):

- Renombrado `vba` → `vbscript`.
- (las tasks siguientes añaden aquí una línea por cambio)
```

`grammars/vbscript/package.json`:

```json
{
  "name": "tree-sitter-vbscript",
  "version": "0.1.0",
  "description": "Tree-sitter grammar for VBScript (Classic ASP), fork of tree-sitter-vba",
  "license": "GPL-3.0",
  "main": "bindings/node",
  "dependencies": {}
}
```

`grammars/vbscript/tree-sitter.json`:

```json
{
  "grammars": [
    {
      "name": "vbscript",
      "camelcase": "VBScript",
      "scope": "source.vbscript",
      "file-types": ["vbs"],
      "injection-regex": "^(vb|vbs|vbscript)$"
    }
  ],
  "metadata": {
    "version": "0.1.0",
    "license": "GPL-3.0",
    "description": "Tree-sitter grammar for VBScript (Classic ASP)"
  }
}
```

`grammars/vbscript/test/corpus/smoke.txt`:

```
==================
smoke: option y dim a nivel de script
==================
option explicit
dim Objeto,tipoVentana,vParcialesActivos
---

(source_file
  (option_statement)
  (dim_statement
    (identifier)
    (identifier)
    (identifier)))
```

Nodos obligatorios del caso: `option_statement`, `dim_statement` con 3 `identifier`. (Ambos son declaraciones, admitidas ya a nivel de módulo — este caso debe pasar SIN tocar reglas; si el árbol difiere en forma pero contiene los nodos obligatorios, `--update`.)

```bash
cd grammars/vbscript && tree-sitter generate && tree-sitter test
```

Expected: PASS (1 caso).

- [ ] **Step 3: Makefile y .gitignore**

En `.gitignore` añadir:

```gitignore
asp/
grammars/vbscript/src/
grammars/vbscript/node_modules/
```

En `Makefile`: añadir `parser/vbscript.so` a `PARSERS` (queda `parser/aspclassic.so parser/vba.so parser/vbscript.so` — vba se elimina en la Task 8) y el target:

```make
grammars/vbscript/src/parser.c: grammars/vbscript/grammar.js
	cd grammars/vbscript && tree-sitter generate

parser/vbscript.so: grammars/vbscript/src/parser.c | parser
	$(CC) $(CFLAGS) -Igrammars/vbscript/src grammars/vbscript/src/*.c -o $@
```

- [ ] **Step 4: Verificar que los tests pasan**

Run: `make test`
Expected: PASS — la suite previa completa + el spec nuevo de `vbscript`.

- [ ] **Step 5: Commit**

```bash
git add grammars/vbscript Makefile .gitignore tests/spec/parser_spec.lua
git commit -m "feat(vbscript): fork GPL-3.0 de tree-sitter-vba vendorizado como gramática vbscript"
```

---

### Task 2: Statements ejecutables a nivel de script

**Files:**
- Modify: `grammars/vbscript/grammar.js` (reglas `source_file` y `_module_scope`)
- Create: `grammars/vbscript/test/corpus/script_level.txt`
- Modify: `grammars/vbscript/NOTICE.md` (una línea)

**Interfaces:**
- Consumes: fork de la Task 1. Upstream define `source_file: $ => repeat($._module_scope)` y `_module_scope` como choice cerrado de 8 declaraciones (líneas ~24-34); existe una regla `_statement` (líneas ~113-123) hoy muerta que duplica el choice de `block`.
- Produces: `source_file` acepta statements ejecutables; las reglas VBA-only `declare_statement`, `type_statement`, `enum_statement` quedan eliminadas. Las Tasks 3–6 asumen esta forma de `source_file`.

- [ ] **Step 1: Corpus que falla**

`grammars/vbscript/test/corpus/script_level.txt` (derivado anonimizado del ASP real):

```
==================
asignaciones y llamadas a nivel de script
==================
Response.Expires = -1
Response.AddHeader "pragma","no-cache"
Response.buffer=true
---

(source_file
  (let_statement)
  (call_statement)
  (let_statement))

==================
set con createobject
==================
Set Objeto = server.CreateObject("Vendor.Componente")
---

(source_file
  (set_statement))

==================
asignacion a default property
==================
session("SerieEmpty") = ""
tipoVentana = trim(request("tipoVentana"))
---

(source_file
  (let_statement)
  (let_statement))
```

Nodos obligatorios por caso: (1) `let_statement`×2 y `call_statement` (o `expression` si la llamada sin paréntesis parsea como expresión — anotar cuál); (2) `set_statement`; (3) `let_statement`×2. Los árboles esperados de arriba son hipótesis: validar forma real con `tree-sitter parse` y `--update` solo si los nodos obligatorios están y no hay `ERROR`.

Run: `cd grammars/vbscript && tree-sitter test`
Expected: FAIL — los tres casos producen `ERROR` (statements no admitidos a nivel de módulo).

- [ ] **Step 2: Editar la gramática**

Reemplazar `source_file` y eliminar `_module_scope` (y con él las alternativas VBA-only). Quedar así:

```js
    source_file: $ => repeat(choice(
      $.option_statement,
      $.sub_statement,
      $.function_statement,
      $.property_statement,
      $._statement,
    )),
```

(`$._statement` ya incluye `dim_statement` y `const_statement`, por eso no se repiten — repetirlos crearía conflicto de choice.) Eliminar las reglas `declare_statement`, `type_statement` y `enum_statement` completas (VBScript no las tiene) y cualquier referencia a ellas.

En `NOTICE.md` añadir: `- source_file acepta statements ejecutables (script, no módulo); eliminadas declare/type/enum.`

- [ ] **Step 3: Verificar RED→GREEN y suite completa**

```bash
cd grammars/vbscript && tree-sitter generate && tree-sitter test
```

Expected: PASS todos los casos (smoke + script_level). Después `make clean && make test` → PASS.

- [ ] **Step 4: Commit**

```bash
git add grammars/vbscript
git commit -m "feat(vbscript): statements ejecutables a nivel de script; fuera declare/type/enum"
```

---

### Task 3: If de una línea

**Files:**
- Modify: `grammars/vbscript/grammar.js` (regla `if_statement`)
- Create: `grammars/vbscript/test/corpus/inline_if.txt`
- Modify: `grammars/vbscript/NOTICE.md` (una línea)

**Interfaces:**
- Consumes: `if_statement` upstream (líneas ~133-139) exige `Then` + `$.block` + `End If`, sin forma inline.
- Produces: `if_statement` con forma inline (`If cond Then stmt [Else stmt]`, sin `End If`). La Task 5 puede añadir `:` como separador sin tocar esta regla.

- [ ] **Step 1: Corpus que falla**

`grammars/vbscript/test/corpus/inline_if.txt`:

```
==================
if de una linea
==================
if len(vParcialesActivos)=0 then vParcialesActivos = "N"
---

(source_file
  (if_statement))

==================
if de una linea con else
==================
If x > 0 Then y = 1 Else y = 2
---

(source_file
  (if_statement))

==================
if en bloque sigue funcionando
==================
If x > 0 Then
  y = 1
End If
---

(source_file
  (if_statement))
```

Nodos obligatorios: `if_statement` en los tres, sin `ERROR`/`MISSING`, y el statement interior visible (p. ej. `let_statement`) dentro del `if_statement`.

Run: `cd grammars/vbscript && tree-sitter test`
Expected: FAIL en los dos primeros (la forma inline no existe); el tercero PASS.

- [ ] **Step 2: Editar la gramática**

Reemplazar `if_statement` por dos formas (conservando la de bloque tal como está hoy, solo movida a `_block_if`):

```js
    if_statement: $ => choice($._block_if, $._inline_if),

    _block_if: $ => seq(
      // cuerpo EXACTO del if_statement upstream actual, sin cambios
    ),

    _inline_if: $ => prec.right(seq(
      ci('If'), $.expression, ci('Then'),
      $._statement,
      optional(seq(ci('Else'), $._statement)),
    )),
```

(El implementador copia el cuerpo actual de `if_statement` dentro de `_block_if` sin modificarlo.) Si `tree-sitter generate` reporta conflicto entre ambas formas (ambas empiezan `If expr Then`), declararlo para GLR añadiendo al grammar:

```js
  conflicts: $ => [
    [$._block_if, $._inline_if],
  ],
```

y verificar con el corpus que GLR resuelve por presencia/ausencia de `End If`. Si el conflicto no se resuelve con esto, **reportar BLOCKED con el error exacto** — no restructurar el manejo de newlines por cuenta propia.

En `NOTICE.md`: `- if_statement admite forma inline de una línea (sin End If).`

- [ ] **Step 3: Verificar y suite completa**

```bash
cd grammars/vbscript && tree-sitter generate && tree-sitter test
```
Expected: PASS (los 3 casos + corpus previo). Después `make clean && make test` → PASS.

- [ ] **Step 4: Commit**

```bash
git add grammars/vbscript
git commit -m "feat(vbscript): If de una línea"
```

---

### Task 4: Argumentos omitidos en llamadas

**Files:**
- Modify: `grammars/vbscript/grammar.js` (regla `_arg_expression_list`)
- Create: `grammars/vbscript/test/corpus/omitted_args.txt`
- Modify: `grammars/vbscript/NOTICE.md` (una línea)

**Interfaces:**
- Consumes: `_arg_expression_list` upstream (línea ~233): `seq($.expression, repeat(seq(',', $.expression)))` — sin huecos.
- Produces: `_arg_expression_list` admite huecos (`a,,b`, `,b`, `a,`). Usada por `function_call`, `call_expression` y `call_statement` sin cambios en esos call sites.

- [ ] **Step 1: Corpus que falla**

`grammars/vbscript/test/corpus/omitted_args.txt` (patrón real: `Objeto.MakeSelect "lb_empresa","select ...",1,,"","Seleccione .."`):

```
==================
llamada sin parentesis con argumento omitido
==================
Objeto.MakeSelect "lb_empresa","select 1 from dual",1,,"","Seleccione .."
---

(source_file
  (call_statement))

==================
llamada con parentesis y hueco
==================
x = f(1,,3)
---

(source_file
  (let_statement))
```

Nodos obligatorios: caso 1 `call_statement` (con su lista de argumentos, huecos incluidos) sin `ERROR`; caso 2 `let_statement` conteniendo `function_call` sin `ERROR`.

Run: `cd grammars/vbscript && tree-sitter test`
Expected: FAIL — `,,` produce `ERROR`.

- [ ] **Step 2: Editar la gramática**

```js
    _arg_expression_list: $ => choice(
      seq($.expression, repeat(seq(',', optional($.expression)))),
      repeat1(seq(',', optional($.expression))),
    ),
```

En `NOTICE.md`: `- _arg_expression_list admite argumentos omitidos (f a,,b).`

- [ ] **Step 3: Verificar y suite completa**

```bash
cd grammars/vbscript && tree-sitter generate && tree-sitter test
```
Expected: PASS todo el corpus. Después `make clean && make test` → PASS.

- [ ] **Step 4: Commit**

```bash
git add grammars/vbscript
git commit -m "feat(vbscript): argumentos omitidos en listas de llamada"
```

---

### Task 5: VBScript-only — fuera `As Type`, dentro literales de fecha y separador `:`

**Files:**
- Modify: `grammars/vbscript/grammar.js`
- Create: `grammars/vbscript/test/corpus/vbscript_only.txt`
- Modify: `grammars/vbscript/NOTICE.md` (tres líneas)

**Interfaces:**
- Consumes: upstream tiene `optional(seq(ci('As'), $.type))` en `dim_statement` (~L189), `const_statement` (~L198), `function_statement` (~L63), `property_statement` (~L71) y `_arg` (~L95), con `type: $ => $.identifier` (~L99).
- Produces: sin tipado `As`; `date_literal` como expresión primaria; `':'` en `extras` (separador de statements). La Task 7 no depende de esto.

- [ ] **Step 1: Corpus que falla**

`grammars/vbscript/test/corpus/vbscript_only.txt`:

```
==================
dim con as debe ser error en vbscript
:error
==================
Dim x As Integer
---

==================
literal de fecha
==================
fecha = #2026-07-16#
---

(source_file
  (let_statement))

==================
dos statements en una linea con dos puntos
==================
a = 1 : b = 2
---

(source_file
  (let_statement)
  (let_statement))
```

(El primer caso usa el marcador `:error` del corpus de tree-sitter: se espera que NO parsee limpio.) Nodos obligatorios: caso 2 `let_statement` con `date_literal` dentro; caso 3 dos `let_statement` sin `ERROR`.

Run: `cd grammars/vbscript && tree-sitter test`
Expected: FAIL — caso 1 parsea limpio (aún admite `As`), caso 2 `ERROR` (no hay date_literal), caso 3 `ERROR`.

- [ ] **Step 2: Editar la gramática**

1. Eliminar `optional(seq(ci('As'), $.type))` de `dim_statement`, `const_statement`, `function_statement`, `property_statement` y `_arg`; eliminar la regla `type`.
2. Añadir a la regla de expresiones primarias (donde están `number_literal`/`string_literal`):

```js
    date_literal: () => /#[^#\r\n]+#/,
```

y sumar `$.date_literal` al choice de la expresión primaria.
3. Añadir `':'` al array `extras` existente del grammar (junto a whitespace/comentarios/continuación de línea).

En `NOTICE.md`:
```
- Eliminado el tipado As Type (no existe en VBScript).
- Añadido date_literal (#...#).
- ':' tratado como separador de statements (extras).
```

- [ ] **Step 3: Verificar y suite completa**

```bash
cd grammars/vbscript && tree-sitter generate && tree-sitter test
```
Expected: PASS todo el corpus (incluido el caso `:error`). Después `make clean && make test` → PASS.

- [ ] **Step 4: Commit**

```bash
git add grammars/vbscript
git commit -m "feat(vbscript): sin As Type; date literals y separador ':'"
```

---

### Task 6: Class ... End Class

**Files:**
- Modify: `grammars/vbscript/grammar.js` (nueva regla `class_statement` + choice de `source_file`)
- Create: `grammars/vbscript/test/corpus/classes.txt`
- Modify: `grammars/vbscript/NOTICE.md` (una línea)

**Interfaces:**
- Consumes: `source_file` de la Task 2; `sub_statement`/`function_statement`/`property_statement`/`dim_statement`/`const_statement` upstream.
- Produces: nodo `class_statement` con `name: (identifier)` — la Fase 3 (documentSymbol del LSP) usará este nodo y ese field.

- [ ] **Step 1: Corpus que falla**

`grammars/vbscript/test/corpus/classes.txt`:

```
==================
clase con campo, property y metodo
==================
Class Pedido
  Private m_total

  Public Property Get Total
    Total = m_total
  End Property

  Public Sub Agregar(monto)
    m_total = m_total + monto
  End Sub
End Class
---

(source_file
  (class_statement
    name: (identifier)
    (dim_statement
      (identifier))
    (property_statement)
    (sub_statement)))
```

Nodos obligatorios: `class_statement` con field `name`, y dentro `dim_statement`, `property_statement`, `sub_statement`; sin `ERROR`. (La forma exacta de los hijos puede variar — validar con `tree-sitter parse` y `--update`.)

Run: `cd grammars/vbscript && tree-sitter test`
Expected: FAIL — `Class` no existe en la gramática.

- [ ] **Step 2: Editar la gramática**

Nueva regla (junto a `sub_statement`):

```js
    class_statement: $ => seq(
      ci('Class'), field('name', $.identifier),
      repeat(choice(
        $.dim_statement,
        $.const_statement,
        $.sub_statement,
        $.function_statement,
        $.property_statement,
      )),
      ci('End'), ci('Class'),
    ),
```

y añadir `$.class_statement` al choice de `source_file`.

En `NOTICE.md`: `- Añadido class_statement (Class ... End Class de VBScript).`

- [ ] **Step 3: Verificar y suite completa**

```bash
cd grammars/vbscript && tree-sitter generate && tree-sitter test
```
Expected: PASS. Después `make clean && make test` → PASS.

- [ ] **Step 4: Commit**

```bash
git add grammars/vbscript
git commit -m "feat(vbscript): Class ... End Class"
```

---

### Task 7: Keywords consultables y highlights completos

**Files:**
- Modify: `grammars/vbscript/grammar.js` (helper `ci`)
- Create: `queries/vbscript/highlights.scm`
- Modify: `grammars/vbscript/NOTICE.md` (una línea)
- Test: `tests/spec/injection_spec.lua` (spec nuevo de query)

**Interfaces:**
- Consumes: helper upstream `function ci(word) { return new RegExp(word, 'i'); }` (~L9-11) — sus tokens no producen nodos consultables (verificado en Fase 1).
- Produces: cada keyword es un token anónimo consultable por su grafía canónica (`"If"`, `"Then"`, `"Class"`, ...); `queries/vbscript/highlights.scm` completo. La Task 8 activa estas queries al cambiar la injection.

- [ ] **Step 1: Test que falla**

Añadir a `tests/spec/injection_spec.lua`:

```lua
  it('las queries de vbscript compilan', function()
    assert.is_not_nil(vim.treesitter.query.get('vbscript', 'highlights'))
  end)
```

Run: `make test`
Expected: FAIL — no existe `queries/vbscript/highlights.scm`.

- [ ] **Step 2: Editar helper y escribir queries**

Redefinir el helper en `grammars/vbscript/grammar.js` (el alias hace el token consultable con su grafía canónica, sin cambiar la forma del árbol):

```js
function ci(word) {
  return alias(new RegExp(word, 'i'), word);
}
```

Regenerar y verificar que TODO el corpus sigue verde (los alias no cambian nodos con nombre):

```bash
cd grammars/vbscript && tree-sitter generate && tree-sitter test
```

`queries/vbscript/highlights.scm`:

```scm
(comment) @comment

(string_literal) @string

(date_literal) @string.special

(number_literal) @number

(boolean_literal) @boolean

(identifier) @variable

(member_expression
  (identifier) @variable.member)

(function_call
  (identifier) @function.call)

(sub_statement
  (identifier) @function)

(function_statement
  (identifier) @function)

(class_statement
  name: (identifier) @type)

[
  "If" "Then" "Else" "ElseIf" "End"
  "Select" "Case" "For" "To" "Step" "Next" "Each"
  "While" "Wend" "Do" "Loop" "Until"
  "With" "Exit" "GoTo" "Resume" "On" "Error"
] @keyword.conditional

[
  "Sub" "Function" "Property" "Get" "Let" "Class"
  "Dim" "Const" "Set" "ReDim" "Erase"
  "Public" "Private" "Static" "Option" "Explicit"
  "Call" "New" "ByVal" "ByRef"
] @keyword

[
  "And" "Or" "Not" "Xor" "Mod" "Is"
] @keyword.operator

[
  "=" "<" ">" "<=" ">=" "<>" "+" "-" "*" "/" "\\" "&" "^"
] @operator
```

Advertencias de ajuste (esperables, no bugs): los nombres exactos de nodos (`boolean_literal`, fields de `sub_statement`, tokens de operador presentes) deben cotejarse contra `grammars/vbscript/src/node-types.json` — eliminar del query cualquier nombre inexistente y anotarlo en el reporte. Cada grafía de keyword debe coincidir EXACTAMENTE con el argumento de `ci(...)` en grammar.js (p. ej. si upstream escribe `ci('Goto')`, la query dice `"Goto"`). El caso especial: si un keyword listado no se usa en ninguna regla, quitarlo de la query.

En `NOTICE.md`: `- ci() ahora produce tokens alias consultables por queries.`

- [ ] **Step 3: Verificar y suite completa**

Run: `make clean && make test`
Expected: PASS — suite previa + spec de query vbscript.

- [ ] **Step 4: Commit**

```bash
git add grammars/vbscript queries/vbscript tests/spec/injection_spec.lua
git commit -m "feat(vbscript): keywords consultables y highlights completos"
```

---

### Task 8: Integración — injection vbscript, adiós vba, licencias y aceptación

**Files:**
- Modify: `queries/aspclassic/injections.scm` (`"vba"` → `"vbscript"`)
- Modify: `Makefile` (eliminar vba de `PARSERS`, targets `build/tree-sitter-vba`/`parser/vba.so`/`queries/vba`; `parsers` queda `parser/aspclassic.so parser/vbscript.so`)
- Delete: `queries/vba/` (todo el directorio)
- Modify: `lua/asp/health.lua` (loop `{'aspclassic','vba','html'}` → aspclassic/vbscript según su estructura actual: aspclassic y vbscript en el loop de `make parsers`; html queda en su bloque propio)
- Modify: `tests/spec/parser_spec.lua` (eliminar spec de vba)
- Modify: `tests/spec/injection_spec.lua` (asserts `langs.vba` → `langs.vbscript`; eliminar spec de query vba)
- Create: `tests/spec/acceptance_spec.lua`
- Modify: `README.md` (sección de licencias; quitar el caveat de resaltado VBScript mínimo)
- Modify: `docs/superpowers/specs/2026-07-16-asp-neovim-design.md` (nota de licencia)

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: pipeline definitivo aspclassic+vbscript; la Fase 3 parte de aquí.

- [ ] **Step 1: Tests que fallan**

`tests/spec/acceptance_spec.lua`:

```lua
describe('aceptación fase 2', function()
  it('el vbscript del fixture parsea sin errores', function()
    vim.cmd.edit('tests/fixtures/basic.asp')
    local parser = vim.treesitter.get_parser(0)
    parser:parse(true)
    local children = parser:children()
    assert.is_not_nil(children.vbscript, 'esperaba injection vbscript')
    for _, tree in ipairs(children.vbscript:trees()) do
      assert.is_false(tree:root():has_error(),
        'el VBScript inyectado tiene nodos ERROR')
    end
    vim.cmd('bwipeout!')
  end)
end)
```

Actualizar `tests/spec/injection_spec.lua`: `langs.vba` → `langs.vbscript` (mensaje incluido) y el spec `las queries de aspclassic compilan` se mantiene.

Run: `make test`
Expected: FAIL — la injection sigue apuntando a vba.

- [ ] **Step 2: Aplicar la integración**

- `queries/aspclassic/injections.scm`: en el bloque de `(code)`, `(#set! injection.language "vba")` → `(#set! injection.language "vbscript")` y actualizar el comentario (ya no es "Fase 1: gramática vba").
- `Makefile`: `PARSERS := parser/aspclassic.so parser/vbscript.so`; eliminar los targets `build/tree-sitter-vba`, `parser/vba.so` y `queries/vba`; `parsers: $(PARSERS)` (ya sin `queries/vba`); `parsers-test: parsers parser/html.so` se mantiene.
- `git rm -r queries/vba`.
- `lua/asp/health.lua`: en el loop de parsers propios, `{ 'aspclassic', 'vba' }` → `{ 'aspclassic', 'vbscript' }` (mismo texto de consejo `make parsers`); el bloque de html y los warns de javascript/css no se tocan.
- `tests/spec/parser_spec.lua`: eliminar el spec `carga el parser vba` (queda aspclassic, vbscript, html).
- `README.md`: reemplazar el caveat de resaltado VBScript mínimo por una nota de que el VBScript se parsea con gramática propia; añadir sección `## Licencias`:

```markdown
## Licencias

- El plugin (código Lua, gramática aspclassic, queries): **MIT**.
- `grammars/vbscript/`: **GPL-3.0** — fork de
  [arrmee-wt/tree-sitter-vba](https://github.com/arrmee-wt/tree-sitter-vba);
  cambios documentados en `grammars/vbscript/NOTICE.md`.
```

- Spec (`docs/superpowers/specs/2026-07-16-asp-neovim-design.md`): en "Contexto y estado del arte", corregir la mención "(..., MIT)" de tree-sitter-vba por "(GPL-3.0; el LICENSE del repo prevalece sobre el header MIT de su grammar.js)" y en "Decisiones tomadas" añadir: `- 2026-07-16: fork GPL-3.0 aceptado para la gramática vbscript; licenciamiento dividido documentado en README.`

- [ ] **Step 3: Verificar suite completa desde cero**

Run: `make clean && make test`
Expected: PASS — todos los specs, incluido el de aceptación, con vba ausente del build.

- [ ] **Step 4: Verificación manual de cierre de fase**

```bash
nvim -u tests/minimal_init.lua tests/fixtures/basic.asp
```

1. `:Inspect` sobre `Dim` → captura `@keyword` del lenguaje `vbscript`.
2. `:Inspect` sobre `Response.Write` → capturas de `vbscript` (`@variable`/`@variable.member`/`@function.call`).
3. `:Inspect` sobre `<%` → `@keyword.directive` de `aspclassic` (regresión Fase 1).
4. `:checkhealth asp` → OK para aspclassic y vbscript; sin mención de vba.
5. Si `asp/default_bodega.asp` existe en el checkout: abrirlo y verificar visualmente resaltado de las tres capas y `:lua print(vim.treesitter.get_parser(0):children().vbscript ~= nil)` → `true`. (Archivo privado, solo verificación local.)

Expected: los 5 puntos se cumplen; cualquier fallo es bug de esta fase.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: injection vbscript definitiva, retiro de vba y licenciamiento dividido — cierre de Fase 2"
```
