; Plegado de la plantilla (vim.treesitter.foldexpr()). Los bloques <% %>
; pliegan cuando ocupan más de una línea; <%= %> no pliega. El HTML de
; `content` lo pliega la query folds de html si está instalada (p. ej. la
; de nvim-treesitter), y el VBScript de `code`, queries/vbscript/folds.scm.

(code_directive) @fold
