<!--#include file="funciones.inc"-->
<script src="util.js"></script>
<% Dim total
total = Len("asp")
Response.Write total
%>
<h1>buscarGlobal</h1>
<script>
function buscarGlobal(primero, segundo = 2, ...resto) { return primero; }
class Vista {
  pintar(color = 'azul') { return color; }
}
const flecha = (valor, extra = 1) => valor + extra;
let expresion = function(nombre) { return nombre; };
function contenedora(parametro) {
  let total = 5;
  function buscarLocal(dato) { return dato + total; }
  // consulta local
  return total;
}
function ajena() {
  function buscarOculta() {}
  let soloAjena = 0;
}
// consulta global
</script>
<button onclick="buscarGlobal(1, 2)">Buscar</button>
<a href="javascript:buscarGlobal(2)">Enlace</a>
<script>
buscarGlobal(1, 2);
buscarExterna(1);
buscarIncluida('a');
document.getElementById('resultado');
const texto = "buscarGlobal";
// buscarGlobal en comentario
</script>
<script runat="server">buscarGlobal();</script>
<script type="text/template">buscarGlobal();</script>
