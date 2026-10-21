<%
' Declarado en un include transitivo: explicit.asp -> base.inc -> util.inc
Const MAX_FILAS = 10
Dim gTransitiva
Function Utilidad(a)
  Utilidad = a * MAX_FILAS
End Function
Class Carro
  Private total
  Public Sub Sumar(n)
    total = total + n
  End Sub
End Class
%>
