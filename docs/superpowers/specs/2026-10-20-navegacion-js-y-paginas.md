# Spec: navegación JavaScript y entre páginas (asp.nvim, serie post-Fase 5)

Fecha: 2026-10-20. Estado: aprobada por Erik. Autor de la spec: Claude Fable 5.1.

## Objetivo

Que `C-]`/`vim.lsp.buf.definition()` y `references()` funcionen igual de bien
sobre el JavaScript de cliente de un `.asp` que sobre su VBScript, y que
"ir a definición" sobre una referencia a otra página (`Response.Redirect`,
`href`, `action`, `<script src>`, ...) abra ese archivo. Se entrega en
cuatro PRs independientes, en este orden:

| PR | Alcance | Módulo nuevo |
|---|---|---|
| 1 | Definición sobre literal de página (abrir el archivo referenciado) + `gf` | `lua/asp/pages.lua` |
| 2 | JS in-file: definición y referencias de símbolos JS del buffer | `lua/asp/js.lua` |
| 3 | JS cross-file: `<script src="...">` y JS dentro de páginas incluidas | extiende `js.lua` |
| 4 | Usos de una página: índice inverso de referencias y de includes | extiende `pages.lua` |

PR 1 y PR 2 se desarrollan en paralelo desde `main`. PR 3 y PR 4 arrancan
cuando 1 y 2 estén mergeados.

## Arquitectura compartida

- El servidor in-process `asp-ls` (`lua/asp/lsp.lua`) sigue siendo único.
  Cada capa expone `definition(bufnr, position)` y `references(bufnr,
  position)` con el mismo contrato que `lua/asp/symbols.lua` (Location o
  lista de Location, o `nil`).
- Los handlers encadenan capas con `or`, en este orden fijo:

  ```lua
  M.handlers['textDocument/definition'] = function(params)
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local pos = params.position
    return require('asp.symbols').definition(bufnr, pos)   -- VBScript (hoy)
      or require('asp.js').definition(bufnr, pos)         -- PR 2
      or require('asp.pages').definition(bufnr, pos)      -- PR 1
  end
  ```

  `symbols.definition` devuelve `nil` rápido si el cursor no cae en un
  `identifier` vbscript, así que un literal `"x.asp"` dentro de `<% %>`
  llega a `pages`. Mismo patrón para `references` (symbols → js → pages).
  Cada PR agrega SOLO su línea; el que mergea segundo rebasea.
- Ninguna capa depende de las queries de nvim-treesitter del usuario. En
  tests solo existen los parsers `aspclassic`, `vbscript` y `html`
  (compilados por el Makefile) y NO hay `queries/html/injections.scm`,
  así que la inyección `script_element → javascript` no ocurre ahí.
  La capa JS localiza los `<script>` por sí misma (ver PR 2).
- Handlers jamás lanzan: cada función pública devuelve `nil` ante cualquier
  error (`pcall` interno), igual que hoy.
- No se toca `serverInfo.version` en estos PRs; se sube al cerrar la serie.
- Suite verde en cada PR (`make test`), CI de GitHub Actions verde, y
  `doc/asp.txt` + README actualizados con la nueva capacidad y sus límites.
- Los `.asp` propietarios bajo `asp/` sirven solo para verificar a mano,
  nunca se commitean.

## PR 1: definición sobre literal de página

**Disparador.** El cursor está dentro de un literal de string, en cualquier
capa (VBScript `"..."`, atributo HTML `href="..."`/`action="..."`/`src="..."`,
JS `'...'`/`"..."`). Detección por TEXTO de la línea, no por árbol: tomar la
línea del cursor, encontrar el string entre comillas (`"` o `'`) que contiene
la columna, y evaluar su contenido. Esto evita depender de tres gramáticas y
funciona en las líneas con varios `<%= %>` fusionados.

