# asp.nvim: renombrar símbolos
# Generar: vhs demo/06-rename.tape (desde la raíz del repo)
Output demo/06-rename.gif

Set FontSize 18
Set Width 1200
Set Height 800
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 70ms

Hide
Type "nvim -u demo/init.lua demo/app/default.asp"
Enter
Sleep 3s
Type "/FormatearMoneda"
Enter
Show
Sleep 2s

# Renombra la Function del include desde una página que la usa: cambia la
# declaración en includes/helpers.asp y los usos de las páginas que lo
# incluyen.
Type ":lua vim.lsp.buf.rename()"
Enter
Sleep 1500ms
Ctrl+U
Type "FormatoMoneda"
Sleep 800ms
Enter
Sleep 2500ms

# Los archivos cambiados quedan abiertos y sin guardar: otra página que
# incluye helpers.asp y la declaración.
Type ":b carrito"
Enter
Sleep 3s
Type ":b helpers"
Enter
Sleep 3s
