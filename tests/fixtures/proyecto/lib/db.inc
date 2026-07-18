<%
Function AbrirConexion()
  Set AbrirConexion = Server.CreateObject("ADODB.Connection")
End Function


Class Repositorio
  Private m_conn
  Public Sub Init(conexion)
    Set m_conn = conexion
  End Sub
End Class
%>
