<%
Dim menuActivo
menuActivo = "inicio"
%>
<script src="lib/menu.js"></script>
<script>
var menu = "<%= menuActivo %>";
function desdeInclude() {
  desdeSrc();
  return menu;
}

function duplicada() { return 'include'; }
</script>
