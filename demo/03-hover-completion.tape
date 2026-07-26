# asp.nvim — hover y completion de los objetos intrínsecos de ASP
# Generar: vhs demo/03-hover-completion.tape   (desde la raíz del repo)
Output demo/03-hover-completion.gif

Set FontSize 18
Set Width 1200
Set Height 800
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 90ms

Hide
Type "nvim demo/app/default.asp"
Enter
Sleep 2500ms
Show

# Hover (K) sobre Response muestra la doc del objeto intrínseco.
Type "/Response"
Enter
Sleep 1200ms
Type "K"
Sleep 3s
Escape
Sleep 800ms

# Completion: tras "Server." aparecen los miembros (CreateObject, MapPath...).
Type "o"
Sleep 500ms
Type "Server."
Sleep 500ms
Ctrl+X
Ctrl+O
Sleep 3s
Escape
Sleep 1s
