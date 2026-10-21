<!--#include file="base.inc"-->
<%
Function FormatearPrecio(valor)
  FormatearPrecio = "$" & Redondear(valor)
End Function
%>
