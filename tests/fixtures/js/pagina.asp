<%@ Language="VBScript" %>
<%
Dim saludo
saludo = "hola"

Function Duplicar(n)
  Duplicar = n * 2
End Function
%>
<html>
<head>
<script type="text/javascript">
var contador = 0;
const LIMITE = 10;
let pendiente = true;

function inicializar(opciones) {
  var contador = opciones.inicio;
  return contador + LIMITE;
}
</script>
<script runat="server" language="JScript">
function soloServidor() { return 1; }
</script>
<script type="text/template">
function enPlantilla() { return 1; }
</script>
<script language="VBScript">
Sub BotonCliente_OnClick()
End Sub
</script>
</head>
<body>
<p><%= Duplicar(saludo) %></p>
<script>
class Carrito {
  agregar(item) {
    var total = item;
    return total;
  }
}

var carrito = new Carrito();
carrito.agregar(contador);
inicializar({ inicio: LIMITE });
soloServidor();
enPlantilla();

var calcular = function factorial(k) {
  return k <= 1 ? 1 : k * factorial(k - 1);
};
var fuera = typeof factorial;

function cola() {
  var cola = [];
  return cola;
}
var total = calcular(contador);
var duplicados = [1, 2].map(x => x * 2);
</script>
<script>
var url = "<%= saludo %>";
var veces = <%= Duplicar(2) %>;
var <%= saludo %> = 0;
function usarUrl() {
  return url + veces + pendiente;
}
</script>
</body>
</html>
