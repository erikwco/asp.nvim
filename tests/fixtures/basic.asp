<%@ Language="VBScript" %>
<!--#include file="lib/helpers.asp" -->
<html>
  <head>
    <script type="text/javascript">
      function saludar() { alert("hola"); }
    </script>
  </head>
  <body>
    <% Dim nombre
       nombre = "mundo"
       Response.Write "Hola, " & nombre %>
    <p>Total: <%= 2 + 2 %></p>
  </body>
</html>
