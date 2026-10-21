<html>
<head>
<link rel="stylesheet" href="/css/estilo.css">
<script src="js/app.js"></script>
<script src="js/falta.js"></script>
</head>
<body>
<a href="existe.asp">existe</a>
<a href="no_existe.asp">no existe</a>
<a href="detalle.asp?id=<%= id %>">dinámico</a>
<a href="http://ejemplo.com/remota.asp">absoluta</a>
<!-- <a href="viejo.asp">comentado</a> -->
<%
Dim id
id = 1
Response.Redirect "falta.asp?id=" & id
' Response.Redirect "viejo2.asp"
%>
<script>
location.href = 'otra/' + id + '.asp';
</script>
</body>
</html>