**Qué cuenta como página.** Tras recortar desde el primer `?` o `#` y
espacios, el texto debe terminar en `.asp`, `.inc`, `.htm`, `.html`, `.js`
o `.css` (case-insensitive). Se descartan `http://`, `https://`, `//`,
`mailto:`, `javascript:`, y strings vacíos. Concatenaciones VBScript
(`"pag.asp?id=" & id`) quedan cubiertas: el literal es `pag.asp?id=` y se
recorta en `?`.

**Resolución.** Reusar la lógica de `lua/asp/includes.lua`: ruta que empieza
con `/` → `includes.virtual_root_for(archivo_actual) .. ruta`; en otro caso
relativa a `vim.fs.dirname(archivo_actual)`. Normalizar `\` a `/`. Si el
archivo no existe, `nil` (sin diagnóstico en este PR). Exponer la
resolución como `M.resolve(text, from_abs)` para que PR 4 la reuse.

**Resultado.** Un `Location` con `uri` del archivo y rango `0:0`.

**Bonus `gf`.** Agregar `ftplugin/asp.lua` que fije `includeexpr` a una
función de `asp.pages` que aplique la misma resolución (sirve para `gf`,
`:find` y `C-w f` sin pasar por LSP). Debe ser idempotente y no pisar un
`includeexpr` que el usuario haya definido antes (comprobar que esté vacío).

**Tests** (`tests/spec/pages_spec.lua`, fixtures en
`tests/fixtures/proyecto/paginas/`): literal en `Response.Redirect` dentro
de `<% %>`; `href` HTML relativo; `action` con querystring; ruta virtual
`/includes/helpers.asp` resuelta contra el `web.config` del fixture;
`http://` devuelve nil; archivo inexistente devuelve nil; cursor fuera de
un string devuelve nil; el handler LSP `textDocument/definition` end-to-end
abre la página (mismo estilo que `tests/spec/lsp_spec.lua`); `includeexpr`
resuelve una ruta virtual.

## PR 2: JavaScript in-file

**Localizar el JS.** Desde el parser `aspclassic` del buffer tomar la capa
`html` (`parser:children().html`, ya inyectada por
`queries/aspclassic/injections.scm`) y buscar
`(script_element (start_tag) @tag (raw_text) @body)`. Excluir los bloques
cuyo `start_tag` tenga `runat="server"` (JScript de servidor, fuera de
alcance) o un `type` que no sea JS (`text/javascript`,
`application/javascript`, `module` o ausente son JS; cualquier otro, no).
Sobre los rangos `raw_text` restantes crear un parser `javascript` propio
(`vim.treesitter.languagetree.new(bufnr, 'javascript')` +
`set_included_regions`, o el equivalente que el implementador valide en
Neovim 0.10 y 0.12), parsear, y cachear por `changedtick` del buffer. NO
usar `vim.treesitter.get_node()` global ni depender de que exista un hijo
`javascript` inyectado por nvim-treesitter: ver el comentario largo en
`symbols.definition` sobre la carrera con el highlighter.

**Declaraciones y kinds.** `function_declaration` (12), `class_declaration`
(5), `method_definition` (6), `variable_declarator` con `var`/`let`/`const`
(13; `const` → 14), parámetros `identifier` directos de `formal_parameters`
(13), y `function_expression` con nombre (12). Nombres case-SENSITIVE
(JavaScript). Las propiedades (`property_identifier`, `this.x`, `obj.m`)
no son identificadores resolubles y quedan fuera por construcción.

**Scopes.** Scope de una declaración = el ancestro más cercano de tipo
`function_declaration`, `function_expression`, `arrow_function` o
`method_definition`; si no hay, es global. Todos los `<script>` de la misma
página comparten el scope global (así funciona el navegador). `let`/`const`
se tratan como function-scoped, no block-scoped: límite documentado.

**Resolución.** Dado un `identifier` bajo el cursor: subir por sus
funciones envolventes, de la más interna a la más externa, buscando una
declaración con ese nombre cuyo scope sea esa función; al final, el scope
global. Primer match gana. `references` devuelve todas las ocurrencias
`identifier` del buffer que resuelvan a la misma declaración (incluida la
declaración), con el mismo criterio de scope que `symbols.references`.

