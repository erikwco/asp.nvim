; Fase 1 - stopgap mínimo. El repo arrmee-wt/tree-sitter-vba no trae
; queries/*.scm propias (ver Makefile). Además, sus tokens de palabra
; clave (If/Then/End/Dim/Function/Sub/Set/For/Next/While/Wend/...) están
; definidos como RegExp inline vía el helper ci() sin envolverlos en
; token()/una regla con nombre, por lo que el parser compilado NO los
; expone como nodos (ni con nombre ni anónimos): no aparecen en
; node-types.json y cualquier patrón de query que los referencie
; -- con nombre o como literal "If" -- falla con "Invalid node type".
; Verificado inspeccionando árboles reales (vim.treesitter.get_string_parser)
; y probando vim.treesitter.query.parse('vba', ...) para cada palabra clave.
; Por eso este query cubre solo lo que el árbol realmente expone: la
; gramática vba se reemplaza por completo en la Fase 2.

(comment) @comment

(string_literal) @string

(number_literal) @number

(boolean_literal) @boolean

[
  (nothing_literal)
  (null_literal)
  (empty_literal)
] @constant.builtin

(sub_statement . (identifier) @function)

(function_statement . (identifier) @function)
