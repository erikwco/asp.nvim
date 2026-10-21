# asp.nvim

Soporte de Classic ASP (VBScript + HTML + JavaScript) para Neovim:
resaltado por regiones vía tree-sitter y navegación LSP (ir a definición,
referencias, símbolos, hover y completion) incluyendo la resolución de
`<!--#include -->` cross-file. Ver |asp.nvim| (`:help asp`) para el detalle.

El VBScript de `<% %>`/`<%= %>` se parsea con gramática propia
(`grammars/vbscript/`, fork de tree-sitter-vba), con resaltado de
keywords, tipos, funciones/variables y llamadas.

## Demo

Las tres capas (VBScript, HTML y JavaScript) resaltadas en un mismo `.asp`:

![Resaltado de las tres capas](demo/01-resaltado.gif)

Ir a la definición a través de `<!--#include -->` (de `default.asp` a
`includes/helpers.asp`):

![Ir a definición cross-include](demo/02-ir-a-definicion.gif)

Hover con la doc de los intrínsecos y completion de sus miembros:

![Hover y completion de intrínsecos](demo/03-hover-completion.gif)

Navegación desde un `onclick` a su función JS, apertura de páginas y
búsqueda de sus usos:

![JavaScript y páginas](demo/04-js-y-paginas.gif)

