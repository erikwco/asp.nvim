; Todo el contenido fuera de <% %> es HTML (un solo árbol combinado,
; para que el HTML partido por bloques ASP parse como documento único).
((content) @injection.content
  (#set! injection.combined)
  (#set! injection.language "html"))

; Todo el código de <% %> y <%= %> es VBScript (gramática propia vbscript).
; También combinado: patrones como <% If x Then %>...<% End If %>
; forman un solo programa.
((code) @injection.content
  (#set! injection.combined)
  (#set! injection.language "vbscript"))
