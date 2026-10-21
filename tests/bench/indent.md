# Medición de la indentación

Medición local del 21 de octubre de 2026 en macOS, Apple M4 Pro de 14
núcleos, con Neovim 0.12.6 Release y 0.10.4. Load average de 2,0 a 2,5
durante la serie.

## Página sintética de 307 KB

`indent.lua` arma una página de 17.505 líneas y 307.031 bytes sin
indentar: 350 bloques con un `<div>`, una tabla envuelta en
`<% If %>`/`<% Else %>`/`<% End If %>`, un bloque `<% %>` con un Sub,
For Each, If/ElseIf/Else y Select Case, un `<script>` con una función JS
y una lista. Abre la página con el plugin y la suite de `minimal_init`
(asp-ls adjunto), corre `gg=G` dos veces y mide `o` siete veces en una
línea de código y en una línea HTML.

| | Neovim 0.12.6 | Neovim 0.10.4 |
| --- | ---: | ---: |
| `gg=G` en frío | 6.442 ms | 6.120 ms |
| ↳ dentro del indentexpr | 2.379 ms | 2.226 ms |
| ↳ ↳ HtmlIndent() | 2.288 ms | 2.124 ms |
| ↳ ↳ asp.nvim | 92 ms | 101 ms |
| `gg=G` en caliente (ya indentado) | 2.393 ms | 2.212 ms |
| `o` en una línea de código (mediana) | 15,4 ms | 15,1 ms |
| `o` en una línea HTML (mediana) | 14,8 ms | 41,8 ms |
| el mismo buffer con `ft=html` | 9.079 ms | 8.323 ms |

La segunda pasada no cambia ninguna línea.

Lo propio de asp.nvim es ~0,1 s: un estado por `changedtick` (Neovim no
lo incrementa durante `=`) y, por línea, una búsqueda en el árbol de la
plantilla y dos búsquedas binarias. El resto del indentexpr es
`HtmlIndent()`, que incluye el indent de JavaScript de Vim en los
`<script>`.

La diferencia entre el frío y el indentexpr (~4 s) es de Neovim: cada
línea reindentada es una edición, y `LanguageTree:_on_bytes` vuelve a
pedir todos los rangos de las capas inyectadas combinadas (`html` y
`vbscript`, uno por bloque). Ese costo crece con el tamaño de la página
y lo paga cualquier edición masiva del buffer, no sólo `=`. En caliente
no hay ediciones.

`ft=html` tarda más porque, sin la ayuda de asp.nvim, HtmlIndent recalcula
su estado desde el texto en cada línea: sólo lo reutiliza si
`b:changedtick` avanzó uno desde la línea anterior, y Neovim no lo
incrementa durante `=`. asp.nvim le indica que continúe cuando la línea
anterior la indentó HtmlIndent sin ajustes.

`o` reconstruye el estado tras la edición: un parseo incremental de la
plantilla y de la capa vbscript, y la consulta de bloques. En 0.10 el
parseo por rango vuelve a procesar todas las inyecciones de la capa
HTML (350 `<script>`), por eso `o` en HTML tarda más.

## Páginas reales

Tres páginas propietarias, fuera del repo, medidas con Neovim 0.12.6
(una sola pasada de `gg=G` en frío):

| Página | Líneas | Tamaño | `gg=G` | HtmlIndent | asp.nvim | con `ft=html` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| A | 8.745 | 318 KB | 16.410 ms | 16.249 ms | 29 ms | 19.947 ms |
| B | 1.715 | 71 KB | 2.367 ms | 2.350 ms | 6 ms | 2.659 ms |
| C | 1.228 | 44 KB | 595 ms | 582 ms | 5 ms | 907 ms |

La página A es sobre todo JavaScript de cliente: 6.850 de sus líneas
están en `<script>`, y `GetJavascriptIndent()` se lleva ~16 s. En la
página B, cinco líneas de un comentario `/* */` dentro de un `<script>`
cambian entre la primera y la segunda pasada; con `ft=html` pasa lo
mismo, es del indent de JavaScript de Vim.

En la página A, `o` en una línea VBScript tarda 1 a 2 ms y `==` sobre un
`End If`, 0,7 ms.

Para repetir la medición sintética desde la raíz del repo:

```bash
nvim --headless -u tests/minimal_init.lua -l tests/bench/indent.lua
BLOQUES=100 nvim --headless -u tests/minimal_init.lua -l tests/bench/indent.lua
```
