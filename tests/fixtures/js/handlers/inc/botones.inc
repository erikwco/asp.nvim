<%
' Sin <script>: sólo manejadores que llaman a funciones de la página.
Dim activo
activo = True
%>
<button type="button" onclick="reinitAsk()">Reiniciar</button>
<button type="button" onclick="enviarFormulario(this.form)">Enviar</button>
