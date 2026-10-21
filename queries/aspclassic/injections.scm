; Todo el contenido fuera de <% %> es HTML (un solo árbol combinado,
; para que el HTML partido por bloques ASP parse como documento único).
((content) @injection.content
  (#set! injection.combined)
  (#set! injection.language "html"))

; Los bloques <% %> y <%= %> son VBScript (gramática propia vbscript).
; También combinado: patrones como <% If x Then %>...<% End If %>
; forman un solo programa. Cada bloque entra con sus delimitadores, que la
; gramática lee como separadores: sin ellos, el final de un bloque y el
; comienzo del siguiente (`<%=a%>...<%=b%>`) se leían como un solo token.
(([(code_directive) (output_directive)] @injection.content)
  (#set! injection.combined)
  (#set! injection.include-children)
  (#set! injection.language "vbscript"))
