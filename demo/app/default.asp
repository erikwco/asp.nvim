<%@ Language="VBScript" %>
<!--#include file="includes/helpers.asp" -->
<html>
<head>
  <title>Tienda</title>
  <style type="text/css">
    body { font-family: sans-serif; margin: 2rem; }
    .total { font-weight: bold; color: #2b8a3e; }
  </style>
</head>
<body>
  <h1>Resumen del pedido</h1>
  <%
  Dim precio, conTasas, etiqueta
  precio = 100
  conTasas = AplicarIVA(precio)
  etiqueta = FormatearMoneda(conTasas)
  Response.Write "Pedido listo: " & etiqueta
  %>
  <p>Base: <%= FormatearMoneda(precio) %></p>
  <p class="total">Total con IVA: <%= etiqueta %></p>

  <script type="text/javascript">
    function confirmar() {
      var ok = window.confirm("Confirmar el pedido?");
      if (ok) { document.forms[0].submit(); }
    }
  </script>
  <button onclick="confirmar()">Pagar</button>
</body>
</html>
