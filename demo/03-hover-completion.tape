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
Type "nvim -u demo/init.lua demo/app/default.asp"
Enter
Sleep 4s
Show

# Hover (K) sobre Response muestra la doc del objeto intrínseco.
Type "/Response.Write"
Enter
Sleep 1500ms
Type "K"
Sleep 3s
Escape
Sleep 1s

# Completion: en una línea nueva dentro del bloque, tras "Server." aparecen
# sus miembros (CreateObject, MapPath, ...).
Type "A"
Enter
Type "Server."
Sleep 800ms
Ctrl+X
Ctrl+O
Sleep 3s
Escape
Sleep 1500ms
