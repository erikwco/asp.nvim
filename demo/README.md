# Demos (GIFs)

Los GIFs del README se generan con [vhs](https://github.com/charmbracelet/vhs)
a partir de los scripts `.tape` de esta carpeta, sin grabar
pantalla a mano.

## Requisitos

```bash
brew install vhs        # instala también ttyd y ffmpeg
```

Necesitás Neovim >= 0.10 y los parsers `html`, `javascript` y `css`
compatibles con esa versión. Los tapes usan `nvim -u demo/init.lua`, que
carga asp.nvim desde este checkout y busca los parsers en los datos de tu
Neovim. No carga tu configuración ni lee o escribe ShaDa.

El tema es Catppuccin Mocha si está instalado; si no, usa Habamax.

## Generar

Desde la raíz del repo:

```bash
make parsers
vhs validate 'demo/*.tape'
vhs demo/01-resaltado.tape          # -> demo/01-resaltado.gif
vhs demo/02-ir-a-definicion.tape    # -> demo/02-ir-a-definicion.gif
vhs demo/03-hover-completion.tape   # -> demo/03-hover-completion.gif
vhs demo/04-js-y-paginas.tape       # -> demo/04-js-y-paginas.gif
```

Los cuatro tapes usan 1200 × 800, fuente de 18 y padding de 20.
El ejemplo de completion modifica el buffer durante la grabación, sin
guardar esos cambios.

## Contenido

- `01-resaltado` muestra las tres capas (VBScript, HTML, JavaScript) resaltadas
  en un mismo `.asp`.
- `02-ir-a-definicion` usa `C-]` sobre `FormatearMoneda` para ir a su definición
  en `includes/helpers.asp` (a través del `<!--#include -->`).
- `03-hover-completion` usa `K` sobre `Response` para mostrar la doc del intrínseco;
  completion tras `Server.` lista sus miembros.
- `04-js-y-paginas` usa `C-]` desde un `onclick` para ir a la función de
  un `<script>`, y desde allí a una función del `.js` cargado por `src`.
  Después abre `otra.asp` desde su literal y ejecuta
  `vim.lsp.buf.references()` para listar los enlaces HTML y JS a esa página.

`C-]` usa el `tagfunc` de LSP. `demo/init.lua` define `gd`, `K` y `grr` al
adjuntar el servidor. `Ctrl-X Ctrl-O` usa su completion mediante `omnifunc`.

`app/` es un mini-proyecto ASP usado sólo por las demos. La configuración
fija su raíz virtual allí para que la búsqueda de páginas no recorra el
resto del repo. `default.asp` y `otra.asp` se enlazan entre sí, y
`js/pedido.js` también apunta a `otra.asp`.
