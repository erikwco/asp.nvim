<!--#include file="constantes.inc" -->
<%
' Utilidades compartidas de la tienda

Function FormatearMoneda(valor)
  FormatearMoneda = MONEDA & FormatNumber(valor, DECIMALES)
End Function

Function AplicarIVA(monto)
  AplicarIVA = monto + (monto * IVA / 100)
End Function
%>
