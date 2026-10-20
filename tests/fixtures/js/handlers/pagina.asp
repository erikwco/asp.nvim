<%@ Language="VBScript" %>
<!--#include file="inc/form.inc" -->
<!--#include file="inc/botones.inc" -->
<!--#include file="inc/enlaces.inc" -->
<%
Dim id
id = 7
%>
<html>
<head>
<script src="js/validar.js"></script>
<script>
function reinitAsk() { return confirm('¿Reiniciar?'); }
function borrar(n) { return n; }
var contador = 0;
contador++;
</script>
</head>
<body onload="reinitAsk()">
<input type="button" class="btnTransfer" id="btn_reset_transfer" onclick="reinitAsk();" value="Cancelar">
<select name="campo" onchange="validarCampo(this)"></select>
<form method="post" onsubmit="return enviarFormulario(this)">
<input type="button" onclick="borrar(<%= id %>); <%= handler %>" value="Borrar">
<input type=button onclick=reinitAsk() value=SinComillas>
<input type="button" ONCLICK="reinitAsk()" value="Mayusculas">
<input type="text" value="reinitAsk" title="borrar">
<input type="button" onclick="sinDeclarar(); location.href = 'otra.asp'" value="Otra">
<input type="button" onclick="var contador = 5; contador++;" value="Local">
<input type="button" onclick="function delManejador() {} delManejador();" value="Funcion">
<input type="button" onclick="ayudaAbierta = false" value="Cerrar ayuda">
<input type="button" onclick="<%= manejador %>" value="Dinamico">
<input type="text" onkeyup="<%= prefijo %>reinitAsk()">
<input type="text" onkeydown="<%= prefijo %> borrar(2)">
<input type="text" onblur="f(&quot;x&quot;); reinitAsk()">
</form>
<a href="javascript:borrar(1)">Borrar</a>
<a href="JavaScript: reinitAsk()">Reiniciar</a>
<a href="<%= url %>javascript:reinitAsk()">Armado</a>
<a href="reinitAsk.asp">Página</a>
<script>
reinitAsk();
</script>
</body>
</html>
