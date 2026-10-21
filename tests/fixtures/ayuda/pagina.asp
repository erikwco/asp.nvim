<!--#include file="intermedio.inc" -->
<%
Dim conn, rs, filas, fso, texto, rx, coincidencias
Set conn = Server.CreateObject("ADODB.Connection")
Set rs = Server.CreateObject("ADODB.Recordset")
Set filas = conn.Execute("select 1")
Set fso = CreateObject("Scripting.FileSystemObject")
Set texto = fso.OpenTextFile("ejemplo.txt")
Set rx = New RegExp
Set coincidencias = rx.Execute("abc")
Response.Write Len("abc") & vbCrLf
Response.Write rs.EOF
Response.Write filas.EOF
Response.Write texto.ReadAll()
Response.Write FuncionIncluida(1, 2)
Sub MiSub(ByVal a, ByRef b)
  Response.Write a & b
End Sub
Function Locales()
  Dim rs
  Set rs = CreateObject("Scripting.Dictionary")
  Response.Write rs.Exists("clave")
End Function
%>
