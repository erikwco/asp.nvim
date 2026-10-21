# Tokens semánticos

Desde la raíz del repositorio, después de `make parsers-test`:

```sh
nvim --headless -u tests/minimal_init.lua -i NONE \
  -l tests/bench/semantic_tokens.lua
```

Sin parámetros genera una página sintética de 72.625 bytes y 4.900 tokens.
Para medir una página propia, usá `ASP_BENCH_FILE=/ruta/pagina.asp`.
El archivo no se modifica. La edición ocurre en el buffer y se descarta.

Cada proceso mide la primera llamada a `full`, otra sin cambios y otra
tras insertar un espacio. Abre con `noautocmd` para incluir la carga de
los parsers y las cachés en la primera medición. Verifica que haya tokens
y que su cantidad no cambie. Repetí el comando en procesos nuevos para
medir llamadas frías; repetir `full` en el mismo buffer mide la caché.

## Revisión del PR #16

Página real de 318.652 bytes, 8.745 líneas y 6.609 tokens. Cinco procesos
por versión y por implementación, alternando antes y después. Medición
del 21 de octubre de 2026 en macOS arm64, con 14 núcleos y carga cercana
a 2. No se incluyó la instrumentación del perfil en las muestras.

- Neovim 0.12.6. Primera llamada, mediana de 104,51 a 52,79 ms. Rango
  final de 51,84 a 53,53 ms. En caliente, 4,57 ms; tras editar, 40,19 ms.
- Neovim 0.10.4. Primera llamada, mediana de 155,16 a 80,11 ms. Rango
  final de 79,05 a 207,42 ms. En caliente, 7,73 ms; tras editar, 49,66 ms.

El índice de ayuda de VBScript y el índice JS pedían `parse(true)` al
parser del buffer. Eso parseaba el JavaScript original de toda la página,
además del árbol JS propio que enmascara las regiones ASP. El índice de
VBScript ahora pide sólo su capa y el de JS usa el HTML ya parseado o un
parser HTML sin inyecciones. El perfil de 0.10 pasó de dos parseos JS a
uno. Los 6.609 tokens y los resultados de navegación se conservaron.

La mediana fría queda debajo de 150 ms en ambas versiones. Ese límite
no se cumple en todas las corridas de 0.10: una de las cinco tardó
207,42 ms. Una prueba adicional reprodujo 205,60 ms de pared y 205,59 ms
de CPU; no fue sólo espera del sistema. El origen de esa variación sigue
pendiente. La medición caliente de ese proceso también fue más lenta.
