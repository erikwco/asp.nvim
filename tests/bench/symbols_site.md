# Medición de referencias VBScript con alcance de sitio

Medición local del 20 de octubre de 2026, con Neovim 0.12.6 Release,
LuaJIT 2.1.1791890110 y Apple M4 Pro de 14 núcleos. La carga del equipo
rondó 3,6 a 6,1 durante la serie.

Compara la primera versión del alcance de sitio (`55e64aa`) con la
actual, que lee cada archivo una sola vez por consulta y solo parsea los
que mencionan el nombre buscado.

- Con 500 páginas de ~2,9 KB, la primera consulta pasó de 242 a 198 ms y
  de 1.004 a 503 lecturas. Las siguientes siguen en ~8 ms, sin lecturas.
- Con 2.000 páginas de 20 KiB que usan todas el nombre buscado, la
  primera consulta pasó de 7,7 a 5,1 s y de 4.004 a 2.003 lecturas. Las
  siguientes siguen en ~27 ms. **La primera consulta bloquea Neovim
  ~5 s**: 1,2 s de barrido de texto y 4 s de parseo VBScript.
- Un nombre que ninguna página usa pasó de 7,7 a 1,7 s en frío, porque
  ya no se parsea ninguna página.

Son medianas de cinco procesos alternados entre las dos versiones.

## Carga y método

`symbols_site.lua` crea un sitio temporal con `web.config` en la raíz:

- `lib/funciones.inc`: 50 funciones `FnNN(valor)` con un `Dim` local cada
  una. Incluye `lib/constantes.inc`, que declara `IVA`.
- 500 páginas de ~2,9 KB en 10 carpetas. Cada una incluye la librería con
  `virtual=`, llama a `Fn01` y `Fn02` en la línea 3 y tiene una tabla HTML
  de 40 filas con `<%= %>`. Una de cada diez declara además
  `Function Ajuste(Fn01)`: ese parámetro no debe contarse.
- Con `ASP_BENCH_GRANDE=1`, 2.000 páginas como esas, completadas a
  20 KiB exactos con un bloque de 190 líneas de VBScript con strings SQL y
  HTML, y un comentario HTML. Es el caso del revisor del PR #9.

En total, 502 archivos y 1.455.749 bytes, o 2.002 archivos y 40.964.807
bytes. La librería está abierta en un buffer con su parser listo, como en
el editor. Cada consulta de `Fn01` y `Fn02` valida que devuelve una
referencia por página más la declaración y la asignación de retorno en la
librería, sin los parámetros homónimos, y que cada página aparece una vez
en la línea 3.

Cada proceso corre cinco rondas. Cada ronda invalida las cachés de páginas,
símbolos e includes de todos los archivos y mide:

- **primera**: `Fn01` con las cachés vacías. Incluye el barrido del sitio,
  el índice de includes y el parseo VBScript de cada archivo del conjunto
  que menciona `Fn01`; en esta carga, todas las páginas.
- **siguiente**: la misma consulta otra vez.
- **otro nombre**: `Fn02`, que no se buscó antes en esa ronda.
- **memoria**: lo que retiene Lua después de la primera consulta, tras un
  `collectgarbage`.

Después de las rondas mide la consulta desde una página que usa `Fn01`
(primera y siguiente) y una consulta tras cambiar una página. Por último
vacía las cachés y busca `Fn03`, que solo aparece en la librería, y
después `Fn01`. Se informa la mediana de cada proceso; las tablas dan la
mediana de las cinco medianas, con el mínimo y el máximo entre paréntesis.
Cada proceso cuenta además los avisos INFO.

Para **antes** se antepusieron en el `runtimepath` los módulos de
`55e64aa` extraídos con `git archive`, con `ASP_BENCH_ANTES=1` para medir
sin validar. Cada proceso imprimió de qué archivo cargó `asp.symbols` y se
comprobó en todos.

## 500 páginas, en milisegundos

| Consulta | Antes | Después |
| --- | ---: | ---: |
| Primera, desde la librería | 241,6 (234,2–246,5) | 198,0 (197,8–202,7) |
| Siguiente | 8,15 (7,63–8,50) | 8,27 (7,89–8,78) |
| Otro nombre, caché caliente | 8,89 (7,58–9,62) | 8,34 (7,78–9,32) |
| Primera desde una página | 11,5 (10,9–13,1) | 10,0 (9,71–11,8) |
| Siguiente desde una página | 8,05 (7,03–9,26) | 6,95 (6,14–8,88) |
| Tras cambiar una página | 10,6 (8,50–12,1) | 9,15 (8,55–12,0) |
| `Fn03`, sin usos en páginas, en frío | 243,0 (233,4–247,4) | 87,6 (84,0–88,7) |
| `Fn01` después de `Fn03` | 10,2 (9,20–11,1) | 162,6 (156,5–168,7) |

| Lecturas, memoria y avisos | Antes | Después |
| --- | ---: | ---: |
| Lecturas, primera consulta | 1.004 | 503 |
| Lecturas, consultas siguientes | 0 | 0 |
| Lecturas, primera desde una página | 3 | 3 |
| Lecturas tras cambiar una página | 2 | 1 |
| Lecturas, `Fn03` en frío / `Fn01` después | 1.004 / 0 | 503 / 500 |
| Memoria retenida | 1.788 KB | 1.780 KB |
| Avisos INFO por proceso | 0 | 0 |

