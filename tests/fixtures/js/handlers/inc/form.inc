<%
' Formulario compartido: declara su función de envío.
%>
<script>
function enviarFormulario(f) {
  return validarCampo(f.campo);
}
</script>
<button type="button" onclick="enviarFormulario(document.forms[0])">Enviar</button>
