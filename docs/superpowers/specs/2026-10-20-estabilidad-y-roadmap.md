# Spec: release de estabilidad 0.6 y roadmap de 7 cambios (asp.nvim)

Fecha: 2026-10-20. Estado: aprobada por Erik. Autor: Claude Fable 5.1.

Continúa a `2026-07-16-asp-neovim-design.md` y a
`2026-10-20-navegacion-js-y-paginas.md`. Primero se paga la deuda acumulada
(release 0.6), después se encaran los siete cambios en el orden de relevancia
que fijó Erik. Cada ítem es un PR (o una serie corta) con revisión cruzada
(Astra ↔ Claude) y revisión final.

## Reglas comunes

- Handlers de `asp-ls` nunca lanzan; cada capa devuelve nil cuando la
  posición no es suya. Cadena de `lsp.lua`: symbols → js → pages.
- Suite verde (`make test`) y CI verde en cada PR; docs (`README.md`,
  `doc/asp.txt`) al día con capacidades y límites.
- Los `.asp` propietarios bajo `asp/` no se commitean.
- Nada de parseo de capas innecesarias desde disco (solo lo que la
  consulta necesita), caché por mtime+tamaño, invalidación en `BufWritePost`.

## Parte 1: release de estabilidad 0.6 (backlog)

### E1. Compatibilidad real con Neovim 0.10

- `lua/asp/health.lua`: en 0.10 `vim.treesitter.language.add` no devuelve
  nada al cargar bien y lanza si falta; en 0.11+ devuelve true/nil+err.
  Reportar bien en ambos (hoy en 0.10 dice que faltan parsers que están).
- `tests/spec/parser_spec.lua` (3 fallos) y
  `tests/spec/pages_references_spec.lua:393` (entradas de `scandir` sin tipo):
  hacerlos correctos en 0.10 sin debilitar lo que afirman.
- `.github/workflows/ci.yml`: sumar `v0.10.4` a la matriz (ubuntu y macOS).
- Verificar que `make test` pasa completo en 0.10.4 y en 0.12.

### E2. Caché del grafo de includes y tope de caché de JS

- `lua/asp/includes.lua`: cachear por archivo (mtime+tamaño) la lista de
  includes extraída de disco (`includes_of(abs_path)` sin buffer), con
  `invalidate(path)` desde `BufWritePost`. `graph`/`buffer_graph` siguen
  recorriendo, pero sin releer ni reparsear archivos sin cambios.
- `lua/asp/js.lua`: el tope `FILE_CACHE_MAX` pasa a ser
  `max(64, tamaño del conjunto de la consulta)`, para que una página con
  más de 64 externos no haga thrash.
- Medir antes/después: definición JS cross-file en caliente con 20 y 100
  includes; `symbols.definition` cross-file VBScript con 100 includes.

### E3. Cierre de release

- `textDocument/documentHighlight`: ocurrencias del símbolo bajo el cursor
  en el buffer actual (VBScript y JS), derivado de `references` filtrado al
  uri propio; capability anunciada.
- `serverInfo.version` → `0.6.0`; README: reemplazar "cinco fases" por la
  lista de capacidades actual; `doc/asp.txt` con changelog breve.
- Regenerar los GIFs de `demo/` con vhs y agregar uno para la navegación
  JS y páginas.

## Parte 2: roadmap de 7 cambios, por relevancia

1. **Usos de VBScript en todo el sitio.** `references` desde una librería
   (`helpers.asp`) encuentra las llamadas en todas las páginas que la
   incluyen, directa o transitivamente, usando el índice inverso de
   includes de `pages`. Prioridad y scope como hoy; caché por mtime.
2. **Diagnósticos de VBScript.** Errores de sintaxis (nodos `ERROR` de la
   capa vbscript), variables sin `Dim` bajo `Option Explicit`, llamadas a
   funciones/subs que no existen en la página ni en su grafo de includes,
   enlaces a páginas inexistentes (literales de `pages`). Severidades
   configurables; sin falsos positivos ruidosos (intrínsecos, `Eval`,
   `Execute`, objetos COM).
3. **Ayuda de funciones nativas y objetos COM.** Hover, completion y
   `textDocument/signatureHelp` para las funciones nativas de VBScript
   (`Len`, `Mid`, `Replace`, `CDate`, `FormatNumber`, ...), constantes
   (`vbCrLf`, ...) y los objetos de `Server.CreateObject` más usados
   (`ADODB.Connection`, `ADODB.Recordset`, `ADODB.Command`,
   `Scripting.FileSystemObject`, `Scripting.Dictionary`, `MSXML2.*`,
   `CDO.Message`), con inferencia simple del tipo por `Set x =
   Server.CreateObject("...")`. signatureHelp también para funciones/subs
   del usuario.
4. **Renombrar símbolos.** `textDocument/rename` para VBScript y JS,
   scope-aware y cross-file (alcance de 1), con `prepareRename`.
5. **Completion y hover de JavaScript.** Símbolos globales de la página,
   sus `.js` e includes; firma de funciones JS en hover; miembros de
   `document`/`window` básicos.
6. **Plegado e indentación de VBScript por tree-sitter.** `folds.scm` e
   `indents.scm` para `vbscript` (Sub/Function/Class/If/For/Do/Select/
   With) y `aspclassic`, coordinados con html.
7. **Resaltado semántico y pulido final.** `textDocument/semanticTokens`
   para distinguir funciones del usuario, parámetros y clases en VBScript
   y JS; revisión de rendimiento de la primera consulta en buffers enormes
   (parseo diferido de capas que no se usan).

## Heredado del resolver

- Dentro de un método de clase, un miembro `Private total` pierde contra
  un `Dim total` de página. Revisar la precedencia entre miembros y página.
- En un buffer sin nombre, el URI `file://` resuelve a otro buffer y los
  handlers devuelven vacío. Definir cómo identificar estos buffers antes
  de ampliar la navegación a archivos sin guardar.
- En las referencias con alcance de sitio, un miembro `Private Hit` de
  una clase y sus usos dentro de un método se cuentan junto con el `Hit`
  global homónimo. El filtro de sombreado de los archivos de disco
  (`parse_occurrences` en `asp.symbols`) solo mira los locales de
  Sub/Function/Property (`scope_id`), no los miembros de clase. Es el
  mismo problema de precedencia del punto anterior.
- `documentHighlight` de un símbolo declarado en un include hace dos
  lecturas de disco en frío: sin declaración en el buffer llama a
  `definition`, que lee las directivas del grafo y parsea el include.

Estos casos quedan para el roadmap y no se corrigen en la release 0.6.

## Fuera de alcance

Windows (sigue como backlog aparte), JScript de servidor, formateo de
código, resolución por tipos en JS más allá de lo descrito en 3 y 5.
