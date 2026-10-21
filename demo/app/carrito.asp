<%@ Language="VBScript" %>
<% Option Explicit %>
<!--#include file="includes/helpers.asp" -->
<html>
<body>
  <h1>Carrito</h1>
  <%
  Dim subtotal, total
  subtotal = 250
  total = AplicarIVA(subtotal)
  descuento = 10
  Response.Write FormatearMoneda(totl)
  Call EnviarRecibo(total)
  %>
  <a href="pagar.asp">Pagar</a>
  <a href="default.asp">Seguir comprando</a>
</body>
</html>
