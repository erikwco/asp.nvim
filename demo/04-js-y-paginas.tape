# asp.nvim: JavaScript y páginas
# Generar: vhs demo/04-js-y-paginas.tape (desde la raíz del repo)
Output demo/04-js-y-paginas.gif

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
Type "/onclick.*\zsconfirmar"
Enter
Show
Sleep 2s

# Del onclick a la función del script.
Ctrl+]
Sleep 2500ms

# La función llama a un global del script src.
Type "/abrirDetalle"
Enter
Sleep 1s
Ctrl+]
Sleep 2s
Ctrl+T
Sleep 500ms

# Un literal de página abre el destino.
Type "/otra.asp"
Enter
Sleep 1s
Ctrl+]
Sleep 2s

# Desde la primera línea de la página, lista quién la usa.
Type ":lua vim.lsp.buf.references()"
Enter
Sleep 4s
