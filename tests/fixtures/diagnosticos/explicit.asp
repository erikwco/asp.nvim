<%@ Language="VBScript" %>
<%
Option Explicit
%>
<!--#include virtual="/inc/base.inc" -->
<%
Dim arr(10), obj, i, k, c, re, salida
total = 5
NoExiste 1, 2
salida = Inexistente(3)
Call Fantasma()
Set c = New NoClase
gTransitiva = Utilidad(MAX_FILAS) & FormatoBase(gBase)
arr(1) = Len("abc") & vbCrLf
salida = arr(2)
Set obj = Server.CreateObject("Scripting.Dictionary")
obj.Prop.Metodo "x", salida
Response.Write obj.Item("a")
If Err.Number <> 0 Then Err.Clear
For i = 1 To MAX_FILAS
  salida = salida & i
Next
For Each k In obj.Keys
  Response.Write k
Next
Set c = New Carro
c.Sumar 1
Set re = New RegExp
MiSub salida, i
Rem nada de esto es código: sinDeclarar NoExisteTampoco

Sub MiSub(primero, segundo)
  Dim local
  Const SEPARADOR = "-"
  ReDim partes(2)
  partes(0) = primero
  local = partes(0) & SEPARADOR & segundo
End Sub

Class Cuenta
  Private saldo
  Public Function Depositar(monto)
    saldo = saldo + monto
    Me.Registrar monto
    Depositar = saldo
  End Function
  Private Sub Registrar(monto)
    Response.Write monto
  End Sub
End Class
%>
<p><%= salida %></p>
<td><%= salida %></td><td><%= i %></td>
