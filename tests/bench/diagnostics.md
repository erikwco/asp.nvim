# Medición de los diagnósticos de VBScript

Medición local del 20 de octubre de 2026, con Neovim 0.12.6 Release,
LuaJIT 2.1.1791890110 y Apple M4 Pro de 14 núcleos. La carga del equipo
rondó 2,2 a 2,5 durante la serie.

En una página de ~20 KB con 20 includes, `asp.diagnostics.refresh` tarda
~5,6 ms con las cachés calientes y ~21 ms en frío. En caliente no lee
nada de disco; en frío lee cada include dos veces, una para sus
directivas y otra para sus símbolos, como ya hacían la definición y las
referencias. El objetivo era menos de 50 ms en caliente.

## Carga y método

`diagnostics.lua` crea un sitio temporal con `web.config` en la raíz:

- 20 includes en `inc/`, de ~7 KB cada uno (142.562 bytes en total). Cada
  uno declara un `Const`, una Function con un `Dim` local, un Sub y una
  Class con un miembro `Private`, y tiene 100 filas HTML con `<%= %>` y
  un `<script>`.
- `pagina.asp`, de 19.801 bytes: las 20 directivas, alternando `file=` y
  `virtual=`, `Option Explicit` y un bloque VBScript que usa lo de cada
  include. Llama a la Function sin paréntesis y al Sub, instancia la
  Class con `New` y llama a su método. Siguen una tabla de 120 filas con
  `<%= %>` y tres enlaces por fila, y un `<script>`.

La página tiene exactamente un error de cada familia: una variable sin
`Dim`, una llamada a una función inexistente y un enlace a una página que
no existe. Cada refresh comprueba que se publiquen esos tres y ningún
otro, y que ninguna familia haya fallado.

Cada proceso corre nueve veces cada caso y se informa la mediana:

- **frío**: invalida las cachés de includes y de símbolos de los 20
  archivos y refresca. Cuenta los `io.open`.
- **caliente**: refresca sin cambios.
- **tras editar**: cambia una línea del bloque VBScript de la página y
  refresca. El árbol VBScript del buffer se vuelve a parsear entero.
- **desglose**: `buffer_graph` y los literales de páginas solos, y un
  refresh con una sola familia activa.

Antes de esos casos mide `asp.symbols.collect_file` de los 20 includes
con la caché vacía: es el parseo en frío al que se sumaron los indicios
que usan los diagnósticos (Option Explicit y Eval/Execute).

## Resultados en milisegundos

Mediana de cinco procesos, con el mínimo y el máximo entre paréntesis:

| Caso | Tiempo | Lecturas |
| --- | ---: | ---: |
| Refresh en frío | 21,4 (21,0–22,0) | 40 |
| Refresh en caliente | 5,54 (5,44–5,88) | 0 |
| Refresh tras editar la página | 5,78 (5,51–5,87) | 0 |

Desglose en caliente:

| Pieza | Tiempo |
| --- | ---: |
| `includes.buffer_graph` | 0,39 |
| Literales de páginas (`pages.buffer_literals`) | 1,38 |
| Solo `includes` | 0,50 |
| Solo `syntax` | 1,05 |
| Solo `undeclared` y `unknown_call` | 3,54 |
| Solo `missing_page` | 3,14 |

Las familias comparten el contexto de un refresh: el árbol VBScript del
buffer se parsea una vez y lo usan sintaxis, variables, llamadas y los
comentarios VBScript de `missing_page`. Por eso la suma de las familias
solas es mayor que el refresh completo.

En Neovim 0.10.4 el refresh en caliente tardó ~8 ms y en frío ~24 ms,
también sin lecturas en caliente. En frío leyó entre 46 y 48 archivos:
además de los 40 includes, 0.10 vuelve a leer archivos de queries de
tree-sitter cuando el recolector vacía la caché débil donde los guarda.

`collect_file` de los 20 includes con la caché vacía: 11,17 ms en `main`
(`4d19ca7`) y 11,41 ms en esta rama, medianas de cinco procesos
alternados con rangos solapados. Los indicios cuestan ~7 µs por include:
miran solo la primera sentencia y buscan Eval/Execute solo si el texto
los menciona. Una primera versión que recorría el árbol con una query
costaba ~55 µs por include, un 18 % más de parseo en frío.

## Qué cuesta cada parte

- El árbol VBScript del buffer sale de un parser string que solo ve los
  bloques `<% %>`, con las regiones de la capa top del propio buffer. Un
  `parse(true)` del buffer parsearía también HTML, JavaScript, CSS y
  regex: en la página real más grande que se probó (~318 KB), 58 ms la
  primera vez y ~10 ms tras cada edición, frente a ~3,5 ms de la capa top
  más el parser string.
- El grafo de includes y los símbolos de cada include salen de sus
  cachés por mtime y tamaño: en caliente solo cuestan un `fs_stat` por
  archivo.
- `missing_page` hace un `fs_stat` por destino distinto en cada refresh,
  sin caché: un archivo puede aparecer o desaparecer sin que cambie la
  página.

Sobre tres páginas reales sin includes, de 44, 71 y 318 KB, el refresh
en caliente tardó 2,8, 3,2 y 12 ms.

## Repetir la medición

Desde la raíz del repo, con los parsers de `make parsers-test`:

```sh
nvim --headless -u NONE -i NONE --cmd 'set rtp+=.' -l tests/bench/diagnostics.lua
```

Para comparar el parseo en frío de los includes con otra revisión,
extraé sus módulos y anteponelos en el `runtimepath`. Si esa revisión no
tiene `asp.diagnostics`, el script solo mide `collect_file`:

```sh
mkdir -p /tmp/antes && git archive 4d19ca7 lua | tar -x -C /tmp/antes
nvim --headless -u NONE -i NONE --cmd 'set rtp^=/tmp/antes' --cmd 'set rtp+=.' \
  -l tests/bench/diagnostics.lua
```

`-i NONE` evita leer y escribir el ShaDa compartido con otros Neovim
abiertos. El script borra sus archivos temporales y restaura las opciones
al terminar.
