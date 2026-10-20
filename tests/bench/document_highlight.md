# Resaltado de ocurrencias frente a referencias

Medición del 20 de octubre de 2026 en macOS, Apple M4 Pro de 14 núcleos,
Neovim 0.12.6 Release. Buffers y cachés calientes. Cada fila contiene siete
pares alternados de llamadas a los handlers de `documentHighlight` y
`references`. La última columna mide otras siete consultas de resaltado
mediante el cliente LSP real, incluida la entrega diferida de la respuesta.

Los valores son medianas en milisegundos, con mínimo y máximo entre
corchetes. El equipo tenía carga de otras aplicaciones: load average de
6,15 al iniciar, con Spotlight, WindowServer, Vitals y Chrome activos.

| Caso | documentHighlight | references | Resaltado por cliente LSP |
| --- | ---: | ---: | ---: |
| 3.000 Functions, variable de página | 161,17 [152,08–171,21] | 151,22 [139,30–164,00] | 162,01 [152,77–175,50] |
| 3.000 Functions, variable local | 131,99 [119,91–160,02] | 139,27 [117,33–148,89] | 119,93 [116,13–129,17] |
| 3.000 Functions, nombre de función | 83,55 [77,93–95,85] | 87,67 [82,90–88,91] | 87,97 [83,42–99,41] |
| 20 includes, variable de página | 0,181 [0,126–0,615] | 34,16 [32,69–49,56] | 0,192 [0,134–0,343] |

En el buffer grande, el costo del resaltado queda cerca del de referencias.
Los intervalos se solapan, por lo que no hay evidencia de una diferencia
pequeña entre ambos. El buffer tiene 18.005 líneas. Cada consulta devuelve
6.003 ocurrencias de la variable de página, cuatro del local o dos de la
función, según la fila. Ambos handlers devuelven los mismos rangos del buffer.

El caso de includes tiene 25 líneas en el buffer y 20 archivos de 452 líneas,
con 150 funciones por include. El resaltado devuelve tres ocurrencias y
referencias devuelve 3.003. Un espía de `io.open` contó cero aperturas de
fuentes externas por resaltado y 20 por consulta de referencias, en los
siete pares. No se mide aquí una declaración externa: si el nombre no está
declarado en el buffer, el resaltado todavía consulta su definición para
decidir el tipo de marca. En JS, además, una declaración ausente produce
una lista vacía.

Todos los resultados se verificaron fuera del intervalo cronometrado:
cantidad, igualdad de rangos del buffer y tipos Write/Read. Hubo cero errores
y ninguna respuesta vacía inesperada. Los tests de regresión comprueban
también que un global JS del buffer no lee sus scripts externos ni includes.

Una ejecución separada instrumentó `symbols.collect`, sin incluir esa
instrumentación en las muestras anteriores. El resaltado hizo una sola
colección por consulta. En las tres consultas del buffer grande consumió
64,05 de 159,90 ms, 64,90 de 129,85 ms y 58,72 de 89,65 ms, respectivamente.
El costo restante incluye la búsqueda de ocurrencias y la conversión a
marcas LSP. Evitar una segunda colección elimina trabajo, pero recorrer
el buffer sigue costando tiempo. Con includes, se evita además leer y
parsear ocurrencias de otros archivos que luego se descartarían.

Para repetir la medición desde la raíz del repo:

```sh
make parsers-test
PR8_BENCH_OUTPUT=/tmp/document-highlight.json nvim --headless \
  -u tests/minimal_init.lua -l tests/bench/document_highlight.lua
```

El script crea y borra sus fixtures temporales. Emite cada fila como JSON
y guarda las muestras individuales cuando se define `PR8_BENCH_OUTPUT`.
No incluye el costo de abrir y parsear por primera vez el archivo ni mide
latencia de dibujo de Neovim.
