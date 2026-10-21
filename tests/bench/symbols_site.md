# Medición de referencias VBScript con alcance de sitio

Medición local del 20 de octubre de 2026, con Neovim 0.12.6 Release,
LuaJIT 2.1.1791890110 y Apple M4 Pro de 14 núcleos. La carga del equipo
rondó 4,5 a 5,8 durante la serie.

Con 500 páginas que incluyen una librería de 50 funciones, las referencias
de una función desde la librería tardan 231 ms en la primera consulta y
7,8 ms en las siguientes, sin leer disco, también para otra función. Antes,
la misma consulta tardaba 1,5 ms pero solo veía la librería: 2 referencias
en lugar de 502. Son medianas de cinco procesos alternados entre `main`
(`1e0966f`) y esta rama.

## Carga y método

`symbols_site.lua` crea un sitio temporal con `web.config` en la raíz:

- `lib/funciones.inc`: 50 funciones `FnNN(valor)` con un `Dim` local cada
  una. Incluye `lib/constantes.inc`, que declara `IVA`.
- 500 páginas de ~2,9 KB en 10 carpetas. Cada una incluye la librería con
  `virtual=`, llama a `Fn01` y `Fn02` en la línea 3 y tiene una tabla HTML
  de 40 filas con `<%= %>`. Una de cada diez declara además
  `Function Ajuste(Fn01)`: ese parámetro no debe contarse.

En total, 502 archivos y 1.455.749 bytes. La librería está abierta en un
buffer con su parser listo, como en el editor. Cada consulta valida que
devuelve 502 referencias de `Fn01` (declaración y asignación de retorno en
la librería, más una llamada por página, sin los parámetros homónimos) y
que cada página aparece una vez en la línea 3.

Cada proceso corre cinco rondas. Cada ronda invalida las cachés de páginas,
símbolos e includes de todos los archivos y mide:

- **primera**: `Fn01` con las cachés vacías. Incluye el barrido del sitio,
  el índice de includes y el parseo VBScript de cada archivo del conjunto.
- **siguiente**: la misma consulta otra vez.
- **otro nombre**: `Fn02`, que no se buscó antes en esa ronda.
- **memoria**: lo que retiene Lua después de la primera consulta, tras un
  `collectgarbage`.

Después de las rondas mide la consulta desde una página que usa `Fn01`
(primera y siguiente) y una consulta tras cambiar una página. Se informa la
mediana de cada proceso; la tabla da la mediana de las cinco medianas, con
el mínimo y el máximo entre paréntesis.

Para **antes** se antepusieron en el `runtimepath` los módulos de
`main` extraídos con `git archive`, con `ASP_BENCH_ANTES=1` para medir sin
validar el resultado. Cada proceso imprimió de qué archivo cargó
`asp.symbols` y se comprobó en todas las rondas.

## Resultados en milisegundos

| Consulta | Antes | Después |
| --- | ---: | ---: |
| Primera, desde la librería | 1,5 (1,5–1,7) | 231,2 (230,1–258,2) |
| Siguiente | 1,57 (1,29–1,80) | 7,79 (6,81–8,03) |
| Otro nombre, caché caliente | 1,53 (1,41–1,92) | 7,92 (6,94–8,22) |
| Primera desde una página | 1,25 (1,09–1,36) | 10,1 (9,84–13,6) |
| Siguiente desde una página | 1,12 (1,09–1,64) | 6,91 (6,55–8,25) |
| Tras cambiar una página | 2,23 (1,34–2,54) | 9,09 (7,97–10,3) |

| Referencias y lecturas | Antes | Después |
| --- | ---: | ---: |
| Referencias desde la librería | 2 | 502 |
| Referencias desde una página | 3 | 502 |
| Lecturas, primera consulta | 2 | 1.004 |
| Lecturas, consultas siguientes | 1 | 0 |
| Lecturas, siguiente desde una página | 2 | 0 |
| Lecturas tras cambiar una página | 1 | 2 |
| Memoria retenida | ~24 KB | 1.770 KB (1.725–1.799) |

Antes no recorría el sitio, así que sus tiempos no son comparables: solo
miraba la librería y su grafo, y releía de disco cada include en cada
consulta. La comparación sirve para ver el costo del alcance de sitio.

La primera consulta lee cada archivo dos veces: una el barrido de texto
de `asp.pages` y otra el parseo VBScript de las ocurrencias. Tras cambiar
una página, las dos lecturas son de esa página. La primera consulta desde
una página lee la librería tres veces: hasta entonces solo se había usado
como buffer, y la leen la caché de directivas, la de declaraciones y la de
ocurrencias.

## Qué consume el tiempo

En una corrida aparte con las mismas cachés vacías, el barrido de texto de
los 502 archivos tardó 64 a 73 ms y armar el índice de includes, 3,5 ms.
El resto de la primera consulta, unos 165 ms, es el parseo VBScript de las
501 fuentes del conjunto. Con la caché caliente, el barrido (listar
directorios y comprobar mtime y tamaño) tarda ~2 ms; el resto de los ~8 ms
es armar las 502 ubicaciones.

La memoria retenida es la tabla de ocurrencias por nombre de cada archivo
del conjunto, guardada como listas planas de números, más las
declaraciones que salen del mismo parseo.

## Repetir el caso

```sh
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/bench/symbols_site.lua
```

Para medir otra versión con la misma carga, anteponé sus módulos en el
`runtimepath` y omití las validaciones:

```sh
ASP_BENCH_ANTES=1 nvim --headless -u NONE --cmd 'set rtp+=.' \
  --cmd 'set rtp^=/ruta/a/otra/version' -l tests/bench/symbols_site.lua
```

El script borra sus archivos temporales y restaura las opciones al terminar.