**Robustez.** Los bloques con `<%= %>` adentro llegan con nodos `ERROR` en
el árbol JS: se tolera, nunca se lanza. Si el parser `javascript` no está
disponible en el runtime del usuario, la capa devuelve `nil` en silencio y
`:checkhealth asp` lo reporta como advertencia (agregar la comprobación en
`lua/asp/health.lua`).

**Infra de tests.** El Makefile debe compilar `parser/javascript.so` desde
un clone shallow de `tree-sitter/tree-sitter-javascript` en
`build/tree-sitter-javascript`, igual que ya hace con `html.so`, y
`parsers-test` debe incluirlo. `src/*.c` cubre `scanner.c`. CI ya corre
`make test`, así que queda cubierto sin tocar `ci.yml`.

**Tests** (`tests/spec/js_spec.lua`, fixtures en `tests/fixtures/js/`):
definición de una función global declarada en otro `<script>` de la misma
página; variable local vs. global homónimas resuelven a la correcta;
parámetro; método de clase; `property_identifier` devuelve nil; cursor en
VBScript devuelve nil desde `js.definition` (la capa VBScript sigue
resolviendo igual que antes: la suite previa debe quedar intacta);
`<script runat="server">` se ignora; `<script type="text/template">` se
ignora; bloque con `<%= %>` adentro no lanza; `references` devuelve
declaración y usos; `textDocument/definition` end-to-end vía LSP sobre un
identificador JS. El test de regresión existente "definition en un bloque
`<script>` cliente devuelve nil de forma estable" cambia de semántica:
ahora `foo` en `symbols.asp` SÍ resuelve (a sí mismo) vía la capa JS;
actualizar ese test para que afirme el nuevo comportamiento y mantener la
afirmación de estabilidad (cinco llamadas, mismo resultado).

**Opcional.** Si no complica, incluir funciones y clases JS en
`textDocument/documentSymbol` con `detail = 'javascript'`.

## PR 3: JavaScript cross-file (tras mergear 1 y 2)

- `<script src="...">` con `src` resoluble (misma regla que `pages.resolve`)
  a un `.js`: parsear ese archivo desde disco con `get_string_parser` y
  agregar sus declaraciones globales al scope global de la página, con
  `file` apuntando al `.js`. Caché por mtime como `symbols.collect_file`.
- JS dentro de páginas incluidas vía `<!--#include-->`: recorrer
  `includes.buffer_graph(bufnr).order` y, para cada archivo, extraer los
  `<script>` desde disco (parser `aspclassic` sobre string → capa html
  confinada a los `content` → `script_element`), igual que
  `symbols.collect_file` evita parsear capas innecesarias.
- `references` cross-file con el mismo alcance.
- Abrir un `.js` suelto no es responsabilidad de este plugin: ahí el
  usuario adjunta su LSP de JS.

## PR 4: usos de una página (tras mergear 1 y 2)

- `pages.references(bufnr, position)`: si el cursor está en un literal de
  página, o si no hay literal y el buffer es un `.asp`/`.inc`, lista las
  ubicaciones de todo el proyecto (raíz = `includes.virtual_root_for`) que
  referencian ESE archivo: literales de página (PR 1, misma detección) y
  directivas `<!--#include-->` (grafo invertido).
- Barrido de texto por archivo, sin tree-sitter, cacheado por mtime.
  Extensiones a recorrer: `.asp`, `.inc`, `.htm`, `.html`, `.js`.
  Ignorar `.git`, `node_modules` y directorios ocultos.
- Las URLs construidas en runtime no se pueden seguir: límite documentado.
- Rendimiento: el primer barrido en un sitio grande puede tardar segundos;
  el resto es instantáneo. Documentar como se hizo con el buffer grande.

## Fuera de alcance de la serie

Resolución por tipos u objetos en JS (`obj.metodo`, jQuery `$`), JScript
de servidor (`<script runat="server">`, `<%@ language="JScript" %>`),
Windows, y hover/completion de JS.
