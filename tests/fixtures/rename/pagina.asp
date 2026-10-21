<!--#include file="inc/utilidades.inc"-->
<%
Dim total, rs, i
total = 0
i = 1
Set rs = Server.CreateObject("ADODB.Recordset")
If Not rs.EOF Then
  total = Len("abc")
End If
Response.Write Redondear(total)

Sub Sumar(cantidad)
  Dim i
  For i = 1 To cantidad
    total = total + i
  Next
End Sub

Function Promedio(lista)
  Dim i, suma
  For i = 0 To UBound(lista)
    suma = suma + lista(i)
  Next
  Promedio = Redondear(suma / (UBound(lista) + 1))
End Function

calc.Redondear 2
Response.Redirect "otra.asp"
%>
<html>
<head>
<script src="js/app.js"></script>
<script>
function iniciar() {
  document.title = "Inicio";
  validarFormulario();
}
</script>
</head>
<body>
<div class="caja">
<button onclick="validarFormulario()">Enviar</button>
</div>
</body>
</html>
