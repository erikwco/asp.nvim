# Medición de referencias de páginas

Medición local del 20 de octubre de 2026, con Neovim 0.12.6 Release,
LuaJIT 2.1.1791890110 y Apple M4 Pro de 14 núcleos. La carga del equipo
rondó 3 a 4 durante la preparación. Las consultas de la serie alternada se midieron de forma secuencial.

La consulta con caché vacía bajó de 6.546 a 3.334 ms y la consulta siguiente
de 127 a 70 ms. Son medianas de cinco pares alternados entre
[`a633803`](https://github.com/erikwco/asp.nvim/commit/a633803e0dc0e587739d933519ad0d31e4ab18fb)
y la implementación corregida en `a28cd97`. Los rangos no se solapan.

## Carga y método

Se ejecutó `bench5k.lua` de la revisión, sin cambiar su carga. Crea 5.000
fuentes de unos 20 KB con SQL, comillas anidadas y dos enlaces por fuente,
un destino y cinco JS minificados. Distribuye las fuentes en 140 directorios
bajo 20 carpetas, con un `web.config` en la raíz. Cada consulta debe devolver
exactamente 5.000 referencias al destino.

Cada proceso de Neovim preparó sus archivos temporales antes de medir.
Se alternaron la versión anterior y la corregida, cinco veces cada una.
La versión anterior cargó `pages.lua` e `includes.lua` de `a633803` mediante
`dofile`; la corregida cargó los módulos del worktree. Se comprobó qué
versión estaba cargada. Un intento previo que no sustituyó los módulos
ya cargados se descartó antes de esta serie.

El cronómetro abarca `pages.references`, incluido el recorrido, las lecturas,
la búsqueda y la construcción de resultados. No abarca crear los archivos,
abrir el buffer ni parsear las capas LSP. La caché de páginas empieza vacía;
la caché del sistema operativo puede estar caliente tras crear los archivos.
La segunda consulta usa el mismo proceso y la caché de páginas llena.
No hubo errores y las veinte consultas devolvieron 5.000 referencias.
Cada consulta corregida emitió exactamente un aviso INFO. Desde el PR #9
el aviso depende de lo que lee la consulta: sale si lee 2.000 archivos o
tarda un segundo, así que en esta carga solo lo emitiría la primera
consulta.

## Resultados en milisegundos

| Par | Vacía antes | Vacía después | Siguiente antes | Siguiente después |
| --- | ---: | ---: | ---: | ---: |
| 1 | 6546 | 3406 | 133 | 77 |
| 2 | 6583 | 3386 | 127 | 75 |
| 3 | 6593 | 3334 | 129 | 70 |
| 4 | 6376 | 3281 | 118 | 69 |
| 5 | 6419 | 3291 | 118 | 69 |
| Mediana | 6546 | 3334 | 127 | 70 |
| Mínimo | 6376 | 3281 | 118 | 69 |
| Máximo | 6593 | 3406 | 133 | 77 |

La reproducción inicial, anterior a la serie alternada, dio 6.693 y 129 ms.
La nota anterior de 316 y 60 ms usaba fuentes de 1,7 KB y una distribución
de enlaces distinta. No es una comparación válida con este caso de 20 KB.

## Qué consume el tiempo

En `prof.lua`, con 2.000 fuentes, la versión anterior llamó a `M.resolve`
3.846.000 veces. La corregida no lo llamó durante el barrido. El prefiltro
inline descarta texto sin extensión de página antes de normalizar rutas,
y la caché guarda candidatos sin consultar la existencia del destino.
La consulta con caché vacía pasó de 2.502 a 1.395 ms en esa reproducción.
Solo leer los archivos y recorrer sus comillas costó 586 ms después del
cambio. El barrido textual sigue teniendo un coste proporcional al contenido.
Estas mediciones de diagnóstico no se mezclaron con la serie anterior.

En el primer `bench5k.lua`, calcular `virtual_root_for` para cada archivo
costó 84 ms, frente a 129 ms de la consulta con caché. La implementación
corregida calcula esa raíz una vez por directorio en cada consulta.
La consulta con caché sigue recorriendo directorios y comprobando los
metadatos de todos los archivos.

## Repetir el caso con validaciones

El script versionado reproduce la carga de `bench5k.lua` y además comprueba
las rutas, líneas, columnas y lecturas. Ejecuta cinco pares de consultas en
un proceso. Cada par vacía la caché de páginas antes de la primera consulta.

```sh
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/bench/pages_references.lua
```

La ejecución de validación creó 5.006 archivos y 100.843.945 bytes.
Los cinco pares pasaron. Cada primera consulta leyó 5.006 archivos y la
siguiente, cero. Todas devolvieron 5.000 referencias en la línea 240,
columnas 9 a 26.
El script borra sus archivos temporales y restaura las opciones al terminar.
