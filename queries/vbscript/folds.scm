; Plegado de VBScript (vim.treesitter.foldexpr()). Neovim sólo pliega los
; nodos de más de una línea.

[
  (sub_statement)
  (function_statement)
  (property_statement)
  (class_statement)
  (for_statement)
  (for_each_statement)
  (while_statement)
  (do_statement)
  (select_case_statement)
  (with_statement)
] @fold

; Sólo el If de bloque: el de una línea no tiene End If. En la inyección
; combinada, un <% If %> ... <% End If %> pliega también el HTML de en medio.
(if_statement
  "End") @fold
