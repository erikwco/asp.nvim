# Demos (GIFs)

Los GIFs del README se generan con [vhs](https://github.com/charmbracelet/vhs)
a partir de los scripts `.tape` de esta carpeta — reproducibles, sin grabar
pantalla a mano.

## Requisitos

```bash
brew install vhs        # instala también ttyd y ffmpeg
```

Y tener asp.nvim instalado en tu Neovim (los tapes corren tu `nvim` real, con
tu config y los parsers `html`/`javascript`/`css` de nvim-treesitter).

## Generar

Desde la raíz del repo:

```bash
vhs demo/01-resaltado.tape          # -> demo/01-resaltado.gif
vhs demo/02-ir-a-definicion.tape    # -> demo/02-ir-a-definicion.gif
vhs demo/03-hover-completion.tape   # -> demo/03-hover-completion.gif
```

## Contenido

- `01-resaltado` — las tres capas (VBScript, HTML, JavaScript) resaltadas
  en un mismo `.asp`.
- `02-ir-a-definicion` — `gd` sobre `FormatearMoneda` salta a su definición
  en `includes/helpers.asp` (a través del `<!--#include -->`).
- `03-hover-completion` — `K` sobre `Response` muestra la doc del intrínseco;
  completion tras `Server.` lista sus miembros.

Los atajos usados (`gd`, `K`, `Ctrl-X Ctrl-O`) son los de LazyVim / LSP por
defecto. Si tu config usa otros, ajustá los tapes.

`app/` es un mini-proyecto ASP autocontenido usado sólo por las demos.
