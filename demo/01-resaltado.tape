# asp.nvim — resaltado de las tres capas (ASP + HTML + JavaScript)
# Generar: vhs demo/01-resaltado.tape   (desde la raíz del repo)
Output demo/01-resaltado.gif

Set FontSize 18
Set Width 1200
Set Height 800
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 60ms

Hide
Type "nvim demo/app/default.asp"
Enter
Sleep 2500ms
Show

# El VBScript (<% %>), el HTML y el JavaScript de <script> se resaltan
# cada uno con su propio lenguaje, en un mismo archivo.
Sleep 2s
Type "jjjj"
Sleep 1500ms
Type "jjjjjj"
Sleep 2s
Type "gg"
Sleep 2s