## 2.000 páginas de 20 KiB, en milisegundos

| Consulta | Antes | Después |
| --- | ---: | ---: |
| Primera, desde la librería | 7.668 (7.562–7.794) | 5.146 (5.109–5.225) |
| Siguiente | 27,1 (26,9–28,1) | 26,9 (25,8–28,4) |
| Otro nombre, caché caliente | 25,6 (24,8–26,8) | 24,8 (24,1–25,8) |
| Primera desde una página | 29,2 (27,8–30,0) | 28,2 (25,9–28,8) |
| Siguiente desde una página | 25,2 (23,9–26,4) | 24,8 (23,2–25,6) |
| Tras cambiar una página | 35,9 (34,2–37,7) | 35,6 (34,6–36,2) |
| `Fn03`, sin usos en páginas, en frío | 7.707 (7.622–7.871) | 1.732 (1.718–1.780) |
| `Fn01` después de `Fn03` | 33,4 (27,5–88,0) | 4.363 (4.353–4.455) |

| Lecturas, memoria y avisos | Antes | Después |
| --- | ---: | ---: |
| Lecturas, primera consulta | 4.004 | 2.003 |
| Lecturas, consultas siguientes | 0 | 0 |
| Lecturas, primera desde una página | 3 | 3 |
| Lecturas tras cambiar una página | 2 | 1 |
| Lecturas, `Fn03` en frío / `Fn01` después | 4.004 / 0 | 2.003 / 2.000 |
| Memoria retenida | 45.856 KB | 46.098 KB |
| Avisos INFO por proceso | 20 | 7 |

Antes, el aviso salía en todas las consultas, también en las de ~27 ms,
porque dependía del tamaño del sitio. Ahora sale solo si la consulta lee
2.000 archivos o tarda un segundo: las cinco primeras consultas, `Fn03` y
`Fn01` después de `Fn03`.

`Fn01` después de `Fn03` es la contracara del prefiltro: `Fn03` no
parseó ninguna página y solo guardó sus palabras, así que `Fn01` las
vuelve a leer para parsearlas. Las dos consultas juntas tardan ~6,1 s,
frente a los ~7,7 s de antes.

## Qué consume el tiempo

En una corrida aparte con el perfil del revisor, la primera consulta de
2.000 páginas tardó 5.193 ms: 1.239 ms de barrido de texto (listar,
leer y buscar literales y directivas, ~0,6 ms por archivo) y 3.954 ms de
parseo, ~1,97 ms por página. Un timer de 1 ms programado antes de la
consulta corrió recién a los 5.196 ms: Neovim no atiende teclas ni
eventos mientras tanto.

Por página de 20 KiB, medido con 200 repeticiones sobre el mismo
contenido:

| Paso | ms |
| --- | ---: |
| Leer y normalizar (`asp.pages.read`) | 0,13 |
| Plantilla `aspclassic`, sin inyecciones | 0,11 |
| Ubicar los bloques `<% %>` | 0,03 |
| Parsear la capa VBScript de esos bloques | 0,82 |
| Declaraciones (consulta de 9 patrones) | 0,30 |
| Ocurrencias de los 525 identificadores | ~0,55 |
| Buscar el nombre en el texto en minúsculas | < 0,01 |
| Palabras de un archivo que no lo menciona | 0,20 |

Antes, ubicar el Sub/Function/Property de cada identificador subiendo con
`node:parent()` costaba ~0,8 ms más por página. Ahora sale de una pila de
scopes sobre las mismas capturas.

Aun sin el recorrido en Lua, el barrido y el parser de VBScript solos
suman ~3 s para estas 2.000 páginas. Bajar de eso pide repartir el trabajo
en tramos que no bloqueen el editor, no optimizarlo más.

La memoria retenida es la tabla de ocurrencias por nombre de cada archivo
parseado, guardada como listas planas de números, más las declaraciones
que salen del mismo parseo y las palabras de los archivos sin parsear.
Durante la primera consulta, además, se retiene el texto que leyó el
barrido hasta terminar (~40 MB en el caso grande) para no leerlo dos
veces.

## Primera versión, frente a `main`

En la ronda 1 se comparó `55e64aa` con `main` (`1e0966f`), que no
recorría el sitio: con 500 páginas, `main` tardaba 1,5 ms en la primera
consulta y 1,6 ms en las siguientes, pero solo veía la librería (2
referencias en lugar de 502) y releía de disco cada include en cada
consulta.

## Repetir el caso

```sh
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/bench/symbols_site.lua
ASP_BENCH_GRANDE=1 nvim --headless -u NONE --cmd 'set rtp+=.' \
  -l tests/bench/symbols_site.lua
```

Para medir otra versión con la misma carga, anteponé sus módulos en el
`runtimepath` y omití las validaciones:

```sh
ASP_BENCH_ANTES=1 nvim --headless -u NONE --cmd 'set rtp+=.' \
  --cmd 'set rtp^=/ruta/a/otra/version' -l tests/bench/symbols_site.lua
```

El script borra sus archivos temporales y restaura las opciones al terminar.
