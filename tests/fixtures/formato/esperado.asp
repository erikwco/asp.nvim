<%@ Language=VBScript %>
<!--#include file="comun.asp"-->
<%
Option Explicit
Dim total, i, item
' comentario de página
Rem otro comentario de página

Class Carrito
    Private items

    Public Property Get Cantidad()
        Cantidad = items
    End Property

    Public Sub Agregar(x)
        items = items + x
    End Sub
End Class

Function Sumar(a, b)
    If a > 0 Then
        Sumar = a + b
    ElseIf a = 0 Then
        Sumar = b
    Else
        Sumar = 0
    End If
End Function

Sub Recorrer(lista)
    For i = 1 To 10
        If i = 5 Then Exit For
        total = total + i
    Next
    For Each item In lista
        Response.Write item
    Next
    Do While total > 0
        total = total - 1
    Loop
    Do
        total = total + 1
    Loop Until total > 3
    While i < 20
        i = i + 1
    Wend
    If total = 0 Then total = 1
    If total > 1 Then ' comentario tras Then
        total = 2
    End If
    Select Case total
        Case 1
            Response.Write "uno"
            ' comentario en la rama
        Case 2, 3
            Response.Write "dos o tres"
        Case Else
            Response.Write "otro"
    End Select
    With Response
        .Write "hola"
    End With
    total = Sumar(1, _
        2)
End Sub
%>
<html>
    <body>
        <table>
            <tr>
                <td><%= total %></td>
            </tr>
        </table>
        <% If total > 0 Then %>
            <p>positivo</p>
            <ul>
                <% For Each item In lista %>
                    <li><%= item %></li>
                <% Next %>
            </ul>
        <% Else %>
            <p>cero</p>
        <% End If %>
        <% total = 0 %>
        <%
        For i = 1 To 3
        %>
            <p><%= i %></p>
        <%
        Next
        %>
        <script>
            function hola() {
                return 1;
            }
        </script>
    </body>
</html>
