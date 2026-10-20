<%@ Language="VBScript" %>
<!--#include file="inc/menu.inc" -->
<!--#include virtual="/inc/pie.asp" -->
<html>
<head>
<script src="js/app.js"></script>
<script src="https://cdn.example.com/jquery.min.js"></script>
<script src="//cdn.example.com/otra.js"></script>
<script src="js/no_existe.js"></script>
<script src="<%= base %>/js/app.js"></script>
<script runat="server" src="js/servidor.js"></script>
<script type="text/javascript" src="/js/virtual.js?v=3"></script>
</head>
<body>
<script>
desdeSrc();
desdeInclude();
desdeMenuJs();
duplicada();
desdeVirtual();
desdePie();
soloServidor();
jQuery();
function usarLocal() {
  var desdeSrc = 1;
  return desdeSrc;
}
var deLaPagina = 1;
mostrar(deLaPagina);
</script>
</body>
</html>