> Los GIFs se generan con [vhs](https://github.com/charmbracelet/vhs) desde
> `demo/*.tape` — ver [`demo/README.md`](demo/README.md).

## Requisitos

- Neovim >= 0.10
- `cc` y `git`: `make parsers` compila los parsers versionados en el repo.
  **No** necesitás tree-sitter CLI ni Node.js para instalar — el `parser.c`
  ya viene generado (ABI 14, compatible desde Neovim 0.10).
- Parsers `html`, `javascript` y `css` instalados (p. ej. con
  nvim-treesitter: `:TSInstall html javascript css`): asp.nvim no los
  compila para no pisar los que instale el usuario. `html` es necesario
  para el resaltado de las regiones HTML; `javascript`/`css` para el
  código de cliente dentro de `<script>`/`<style>`. `javascript` además
  habilita ir a definición/referencias en los `<script>` (sin él esa capa
  queda inerte y `:checkhealth asp` lo advierte).
  En Neovim 0.10, estos parsers deben usar ABI 13 o 14. Los de ABI 15
  no cargan, aunque estén instalados; `:checkhealth asp` los reporta
  como instalados pero con error de carga y muestra el error de Neovim.

### Resolver errores de ABI en Neovim 0.10

La rama [`main` de nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter/tree/main)
exige Neovim 0.12 y compila parsers con ABI 15. Para usar Neovim 0.10,
fijá `branch = 'master'` en la configuración de nvim-treesitter y
reinstalá `html`, `javascript` y `css` con `:TSInstall! html javascript css`.
La rama `master` fija versiones de esos tres parsers con ABI 14,
que también cargan en Neovim 0.11+.

Si compilás los parsers por tu cuenta, regenerá sus fuentes con
`tree-sitter generate --abi 14` antes de compilarlos. Otra opción es
pasar a Neovim 0.11+ para cargar ABI 15; usar nvim-treesitter `main`
requiere Neovim 0.12.

Neovim 0.10 y 0.12 comparten `stdpath('data')/site/parser` por defecto.
Una actualización de parsers desde 0.12 puede dejar archivos ABI 15
que 0.10 no carga. Para separar las instalaciones, usá otro
`NVIM_APPNAME`, por ejemplo `NVIM_APPNAME=nvim-010 nvim`; ese nombre
también separa la configuración y los datos del editor.

## Instalación (lazy.nvim)

```lua
{
  'erikwco/asp.nvim',
  build = 'make parsers',
  ft = 'asp',
  opts = {},
}
```

## Navegación y ayuda al código

Al abrir un `.asp` se adjunta el servidor in-process `asp-ls`. Usá `C-]`
a través de `tagfunc` o `vim.lsp.buf.definition()` para ir a definición,
y `vim.lsp.buf.references()` para listar referencias.

### VBScript e includes

La navegación resuelve Functions, Subs, Classes, variables y constantes
sin distinguir mayúsculas, con precedencia local → página. Las referencias
de un símbolo local se limitan a su scope.

Definición y referencias siguen los `<!--#include file/virtual="..."-->`
de forma recursiva y toleran ciclos. Los includes que no resuelven se
marcan con un warning en su línea. La raíz de los includes `virtual=` se
autodetecta mediante `web.config` o `.git` y puede fijarse con
`require('asp').setup({ virtual_root = '/ruta/al/sitio' })`.

Las referencias de un símbolo de página (Function, Sub, Class, `Dim` o
`Const` fuera de un Sub/Function/Property) tienen alcance de sitio. Desde
una librería como `includes/helpers.asp`, `vim.lsp.buf.references()` lista
también los usos de las páginas que la incluyen, directa o transitivamente,
y de los demás includes de esas páginas: si una página incluye
`helpers.asp` y `lib/db.inc`, las llamadas desde `db.inc` también cuentan.
Desde una página que usa la función, el conjunto parte del include que la
declara, así que el resultado es el mismo que desde la librería.

En cada archivo se omiten los usos dentro de un Sub, Function o Property
que declara ese nombre como local o parámetro. Una página que no incluye la
librería no cuenta aunque use el mismo nombre. Una declaración de página
homónima en otro archivo del conjunto sí cuenta: al incluirse, ASP junta
todo en un único script y es la misma variable global, y en runtime gana la
última definición. La definición no cambia: sigue el buffer y sus includes.
El conjunto usa la raíz y el barrido de los [usos de una
página](#usos-de-una-página). Los includes del buffer consultado son los
de su contenido sin guardar; los de los demás archivos, los del disco. Un
include que se crea o se borra entra o sale del conjunto en la siguiente
consulta, también fuera de la raíz.

### JavaScript de cliente

Definición y referencias resuelven funciones, clases, métodos,
`var`/`let`/`const` y parámetros dentro de los `<script>` del archivo.
También funcionan en atributos de evento `on*`, como
`onclick="reinitAsk();"`, `onchange` y `onsubmit`, y en URLs
`href="javascript:..."`. Los atributos se reconocen en cualquier elemento,
sin distinguir mayúsculas; los nombres JS sí son case-sensitive.

Cada función tiene su scope. Los `<script>`, manejadores y URLs
`javascript:` comparten el scope global de la página. Cada manejador `on*`
es el cuerpo de una función, con sus `var` locales. Cada URL `javascript:`
es un script global, cuyas variables y funciones pertenecen a la página.

Ese global suma las funciones, clases y variables globales de los `.js`
de sus `<script src>`, y de los `<script>` y URLs `javascript:` de las
páginas incluidas con `<!--#include-->`. También incluye los `<script src>`
de esos includes. `C-]` abre la declaración en el archivo correspondiente
y `vim.lsp.buf.references()` reúne sus usos, incluidos los manejadores de
esas páginas. Ver `:help asp-javascript`.

Se ignoran `<script runat="server">`, los `type` que no son JavaScript,
como `text/template`, y `<script language="VBScript">`. Un `<%= %>` dentro
del JS se trata como un valor opaco.

### Páginas y recursos

La consulta de definición dentro de un literal entre comillas simples o
dobles abre el archivo en su primera línea. Funciona en VBScript
(`Response.Redirect "otra.asp"`), atributos HTML (`href`, `action`, `src`)
y strings de JavaScript, sin depender de sus parsers. Incluye comillas
anidadas, como `<a onclick="location.href='otra.asp'">`, y enlaces en
`Response.Write`.

Admite `.asp`, `.inc`, `.htm`, `.html`, `.js` y `.css`, sin distinguir
mayúsculas en la extensión. Ignora querystring, fragmento y espacios
exteriores, así que `"otra.asp?id=" & id` también resuelve.

Las rutas de páginas que empiezan con `/` usan esa misma raíz virtual.
Las demás son relativas al directorio del archivo actual. Se normalizan
los separadores `\` a `/`. El destino debe existir y ser un archivo;
si no existe, la consulta devuelve `nil` sin agregar diagnósticos.
Se descartan `http://`, `https://`, `//`, `mailto:` y `javascript:`.

`gf` y `C-w f` usan `includeexpr` para resolver el nombre que Neovim extrae.
El ftplugin configura la expresión solo si está vacía y conserva cualquier
`includeexpr` previo del usuario. Neovim aplica la expresión cuando su
búsqueda normal no encuentra el archivo. `:find` no evalúa `includeexpr`;
para usar el resolver explícitamente:

```lua
local pages = require('asp.pages')
local path = pages.resolve('/includes/helpers.asp', vim.api.nvim_buf_get_name(0))
if path then vim.cmd.find(vim.fn.fnameescape(path)) end
```

#### Usos de una página

`vim.lsp.buf.references()` dentro de un literal lista los enlaces y
directivas `<!--#include -->` que apuntan a ese archivo en todo el proyecto.
Fuera de un símbolo o literal de página, en un `.asp` o `.inc`, busca quién
usa el archivo abierto. Los resultados se ordenan por archivo, línea y
columna. Un literal de página irresoluble devuelve una lista vacía.

La búsqueda de usos recorre los archivos guardados `.asp`, `.inc`, `.htm`,
`.html` y `.js`. La raíz del barrido es `setup({ virtual_root = ... })` si
está fijada; si no, el `web.config` más externo hacia arriba desde el archivo;
si no hay ninguno, el `.git` más cercano. Un `admin/web.config` anidado no
oculta los enlaces desde otras carpetas del sitio. La resolución de rutas
`/virtual` conserva el `web.config` más cercano al archivo que contiene el
enlace, igual que los includes.

El barrido usa la ruta real de la raíz. Omite `build`, `node_modules` y las
carpetas ocultas, incluida `.git`, antes de descender. No sigue symlinks de
archivos ni de directorios dentro del sitio. Lee texto sin tree-sitter y
resuelve cada ruta contra el archivo que la contiene. Las directivas
respetan `file` o `virtual`, también cuando `virtual` no lleva `/` inicial.
La caché guarda candidatos normalizados por archivo, mtime, tamaño y raíz
virtual. Crear un destino después del primer barrido no requiere invalidarla.
Guardar una fuente invalida su entrada y cada barrido purga las fuentes
desaparecidas bajo esa raíz. Los cambios sin guardar no se incluyen.
Se quita el BOM UTF-8 y se convierte de latin1 si el texto no es UTF-8 válido.

Los nombres JS sin binding, como `document`, `alert` o `.title`, devuelven
una lista de referencias vacía. Los literales de página dentro de JS sí
consultan los usos del destino. Las referencias de símbolos VBScript
conservan la precedencia.

### Símbolos, hover y completion

- `vim.lsp.buf.document_symbol()` muestra el outline del archivo, también
  disponible desde aerial o Telescope `lsp_document_symbols`. Las funciones
  y clases JS globales aparecen al final, con detail `javascript`.
- `vim.lsp.buf.workspace_symbol()` busca símbolos VBScript en todo el proyecto.
- Hover muestra la documentación de los intrínsecos de ASP (`Response`,
  `Request`, `Server`, `Session`, `Application`) y la firma de tus funciones
  y subs de VBScript.
- Completion ofrece miembros de los intrínsecos tras `Objeto.` con
  `triggerCharacters` en `.`, además de los símbolos VBScript del proyecto.

### Resaltar ocurrencias del símbolo

`textDocument/documentHighlight` devuelve las ocurrencias de VBScript o
JavaScript en el buffer actual, respetando el scope de las referencias.
La declaración se marca como Write y los usos como Read; si no se resuelve
una declaración, se usa Text. No incluye los enlaces a páginas ni las
ocurrencias de otros archivos.

Podés activarlo desde tu plugin de LSP o con `vim.lsp.buf.document_highlight()`
en `CursorHold`. Este ejemplo limpia el resaltado al mover el cursor,
entrar en Insert o salir del buffer:

```lua
local group = vim.api.nvim_create_augroup('asp_document_highlight', { clear = true })
vim.api.nvim_create_autocmd('LspAttach', {
  group = group,
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not client or client.name ~= 'asp-ls' then return end
    vim.api.nvim_clear_autocmds({ group = group, buffer = args.buf })
    vim.api.nvim_create_autocmd('CursorHold', {
      group = group,
      buffer = args.buf,
      callback = vim.lsp.buf.document_highlight,
    })
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter', 'BufLeave' }, {
      group = group,
      buffer = args.buf,
      callback = vim.lsp.buf.clear_references,
    })
  end,
})
```

El ejemplo se registra cuando se adjunta `asp-ls`, también en `.inc` y
extensiones en mayúsculas.

### Rendimiento

Las consultas VBScript sobre archivos de disco, como includes y símbolos
del proyecto, parsean sólo VBScript. En el buffer que tenés abierto,
tree-sitter también procesa las capas HTML, JavaScript, CSS y regex. En
páginas muy grandes con muchos bloques `<script>`, la primera consulta
puede tardar varios segundos. Las siguientes reutilizan los árboles,
aunque el costo de recorrer símbolos y ocurrencias crece con el archivo.

El resaltado recorre sólo las ocurrencias del buffer. Si la declaración
está allí, tampoco consulta archivos externos para clasificarla. Cuando
falta, busca la definición en includes o scripts externos para distinguir
un uso de un nombre sin declaración.
[Mediciones del resaltado frente a referencias](tests/bench/document_highlight.md).

El JavaScript de los `<script src>` y de los includes se lee desde disco
con parsers de HTML y JavaScript confinados a sus regiones. La caché usa
mtime y tamaño. Al terminar cada consulta vuelve a 64 archivos, descartando
los usados hace más tiempo, salvo los que usó esa consulta: si fueron más
de 64, los conserva todos. Olvida los borrados en la siguiente consulta.

El grafo de includes cachea las directivas de cada archivo por mtime y
tamaño, con el mismo criterio y un tope de 512 archivos. El destino de
cada include se resuelve en cada consulta, así que crear o borrar un
archivo incluido no requiere invalidar nada. En caliente, una definición
cross-file con 100 includes tarda ~1,8 ms en JS y ~1,7 ms en VBScript,
frente a 115 y 17 ms antes de agregar esta caché.
[Mediciones](tests/bench/includes_graph.md).

La primera búsqueda de usos de una página recorre y lee el sitio entero,
y puede tardar segundos. Las siguientes comprueban mtime y tamaño y sólo
releen archivos cambiados. Si la consulta lee al menos 2.000 archivos o
tarda un segundo, se emite un único aviso INFO con la cantidad de
archivos y el uso de caché en las siguientes consultas. Una consulta con
la caché caliente no avisa, aunque el sitio sea grande.

En Neovim 0.12.6 sobre Apple M4 Pro, 5.000 fuentes de unos 20 KB más el
destino y cinco JS minificados tardaron 3.334 ms en la primera consulta y
70 ms con caché, frente a 6.546 y 127 ms antes de optimizar el barrido.
Son medianas de cinco pares alternados, con 5.000 referencias verificadas
en cada consulta. Los archivos recién creados podían estar en la caché
del sistema operativo. [Mediciones y límites](tests/bench/pages_references.md).
Para repetir el caso con validación de rangos y lecturas:
`nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/bench/pages_references.lua`.

Las referencias VBScript con alcance de sitio hacen ese mismo barrido y
reutilizan lo que leyó: cada archivo se lee una vez por consulta. Solo
parsean los archivos del conjunto que mencionan el nombre en su texto, y
de ellos solo la capa VBScript. De cada archivo parseado guardan las
ocurrencias de todos sus nombres por mtime y tamaño; de los demás, sus
palabras. Con la caché caliente, buscar otro símbolo no lee disco salvo
los archivos cambiados y los que recién ahora mencionan el nombre buscado.
Emiten el mismo aviso INFO que los usos de páginas.

Con 500 páginas de ~2,9 KB que incluyen una librería de 50 funciones, la
primera consulta tardó ~200 ms y las siguientes ~8 ms, también para otro
nombre y sin lecturas. La caché ocupó ~1,8 MB.

En un sitio grande, la primera consulta bloquea Neovim varios segundos.
Con 2.000 páginas de 20 KiB que usan todas el nombre buscado, tardó
~5,1 s: ~1,2 s de barrido y ~4 s de parsear las 2.000 páginas. Las
siguientes tardaron ~27 ms y la caché ocupó ~46 MB. Un nombre que ninguna
página usa tardó ~1,7 s en frío, porque no hace falta parsear ninguna.
Una página cambiada se relee sola.
[Mediciones](tests/bench/symbols_site.md).

## Limitaciones conocidas

- La navegación de páginas toma las comillas más cercanas a cada lado del
  cursor en una sola línea y exige que sean del mismo tipo.
  No evalúa expresiones ni URLs construidas en runtime, como
  `"pagina_" & id & ".asp"` o `"<%= destino %>"`. La detección es por texto,
  sin interpretar comentarios ni decodificar escapes de URL o de lenguaje.
  Los literales sí se detectan aunque haya varios `<%= %>` en esa línea.
- Con el cursor exactamente sobre una comilla, la definición LSP devuelve
  `nil`. `gf` puede abrir la página desde la comilla inicial.
- La comparación respeta el filesystem. En APFS sin distinción de mayúsculas,
  `"Otra.asp"` y `"otra.asp"` reúnen los mismos usos. En un filesystem sensible
  a mayúsculas son destinos distintos. La comparación usa la ruta real tras
  filtrar por el nombre base en minúsculas; no reúne aliases por symlink con
  nombres base diferentes ni hard links. Una raíz por symlink sí funciona.
- Las directivas `<!--#INCLUDE FILE=...-->` en mayúsculas no las reconoce la
  gramática actual. El barrido puede detectar su texto como un literal, pero
  no garantiza la semántica `file` o `virtual` de esas directivas.
- Las rutas relativas dentro de un `.inc` o una página incluida se
  resuelven contra el archivo que contiene la ruta, no contra la página
  que pidió el navegador. Es un límite de diseño del resolver compartido.
- Las referencias VBScript con alcance de sitio no siguen `Server.Execute`,
  `Server.Transfer` ni includes armados en runtime. Solo conocen los
  incluidores dentro de la raíz del barrido; un include fuera de ella se
  recorre con su grafo. Los demás archivos se leen de disco, sin los cambios
  sin guardar de otros buffers. Los usos se buscan por nombre, así que un
  miembro `obj.Total` cuenta como uso de un `Total` de página, igual que antes.
- `gf` y `C-w f` solo reconocen rutas con `/` como separador. Neovim corta
  el nombre en `\` en Unix. `C-]` y `vim.lsp.buf.definition()` sí normalizan
  `\` a `/`.
- Varios bloques `<%= %>` en una misma línea (p. ej.
  `<td><%=a%></td><td><%=b%></td>`) se fusionan en una sola región por la
  injection combinada de VBScript (necesaria para que construcciones
  cruzadas como `<% If %>...<% End If %>` parseen como un solo programa);
  como resultado, hover/definición/referencias no resuelven identificadores
  dentro de esos bloques adyacentes. Poné cada `<%= %>` en su propia línea
  para navegación LSP completa.
- JavaScript entre archivos: de cada `.js` de `<script src>` y de cada
  include sólo se ven sus declaraciones globales. Gana el buffer, luego
  los `<script src>` en orden y después los includes en el orden del
  grafo. Si varios archivos declaran el mismo global, la definición va
  al de mayor prioridad y las referencias los reúnen a todos (en el
  navegador son la misma variable). Se ignoran los `src` externos (`http://`, CDN),
  inexistentes o armados con `<%= %>`; no se siguen `import`/`export`.
  Abrir un `.js` suelto no activa `asp-ls`: ahí va tu LSP de JavaScript.
- JavaScript: `let`/`const` se tratan como `var` (scope de función, no de
  bloque); las propiedades (`obj.metodo`, `this.x`, jQuery `$`) no se
  resuelven; no se recogen como declaración los nombres desestructurados,
  los parámetros con default o rest, el de `catch (e)` ni la variable de
  `for (const x of xs)`. Sin hover ni completion para JS.
- JavaScript en manejadores `on*`: no se modela el parámetro implícito
  `event` ni la cadena de scopes del elemento y su formulario
  (`onclick="submit()"` no resuelve a `form.submit`). No se decodifican
  las entidades HTML (`&quot;`) ni los `%xx` de una URL `javascript:`:
  ahí el JS queda con un error de sintaxis y el resto resuelve igual.
  Un manejador con `language="vbscript"` (IE) se lee igual como JS. No
  se ven los manejadores que arma VBScript (`Response.Write "<a
  onclick=...>"`) ni un `href` cuyo prefijo `javascript:` viene de un
  `<%= %>`.

## Licencias

- El plugin (código Lua, gramática aspclassic, queries): **MIT**.
- `grammars/vbscript/`: **GPL-3.0** — fork de
  [arrmee-wt/tree-sitter-vba](https://github.com/arrmee-wt/tree-sitter-vba);
  cambios documentados en `grammars/vbscript/NOTICE.md`.

## Documentación y estado

- `:help asp` — referencia completa dentro de Neovim.
- `:checkhealth asp` — diagnóstico de parsers y del servidor.
- CI: la suite corre en Linux y macOS contra Neovim 0.10.4, estable y nightly.
  Windows no está en la matriz (el build usa `make`/`cc`/`.so`, Unix-only);
  soporte Windows es backlog, requeriría un path de build separado.

La versión 0.6.0 incluye:

- Resaltado de VBScript, HTML y JavaScript, con gramática VBScript propia.
- Navegación VBScript en el archivo y a través del grafo de includes.
- Apertura de páginas y recursos por literal, `gf` y `C-w f`.
- Búsqueda de usos de páginas en todo el sitio.
- Navegación JavaScript en el archivo, en `.js` e includes, en manejadores
  `on*` y en URLs `javascript:`.
- Hover de los objetos intrínsecos de ASP y de las firmas de tus funciones
  y subs de VBScript. Completion de miembros intrínsecos y símbolos del proyecto.
- Diagnósticos de includes y búsqueda de símbolos.
- `documentHighlight` para las ocurrencias VBScript y JS del buffer actual.
- CI en Neovim 0.10.4, estable y nightly, sobre Linux y macOS.

## Desarrollo

El `parser.c` de cada gramática está versionado (por eso instalar sólo
necesita `cc`). Si editás una `grammars/*/grammar.js`, regenerá y commiteá:

```bash
make generate   # requiere Node.js; usa tree-sitter-cli 0.25.10, ABI 14
make test       # corpus + suite plenary
```

`make test` necesita red la primera vez: clona plenary.nvim,
tree-sitter-html y tree-sitter-javascript en `build/` y compila
`parser/html.so` y `parser/javascript.so` sólo para la suite.
tree-sitter-javascript va pineado al tag `v0.23.1` (ABI 14): su rama
principal genera ABI 15, que Neovim 0.10 no carga.

Para probar otro Neovim, pasá su ruta en `NVIM`:

```bash
make test NVIM=/ruta/a/nvim
```

El harness desactiva ShaDa con `vim.o.shadafile = 'NONE'` para que los
procesos de prueba no lean ni escriban el estado del desarrollador.

El CI falla si el `parser.c` versionado quedó desactualizado respecto a su
`grammar.js`.
