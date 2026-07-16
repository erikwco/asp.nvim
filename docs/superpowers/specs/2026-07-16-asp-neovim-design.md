# Diseño: soporte de Classic ASP para Neovim (asp.nvim)

**Fecha:** 2026-07-16
**Estado:** aprobado en sesión de brainstorming

## Objetivo

Plugin completo y publicable para Neovim que dé soporte de primera clase a Classic ASP
(VBScript de servidor + HTML + JavaScript de cliente en un mismo archivo):

1. Reconocimiento (resaltado, indentación, folding, textobjects) correcto de cada región.
2. Navegación: go-to-definition, referencias y símbolos, incluyendo definiciones que viven
   en archivos referenciados con `<!--#include file/virtual="..."-->`.

## Contexto y estado del arte (verificado 2026-07-16)

- No existe ningún LSP para Classic ASP/VBScript. El nicho está vacío.
- No existe gramática tree-sitter de VBScript, pero sí de VBA:
  [arrmee-wt/tree-sitter-vba](https://github.com/arrmee-wt/tree-sitter-vba)
  (basada en la especificación de Microsoft, case-insensitive, MIT). VBScript es
  aproximadamente un subconjunto de VBA → se adapta por fork en lugar de escribir desde cero.
- Lo único existente para ASP en Vim/Neovim es el syntax legado por regex
  ([aspvbs.vim](https://github.com/vim-scripts/aspvbs.vim)), sin navegación.
- El patrón de "capa de plantilla" está resuelto en el ecosistema
  (`tree-sitter-embedded-template`, usado por ERB/EJS, mismos delimitadores `<% %>`).

## Decisiones tomadas

- **Lado servidor objetivo:** VBScript (con soporte incidental de JScript vía directiva).
- **Alcance de navegación:** archivo actual + su grafo de includes (v1); `workspace/symbol`
  cubre el proyecto completo.
- **Enfoque elegido (A):** gramáticas tree-sitter + plugin Lua con LSP in-process.
  Descartados: (B) LSP externo multi-editor — posible fase 2; (C) solo piezas existentes —
  se recupera como fase 1 del plan.

## Arquitectura

Tres piezas:

```
┌─────────────────────────────────────────────────────┐
│ asp.nvim (plugin Lua)                               │
│  · filetype .asp/.inc → "asp"                       │
│  · servidor LSP in-process (vim.lsp.start,          │
│    cmd como función — sin proceso externo)          │
│  · grafo de includes + índice de símbolos           │
│  · health checks, config, docs                      │
└──────────────┬──────────────────────────────────────┘
               │ consume vía nvim-treesitter
┌──────────────┴──────────────┐  ┌────────────────────┐
│ tree-sitter-aspclassic      │  │ tree-sitter-       │
│ (capa plantilla)            │  │ vbscript           │
│  · <% %>, <%= %>, <%@ %>    │  │ (fork de           │
│  · contenido vs. código     │  │  tree-sitter-vba)  │
│  · <!--#include ... -->     │  │                    │
│    como nodo propio         │  └────────────────────┘
└─────────────────────────────┘
```

### Cadena de injections

1. Buffer `.asp` → `tree-sitter-aspclassic`: distingue bloques de código (`<% %>`, `<%= %>`),
   directivas (`<%@ %>`) y contenido.
2. Contenido → inyección **HTML** (gramática existente).
3. Bloques de código → inyección **VBScript**; si `<%@ Language=JScript %>` está presente,
   se inyecta **JavaScript**.
4. Dentro del HTML, `<script>`/`<style>` → JavaScript/CSS por las queries estándar de
   tree-sitter-html.

Solo se mantienen las dos gramáticas pequeñas propias; HTML/JS/CSS quedan en manos de la
comunidad.

**Decisión clave:** `<!--#include file/virtual="..."-->` es un nodo de primera clase de la
gramática de plantilla (no un comentario HTML), porque es la entrada al grafo de includes.

## LSP in-process

Servidor implementado como función Lua dentro de Neovim (≥0.10), registrado para el
filetype `asp`. `gd`, `gr`, `K`, Telescope y cualquier UI de LSP funcionan sin configuración.

### Capacidades v1

| Método | Comportamiento |
|---|---|
| `textDocument/definition` | Function/Sub/Class/Const/variable, en archivo actual + grafo de includes |
| `textDocument/references` | Referencias dentro del grafo de includes |
| `textDocument/documentSymbol` | Outline del archivo |
| `workspace/symbol` | Símbolos de todo el proyecto |
| `textDocument/hover` | Firma + docs embebidas de intrínsecos ASP (Response, Request, Server, Session, Application) |
| `textDocument/completion` | Símbolos del grafo + miembros de intrínsecos |

### Flujo de datos

Al abrir un buffer: (1) parseo tree-sitter; (2) query extrae nodos `#include` y resuelve
rutas — `file=` relativo al archivo, `virtual=` relativo a una **raíz virtual configurable**
(autodetección hacia arriba por marcador `.git`/`web.config`, con override); (3) parseo
recursivo de incluidos (desde disco si no están abiertos), con detección de ciclos; índice
en memoria `símbolo → {archivo, rango}`, invalidado por archivo (`BufWritePost`/watchers).

### Semántica de resolución

Namespace plano por página+includes (fiel a VBScript en ASP). Orden: (1) local a la función
actual, (2) nivel de página, (3) includes en orden. Comparación **case-insensitive**.

### Manejo de errores

- Include no resuelto → diagnóstico LSP (warning) en la línea del include.
- Ciclo de includes → se corta la recursión y se reporta.
- Errores de sintaxis → árboles parciales de tree-sitter; la navegación sigue funcionando
  (degradación suave).

### Fuera de alcance v1

Type-checking; rename; navegación dentro del JavaScript de cliente (se documenta la
integración opcional con otter.nvim); soporte COM (`Server.CreateObject`) más allá de
completion estática de objetos ADO comunes.

## Testing

- **Gramáticas:** corpus nativo de tree-sitter. El fork hereda el corpus de VBA y agrega
  las diferencias de VBScript (sin `As Type`, `Class...End Class`, `Option Explicit`,
  continuación `_`, separador `:`, literales `#fecha#`). Plantilla: `<% %>` multilínea,
  bloques en atributos HTML, includes con ambos tipos de comillas.
- **Plugin:** busted/plenary sobre fixtures que simulan un proyecto ASP real (includes
  anidados, virtuales, ciclo deliberado, include roto). Cada capacidad LSP probada contra
  los fixtures.
- **CI:** GitHub Actions — gramáticas en Linux/macOS/Windows, corpus, tests de plugin en
  Neovim estable y nightly.

## Fases

Cada fase termina en algo usable; el plugin es útil desde la fase 2.

| Fase | Entregable | Estimación |
|---|---|---|
| 1 | Gramática de plantilla + injections con tree-sitter-vba tal cual → resaltado 3 capas | ~1 semana |
| 2 | Fork tree-sitter-vbscript con corpus propio | 1–2 semanas |
| 3 | LSP in-process: documentSymbol + definition en archivo actual | ~1 semana |
| 4 | Grafo de includes: definition/references/workspace-symbol cross-file + diagnósticos | 1–2 semanas |
| 5 | Hover/completion intrínsecos, :help, health check, CI, publicación | ~1 semana |

**Total: 5–7 semanas a tiempo parcial.**

## Publicación

GitHub, instalable con lazy.nvim (dependencia: nvim-treesitter). Gramáticas registradas
vía `parser_config`; propuesta posterior de inclusión oficial en nvim-treesitter. README
con GIFs; anuncio en r/neovim.

## Riesgo principal

Fidelidad del fork VBA→VBScript (las clases de VBScript difieren; VBA tiene construcciones
ausentes en VBScript). Mitigación: la fase 1 valida toda la arquitectura de injections con
VBA sin modificar antes de invertir en el fork, y el corpus de la fase 2 se construye con
archivos ASP reales del usuario.
