<!--#include file="constantes.inc" -->
<%
Function FormatearMoneda(valor)
  FormatearMoneda = "$" & FormatNumber(valor, DECIMALES)
End Function

Sub RespuestaRapida()
  Response.Write "ok"
End Sub
%>
