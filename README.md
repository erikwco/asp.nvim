# asp.nvim

Soporte de Classic ASP (VBScript + HTML + JavaScript) para Neovim:
resaltado por regiones vía tree-sitter y navegación LSP (ir a definición,
referencias, símbolos, hover y completion) incluyendo la resolución de
`<!--#include -->` cross-file. Ver |asp.nvim| (`:help asp`) para el detalle.

El VBScript de `<% %>`/`<%= %>` se parsea con gramática propia
(`grammars/vbscript/`, fork de tree-sitter-vba), con resaltado de
keywords, tipos, funciones/variables y llamadas.

## Requisitos

- Neovim >= 0.10
- `cc` y `git`: `make parsers` compila los parsers versionados en el repo.
  **No** necesitás tree-sitter CLI ni Node.js para instalar — el `parser.c`
  ya viene generado (ABI 14, compatible desde Neovim 0.10).
- Parsers `html`, `javascript` y `css` instalados (p. ej. con
  nvim-treesitter: `:TSInstall html javascript css`): asp.nvim no los
  compila para no pisar los que instale el usuario. `html` es necesario
  para el resaltado de las regiones HTML; `javascript`/`css` para el
  código de cliente dentro de `<script>`/`<style>`.

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

Al abrir un `.asp` se adjunta el servidor in-process `asp-ls`:

- **Ir a definición**: `C-]` (vía tagfunc) o `vim.lsp.buf.definition()` —
  Functions, Subs, Classes, variables y constantes del archivo actual,
  case-insensitive, con precedencia local → página.
- **Símbolos del documento**: `vim.lsp.buf.document_symbol()` u outline de
  tu plugin favorito (aerial, Telescope `lsp_document_symbols`, ...).
- **Hover**: documentación de los objetos intrínsecos de ASP
  (`Response`, `Request`, `Server`, `Session`, `Application`) y firma de
  tus propias funciones/subs.
- **Completion**: miembros de los intrínsecos tras `Objeto.` (con
  `triggerCharacters` en `.`) y los símbolos del proyecto.

- **Cross-file**: definición y referencias siguen los
  `<!--#include file/virtual="..."-->` (recursivo, ciclos tolerados);
  `vim.lsp.buf.workspace_symbol()` busca en todo el proyecto.
- **Diagnósticos**: los includes que no resuelven se marcan con un
  warning en su línea. La raíz de los includes `virtual=` se autodetecta
  (`web.config` o `.git`) y puede fijarse con
  `require('asp').setup({ virtual_root = '/ruta/al/sitio' })`.

> **Nota de rendimiento:** para los archivos INCLUDED/indexados (grafo de
> includes, `workspace/symbol`), la Fase 4 ya optimizó esto: solo se
> parsea la capa VBScript desde disco (milisegundos, incluso en archivos
> enormes), sin tocar html/js/css/regex. Esa optimización no cubre el
> buffer que tienes ABIERTO: en páginas muy grandes con muchos bloques
> `<script>` (miles de líneas), la *primera* consulta LSP tras abrir el
> archivo puede tardar varios segundos mientras tree-sitter parsea todas
> sus capas; las consultas siguientes sobre ese buffer son instantáneas.

## Limitaciones conocidas

- Varios bloques `<%= %>` en una misma línea (p. ej.
  `<td><%=a%></td><td><%=b%></td>`) se fusionan en una sola región por la
  injection combinada de VBScript (necesaria para que construcciones
  cruzadas como `<% If %>...<% End If %>` parseen como un solo programa);
  como resultado, hover/definición/referencias no resuelven identificadores
  dentro de esos bloques adyacentes. Poné cada `<%= %>` en su propia línea
  para navegación LSP completa.

## Verificación

`:checkhealth asp`

## Licencias

- El plugin (código Lua, gramática aspclassic, queries): **MIT**.
- `grammars/vbscript/`: **GPL-3.0** — fork de
  [arrmee-wt/tree-sitter-vba](https://github.com/arrmee-wt/tree-sitter-vba);
  cambios documentados en `grammars/vbscript/NOTICE.md`.

## Documentación y estado

- `:help asp` — referencia completa dentro de Neovim.
- `:checkhealth asp` — diagnóstico de parsers y del servidor.
- CI: la suite corre en Linux y macOS contra Neovim estable y nightly.
  Windows no está en la matriz (el build usa `make`/`cc`/`.so`, Unix-only);
  soporte Windows es backlog, requeriría un path de build separado.

El plugin cubre las cinco fases del diseño: resaltado de las tres capas,
gramática VBScript propia, navegación LSP, grafo de includes cross-file, y
ayuda al código (hover/completion) con documentación y CI.

## Desarrollo

El `parser.c` de cada gramática está versionado (por eso instalar sólo
necesita `cc`). Si editás una `grammars/*/grammar.js`, regenerá y commiteá:

```bash
make generate   # requiere Node.js; usa tree-sitter-cli 0.25.10, ABI 14
make test       # corpus + suite plenary
```

El CI falla si el `parser.c` versionado quedó desactualizado respecto a su
`grammar.js`.
