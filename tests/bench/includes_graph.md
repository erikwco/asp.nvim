# Medición del grafo de includes en caliente

Medición local del 20 de octubre de 2026, con Neovim 0.12.6 Release,
LuaJIT 2.1.1791890110 y Apple M4 Pro de 14 núcleos. La carga del equipo
rondó 3,3 a 4,3 durante la serie.

Con las cachés calientes, la definición JS cross-file con 20 includes con
`<script>` bajó de 3,25 a 0,50 ms, y con 100 includes, de 115 a 1,8 ms.
La definición VBScript con 100 includes bajó de 16,6 a 1,7 ms. Ninguna
consulta en caliente lee archivos de disco; antes, cada una releía y
reparseaba la plantilla de cada include, y con 100 includes JS también
su JavaScript. Son medianas de cinco rondas alternadas entre `ad8bcbe`
y esta rama. Los rangos de antes y después no se solapan.

## Carga y método

`includes_graph.lua` crea un sitio temporal con `web.config` en la raíz y
una página por caso. Cada página incluye N archivos de `inc/`, alternando
`file=` y `virtual=`. Cada include tiene unas 110 líneas y 8 KB: un bloque
`<% Function vbNNN %>`, 100 filas HTML con `<%= %>` y, en los casos JS,
un `<script>` con la función global `jsNNN`. El caso `js_def_20_250fn`
usa 250 funciones JS por include, como la nota de rendimiento del README.

La función buscada está en el último include, así que la consulta recorre
el grafo entero. Cada consulta valida su resultado: la definición apunta
al último include y las referencias JS son exactamente dos.

Antes de medir, cada caso corre la consulta tres veces para calentar las
cachés de archivos, del buffer y del grafo; en la tercera cuenta los
`io.open`. Después corre cinco consultas y, tras cada una,
`includes.buffer_graph` sola. Se informa la mediana de cada serie de cinco.

Se alternaron tres procesos de Neovim en cinco rondas:

- **antes**: módulos de `ad8bcbe` (antes de esta rama), antepuestos en el
  `runtimepath`.
- **solo A**: `includes.lua` de esta rama con el `js.lua` de `ad8bcbe`.
  Separa el efecto de la caché del grafo del tope de la caché JS.
- **después**: esta rama.

Cada proceso imprime de qué archivo cargó `asp.includes`, `asp.js` y
`asp.symbols`. Se comprobó en la última ronda de cada variante; todas las
rondas usan los mismos argumentos. La tabla da la mediana de las cinco
medianas por proceso, con el mínimo y el máximo entre paréntesis.

## Resultados en milisegundos

| Caso | Antes | Solo A | Después |
| --- | ---: | ---: | ---: |
| Definición JS, 20 includes | 3,25 (3,02–3,75) | 0,44 (0,40–0,56) | 0,50 (0,45–0,56) |
| Definición JS, 100 includes | 114,6 (110,5–122,3) | 95,0 (92,2–98,7) | 1,80 (1,65–1,93) |
| Definición VBScript, 100 includes | 16,6 (15,4–17,9) | 1,45 (1,44–1,61) | 1,71 (1,41–1,82) |
| Referencias JS, 100 includes | 114,2 (102,5–121,1) | 94,3 (89,3–101,2) | 1,69 (1,60–1,99) |
| Definición JS, 20 includes de 250 funciones | 4,18 (4,15–5,46) | 0,67 (0,46–1,62) | 0,47 (0,46–0,48) |

`buffer_graph` sola, en los mismos procesos:

| Caso | Antes | Después |
| --- | ---: | ---: |
| 20 includes | 3,11 | 0,31 |
| 100 includes JS | 17,7 | 0,97 |
| 100 includes VBScript | 15,7 | 1,00 |
| 100 includes JS (referencias) | 17,4 | 1,01 |
| 20 includes de 250 funciones | 3,91 | 0,31 |

Lecturas de archivo por consulta en caliente:

| Caso | Antes | Solo A | Después |
| --- | ---: | ---: | ---: |
| JS, 20 includes | 20 | 0 | 0 |
| JS, 100 includes | 200 | 100 | 0 |
| VBScript, 100 includes | 100 | 0 | 0 |

## Qué explica cada parte

Con 20 includes, la consulta anterior era casi solo `buffer_graph`:
releía y reparseaba la plantilla aspclassic de cada include. La caché de
directivas por archivo (parte A) elimina esas lecturas. Lo que queda en
`buffer_graph` se calcula en cada consulta a propósito:

- Las directivas de la propia página salen del árbol del buffer, sin
  caché. Con 100 directivas en la página cuesta unos 0,25 ms.
- Cada directiva se resuelve de nuevo (normalizar la ruta y un `fs_stat`,
  unos 4,5 µs). El destino puede aparecer o desaparecer sin que cambie el
  archivo que lo incluye.
- Cada archivo cacheado se valida con un `fs_stat` de mtime y tamaño.
- La raíz virtual se calcula una vez por directorio y consulta.
  `virtual_root_for` cuesta unos 16 µs bajo un `web.config` y 47 µs sin
  él. Antes se pagaba en cada include `virtual=`.

Con 100 includes JS, la caché de archivos JS (tope fijo de 64) se vaciaba
en cada recorrido: cada archivo se expulsaba antes de volver a usarse y
se releía y reparseaba su JavaScript. Por eso "solo A" sigue en 95 ms con
100 lecturas. Con la parte B, la caché se recorta al terminar cada
consulta sin expulsar ningún archivo que esa consulta usó, así que el tope
efectivo pasa a ser el tamaño del conjunto.

Las tablas se midieron con el recorte hecho al guardar cada entrada; la
segunda ronda de revisión lo pasó al final de la consulta. Cinco
procesos de comprobación con ese cambio, sin alternar con las otras
variantes, dieron medianas de 0,46, 1,64, 1,58, 1,63 y 0,55 ms en los
cinco casos, en el orden de la tabla, y ninguna lectura.

`buffer_graph` sigue siendo entre el 54 y el 66 % de la consulta en
caliente, pero sobre un total entre 6,5 y 68 veces menor. Las diferencias entre "solo A" y
"después" en los casos que la parte B no toca están dentro del ruido.
Sus rangos se solapan; el caso de 250 funciones tuvo picos de recolección
de basura de hasta 1,6 ms.

No se midió la primera consulta con las cachés vacías. Sigue leyendo y
parseando cada archivo una vez, como antes.

## Repetir la medición

Desde la raíz del repo, con los parsers de `make parsers-test`:

```sh
nvim --headless -u NONE -i NONE --cmd 'set rtp+=.' -l tests/bench/includes_graph.lua
```

Para medir otra revisión, extraé sus módulos y anteponelos en el
`runtimepath`. Los parsers siguen saliendo de `.`:

```sh
mkdir -p /tmp/antes && git archive ad8bcbe lua | tar -x -C /tmp/antes
nvim --headless -u NONE -i NONE --cmd 'set rtp^=/tmp/antes' --cmd 'set rtp+=.' \
  -l tests/bench/includes_graph.lua
```

`-i NONE` evita leer y escribir el ShaDa compartido con otros Neovim
abiertos. El script borra sus archivos temporales y restaura las opciones
al terminar.
