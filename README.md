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
  'erik/asp.nvim',
  build = 'make parsers',
  ft = 'asp',
  opts = {},
}
```

## Verificación

`:checkhealth asp`
