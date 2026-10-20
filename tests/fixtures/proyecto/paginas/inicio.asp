<% Response.Redirect "otra.asp" %>
<a href="otra.asp">Otra página</a>
<form action="otra.asp?id=1#detalle"></form>
<a href="/includes/helpers.asp">Helpers</a>
<script>
  const pagina = 'otra.asp';
  const recurso = "lib/app.js";
</script>
<% Response.Redirect "otra.asp?id=" & id %>
<a href="http://example.com/otra.asp">Externo</a>
<a href="inexistente.asp">Ausente</a>
<td><%= "otra.asp" %></td><td><%= "lib/app.js" %></td>
