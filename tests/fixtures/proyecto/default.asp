<%@ Language="VBScript" %>
<!--#include file="includes/helpers.asp" -->
<!--#include virtual="/lib/db.inc" -->
<html>
<head><title>Proyecto de prueba</title></head>
<body>
<%
Dim conn, totalPagina
Set conn = AbrirConexion()
totalPagina = FormatearMoneda(BASE_PRECIO * IVA)
Set conn = Server.CreateObject("ADODB.Connection")
Response.Write totalPagina
respuestarapida
%>
</body>
</html>
