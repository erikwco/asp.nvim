<%@ Language="VBScript" %>
<!--#include file="includes/helpers.asp" -->
<!--#include virtual="/lib/db.inc" -->
<!--#include file="lib/log.inc" -->
<%
Dim cn
Set cn = AbrirConexion()
RespuestaRapida

' Parámetro homónimo de la función de helpers.asp: es otra variable.
Function Resumen(FormatearMoneda)
  Resumen = FormatearMoneda
End Function

' Local homónimo de la función de db.inc: tampoco es la misma.
Sub Detalle()
  Dim AbrirConexion
  AbrirConexion = "local"
End Sub
%>
