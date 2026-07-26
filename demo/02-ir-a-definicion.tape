# asp.nvim — ir a la definición a través de <!--#include -->
# FormatearMoneda se usa en default.asp pero se define en includes/helpers.asp.
# Generar: vhs demo/02-ir-a-definicion.tape   (desde la raíz del repo)
Output demo/02-ir-a-definicion.gif

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

# Buscamos un uso de FormatearMoneda...
Type "/etiqueta = Format"
Enter
Sleep 1500ms

# ...y saltamos a su definición (LazyVim: gd), que vive en otro archivo.
Type "gd"
Sleep 3s

# El cursor aterriza en Function FormatearMoneda dentro de includes/helpers.asp
Type "K"
Sleep 2500ms
Escape
Sleep 1s
