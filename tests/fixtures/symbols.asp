<%@ Language="VBScript" %>
<html><body>
<%
Option Explicit
Dim total, nombre
Const IVA = 12

Class Pedido
  Private m_total
  Public Sub Agregar(monto)
    m_total = m_total + monto
  End Sub
  Public Property Let Total(nuevoTotal)
    m_total = nuevoTotal
  End Property
End Class

Function CalcularTotal(base)
  Dim recargo
  recargo = base * IVA
  CalcularTotal = base + recargo
End Function

Sub Mostrar()
  Response.Write CalcularTotal(total)
End Sub

nombre = "cliente"
mostrar
%>
</body></html>
