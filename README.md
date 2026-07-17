# asp.nvim

Soporte de Classic ASP (VBScript + HTML + JavaScript) para Neovim:
resaltado por regiones vía tree-sitter. Fases futuras: go-to-definition
con resolución de `<!--#include -->` (ver `docs/superpowers/specs/`).

El VBScript de `<% %>`/`<%= %>` se parsea con gramática propia
(`grammars/vbscript/`, fork de tree-sitter-vba), con resaltado de
keywords, tipos, funciones/variables y llamadas.

## Requisitos

- Neovim >= 0.10
- `cc` y `git` (para compilar los parsers)
- Parser `html` instalado (p. ej. con nvim-treesitter, `:TSInstall html`):
  `make parsers` no lo compila para no pisar el que instale el usuario.
- Parsers `javascript` y `css` instalados (p. ej. con nvim-treesitter)
  para el código de cliente dentro de `<script>`/`<style>`.

## Instalación (lazy.nvim)

```lua
{
  'erik/asp.nvim',
  build = 'make parsers',
  ft = 'asp',
  opts = {},
}
```

## Navegación (Fases 3-4)

Al abrir un `.asp` se adjunta el servidor in-process `asp-ls`:

- **Ir a definición**: `C-]` (vía tagfunc) o `vim.lsp.buf.definition()` —
  Functions, Subs, Classes, variables y constantes del archivo actual,
  case-insensitive, con precedencia local → página.
- **Símbolos del documento**: `vim.lsp.buf.document_symbol()` u outline de
  tu plugin favorito (aerial, Telescope `lsp_document_symbols`, ...).

- **Cross-file**: definición y referencias siguen los
  `<!--#include file/virtual="..."-->` (recursivo, ciclos tolerados);
  `vim.lsp.buf.workspace_symbol()` busca en todo el proyecto.
- **Diagnósticos**: los includes que no resuelven se marcan con un
  warning en su línea. La raíz de los includes `virtual=` se autodetecta
  (`web.config` o `.git`) y puede fijarse con
  `require('asp').setup({ virtual_root = '/ruta/al/sitio' })`.

> **Nota de rendimiento:** en páginas muy grandes con muchos bloques
> `<script>` (miles de líneas), la *primera* consulta LSP tras abrir el
> archivo puede tardar varios segundos mientras tree-sitter parsea todas
> las capas; las consultas siguientes son instantáneas. La Fase 4
> optimizará esto parseando solo la capa VBScript.

## Verificación

`:checkhealth asp`

## Licencias

- El plugin (código Lua, gramática aspclassic, queries): **MIT**.
- `grammars/vbscript/`: **GPL-3.0** — fork de
  [arrmee-wt/tree-sitter-vba](https://github.com/arrmee-wt/tree-sitter-vba);
  cambios documentados en `grammars/vbscript/NOTICE.md`.
