<%
Dim total
total = 0
Class Carrito
  Private total
  Public Sub Agregar(monto)
    total = total + monto
  End Sub
  Public Function Valor()
    Valor = Me.total
  End Function
End Class
Set c = New Carrito
c.Agregar 5
total = c.Valor()
%>
