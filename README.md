# asp.nvim

Soporte de Classic ASP (VBScript + HTML + JavaScript) para Neovim:
resaltado por regiones vía tree-sitter. Fases futuras: go-to-definition
con resolución de `<!--#include -->` (ver `docs/superpowers/specs/`).

En esta fase el resaltado a nivel de token de VBScript es mínimo: lo que
funciona hoy es la separación de regiones y el resaltado de HTML/JavaScript;
la gramática de VBScript completa (Fase 2) traerá el resaltado detallado.

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

## Verificación

`:checkhealth asp`
