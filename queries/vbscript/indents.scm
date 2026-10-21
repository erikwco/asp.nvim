; Indentación de VBScript para el módulo indent de nvim-treesitter, para
; quien apague el indentexpr de asp.nvim con setup({ indent = false }). El
; que se prueba es el propio (lua/asp/indent.lua); esta query sigue sus
; reglas: cada bloque indenta su cuerpo y Select Case indenta dos niveles,
; uno para el Case y otro para sus sentencias.

[
  (sub_statement)
  (function_statement)
  (property_statement)
  (class_statement)
  (for_statement)
  (for_each_statement)
  (while_statement)
  (do_statement)
  (with_statement)
  (select_case_statement)
  (case_clause)
] @indent.begin

; El cuerpo de Case Else no tiene case_clause: es el único block hijo
; directo del Select, y abre su nivel desde su primera línea.
((select_case_statement
  (block) @indent.begin)
  (#set! indent.immediate 1)
  (#set! indent.start_at_same_line 1))

; Sólo el If de bloque: el de una línea no tiene End If.
(if_statement
  "End") @indent.begin

; Las palabras de cierre de cada bloque (no el Next de On Error Resume Next).
[
  (sub_statement "End" @indent.end @indent.branch)
  (function_statement "End" @indent.end @indent.branch)
  (property_statement "End" @indent.end @indent.branch)
  (class_statement "End" @indent.end @indent.branch)
  (if_statement "End" @indent.end @indent.branch)
  (with_statement "End" @indent.end @indent.branch)
  (select_case_statement "End" @indent.end @indent.branch)
  (for_statement "Next" @indent.end @indent.branch)
  (for_each_statement "Next" @indent.end @indent.branch)
  (do_statement "Loop" @indent.end @indent.branch)
  (while_statement "Wend" @indent.end @indent.branch)
]

[
  (elseif_clause)
  (else_clause)
] @indent.branch
