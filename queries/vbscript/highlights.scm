; Queries de resaltado para tree-sitter-vbscript (fork Fase 2).
;
; Desde la Task 7, ci() en grammar.js envuelve cada palabra clave con
; alias(new RegExp(word, 'i'), word): cada keyword pasa a ser un token
; anonimo consultable por su grafia canonica (p. ej. "If", "GoTo"), sin
; alterar la forma de ningun nodo con nombre (el corpus sigue verde tal
; cual). Cada grafia listada abajo se cotejo 1:1 contra los argumentos
; reales de ci(...) en grammar.js — no contra el brief de la task, que
; traia una lista de partida.

(comment) @comment

(string_literal) @string

(date_literal) @string.special

(number_literal) @number

(boolean_literal) @boolean

[
  (nothing_literal)
  (null_literal)
  (empty_literal)
] @constant.builtin

(identifier) @variable

(member_expression
  (identifier) @variable.member)

(function_call
  (identifier) @function.call)

(sub_statement . (identifier) @function)

(function_statement . (identifier) @function)

(class_statement
  name: (identifier) @type)

; Control de flujo. "In" se anadio (no estaba en la lista de partida del
; brief) porque ci('In') existe en grammar.js (for_each_statement).
[
  "If" "Then" "Else" "ElseIf" "End"
  "Select" "Case" "For" "To" "Step" "Next" "Each" "In"
  "While" "Wend" "Do" "Loop" "Until"
  "With" "Exit" "GoTo" "Resume" "On" "Error"
] @keyword.conditional

; Declaraciones y modificadores. "New" se elimino: no existe ningun
; ci('New') en grammar.js (VBScript real usa CreateObject, no New, y
; esta gramatica no implementa la forma New). El resto de entradas que
; no estaban en la lista de partida del brief (Friend, Optional,
; ParamArray, Preserve, Base, Compare, Binary, Text, Database, Module,
; Mid) se anadieron porque ci(...) las usa realmente en grammar.js.
[
  "Sub" "Function" "Property" "Get" "Let" "Class"
  "Dim" "Const" "Set" "ReDim" "Erase"
  "Public" "Private" "Friend" "Static" "Option" "Explicit"
  "Call" "ByVal" "ByRef" "Optional" "ParamArray" "Preserve"
  "Base" "Compare" "Binary" "Text" "Database" "Module" "Mid"
] @keyword

; Operadores logicos/de palabra. "Eqv" e "Imp" se anadieron: ci('Eqv') y
; ci('Imp') existen en binary_expression pero no estaban en la lista de
; partida del brief.
[
  "And" "Or" "Not" "Xor" "Mod" "Is" "Eqv" "Imp"
] @keyword.operator

[
  "=" "<" ">" "<=" ">=" "<>" "+" "-" "*" "/" "\\" "&" "^"
] @operator
