# asp.nvim: diagnósticos de VBScript
# Generar: vhs demo/05-diagnosticos.tape (desde la raíz del repo)
Output demo/05-diagnosticos.gif

Set FontSize 18
Set Width 1200
Set Height 800
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 70ms

Hide
Type "nvim -u demo/init.lua demo/app/carrito.asp"
Enter
Sleep 3s
Show
Sleep 3s

# Con Option Explicit: variables sin Dim, una Sub inexistente y un
# enlace a una página que no existe.
# ]d salta al siguiente y CTRL-W d abre su detalle.
Type "]d"
Sleep 800ms
Ctrl+W
Type "d"
Sleep 3s
Escape
Type "]d"
Sleep 800ms
Ctrl+W
Type "d"
Sleep 3s
Escape
Type "]d"
Sleep 800ms
Ctrl+W
Type "d"
Sleep 3s
Escape

# Se corrige el nombre: 500 ms después de la edición se vuelve a revisar.
Type "/totl"
Enter
Sleep 500ms
Type "cwtotal"
Escape
Sleep 2500ms

# Y se declara la variable que faltaba.
Type "/Dim subtotal"
Enter
Sleep 500ms
Type "A, descuento"
Escape
Sleep 3s
