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
Type "nvim -u demo/init.lua demo/app/default.asp"
Enter
Sleep 4s
Show

# Cursor sobre un uso de FormatearMoneda...
Type "/FormatearMoneda(conTasas"
Enter
Sleep 2s

# ...y saltamos a su definición, que vive en otro archivo.
Ctrl+]
Sleep 3s

# El cursor aterriza en Function FormatearMoneda en includes/helpers.asp;
# K muestra su firma.
Type "K"
Sleep 3s
Escape
Sleep 1500ms
