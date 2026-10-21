# Ayuda JavaScript en caliente

Medición local del 21 de octubre de 2026 sobre la implementación de
`feat/js-help`, con Apple M4 Pro de 14 núcleos. Completion por LSP tarda
1,866 ms en Neovim 0.12.6 y 2,083 ms en 0.10.4. Son medianas de cinco
procesos por versión; las consultas no leen contenido de disco ni crean
parsers. No se compara velocidad entre versiones ni contra una revisión
anterior: la ayuda JS es nueva y el equipo tenía otros procesos activos.

## Carga y comprobaciones

`js_help.lua` genera una página de exactamente 20.480 bytes, con 20
includes y cinco archivos `.js` locales. La página contiene HTML y JS,
una función propia, una variable y llamadas repetidas. Cada include
declara una función JS y contiene un bloque VBScript. Cada `.js` tiene
diez funciones. No usa ni copia páginas propietarias.

La posición de completion está al final del script, con prefijo vacío.
Cada consulta comprueba 109 resultados e incluye la función propia, la
del último include, la del último `.js`, una variable y `document`.
También comprueba que no aparezcan `Response` ni la keyword `function`.
Hover consulta la función del último include. SignatureHelp consulta su
segundo argumento y comprueba el índice activo y los dos parámetros.

Cada proceso calienta las tres ayudas con 15 consultas y hace una
consulta LSP de calentamiento. Después mide 200 completions directas,
100 hovers, 100 signatureHelp y 100 completions mediante
`vim.lsp.buf_request_sync`. La comprobación del resultado está dentro del
intervalo medido; cualquier error aborta el proceso con código distinto
de cero. Los diagnósticos están desactivados para aislar la ayuda.

Se alternaron cinco procesos de Neovim 0.12.6 Release y cinco de Neovim
0.10.4 Release (`ge96f75a4e6`). La carga de un minuto del equipo pasó de
4,29 a 4,92 durante la serie. Había actividad de aplicaciones del usuario
y servicios del sistema; no se interrumpió. La variación de 0.10.4 impide
atribuir diferencias pequeñas a la versión de Neovim.

## Resultados

Mediana de las cinco medianas por proceso, en milisegundos. Entre
paréntesis, el mínimo y el máximo de esas cinco medianas.

| Consulta | Neovim 0.12.6 | Neovim 0.10.4 |
| --- | ---: | ---: |
| Completion directa | 1,854 (1,765 a 1,872) | 2,112 (1,126 a 2,185) |
| Hover | 0,463 (0,458 a 0,472) | 0,431 (0,308 a 0,465) |
| SignatureHelp | 1,824 (1,813 a 1,895) | 1,588 (1,391 a 1,653) |
| Completion por LSP | 1,866 (1,793 a 2,002) | 2,083 (1,141 a 2,250) |

Medianas de completion por proceso, en orden de ejecución:

- 0.12.6 directa: 1,854; 1,778; 1,865; 1,765; 1,872 ms.
- 0.10.4 directa: 2,116; 2,185; 1,186; 1,126; 2,112 ms.
- 0.12.6 LSP: 1,861; 1,866; 1,793; 1,891; 2,002 ms.
- 0.10.4 LSP: 2,191; 2,250; 1,230; 1,141; 2,083 ms.

En todos los procesos hubo cero errores, cero llamadas a `io.open` y
cero llamadas a `vim.treesitter.get_string_parser` durante las muestras
calientes. Sí se consulta metadata con `fs_stat` para validar mtime y
tamaño y para resolver las rutas; no se cachean destinos inexistentes.

Un perfil separado en 0.12.6, fuera de las muestras anteriores, midió
200 completions. Del total de 348,95 ms, 141,20 ms correspondieron a
`js.visible` (40,5 %) y 56,84 ms a la máscara textual (16,3 %).
`js.visible` recorre los scopes, el grafo de includes y los externos,
valida sus cachés y construye la lista de bindings. La medición cubre
esa consulta completa y la vía LSP; no sólo el filtrado de un catálogo.
No se midió la primera consulta con cachés vacías.

## Repetir

Desde la raíz del repo, después de `make parsers-test`:

```sh
nvim --headless -u tests/minimal_init.lua -i NONE \
  -c "lua dofile('tests/bench/js_help.lua')"
/tmp/nvim010/nvim-macos-arm64/bin/nvim --headless \
  -u tests/minimal_init.lua -i NONE \
  -c "lua dofile('tests/bench/js_help.lua')"
```

Repetí el par cinco veces. Cada proceso imprime JSON con tamaño, catálogo,
resultados, tiempos, lecturas, parseos y errores. `ASP_JS_PROFILE=1` añade
el perfil por funciones después de medir. El script borra su directorio
temporal y restaura las funciones instrumentadas al terminar. La suite
`make test` también verifica la ausencia de lecturas y parseos en caliente.
