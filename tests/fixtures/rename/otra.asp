<!--#include file="inc/utilidades.inc"-->
<%
Dim precio
precio = Redondear(10.456)
Response.Write FormatearPrecio(precio)
Response.Write util.Redondear
%>
