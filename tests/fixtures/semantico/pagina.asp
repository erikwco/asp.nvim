<!--#include file="lib.inc"-->
<%
Option Explicit
Const MAX = 10
Dim total, c
Function Sumar(a, b)
  Dim max
  max = a
  Sumar = a + b + MAX
End Function
Class Caja
  Private m_total
  Public Sub Agregar(x)
    m_total = m_total + x
    Me.m_total = Len("Sumar")
  End Sub
End Class
Set c = New Caja
total = Sumar(1, MAX) + Redondear(total)
Response.Write "ñandú " & total & vbCrLf
%>
<p>total: <%=total%><%=MAX%></p>
<script>
function saludar(nombre) { var x = nombre; return x; }
class Punto { mover(dx) { return dx; } }
saludar("total");
</script>
