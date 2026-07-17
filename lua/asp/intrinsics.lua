local M = {}

-- Datos de los objetos intrínsecos de Classic ASP. Firmas y descripciones
-- basadas en la documentación pública de ASP (dominio de conocimiento común).
local DATA = {
  Response = {
    doc = 'Envía la salida al cliente (cabeceras, cuerpo, cookies).',
    members = {
      { 'Write', 'Response.Write(variant)', 'Escribe una cadena en la respuesta HTTP.' },
      { 'Redirect', 'Response.Redirect(url)', 'Redirige al cliente a otra URL.' },
      { 'End', 'Response.End()', 'Detiene el procesamiento y envía lo ya bufferizado.' },
      { 'Clear', 'Response.Clear()', 'Borra el buffer de respuesta (sin cabeceras).' },
      { 'Flush', 'Response.Flush()', 'Envía el buffer actual inmediatamente.' },
      { 'Buffer', 'Response.Buffer [= bool]', 'Controla si la respuesta se bufferiza.' },
      { 'ContentType', 'Response.ContentType [= string]', 'Tipo MIME de la respuesta.' },
      { 'Expires', 'Response.Expires [= minutos]', 'Minutos hasta que la página caduque en caché.' },
      { 'ExpiresAbsolute', 'Response.ExpiresAbsolute [= fecha]', 'Fecha/hora absoluta de caducidad.' },
      { 'AddHeader', 'Response.AddHeader(nombre, valor)', 'Agrega una cabecera HTTP.' },
      { 'Cookies', 'Response.Cookies(nombre)', 'Colección de cookies de salida.' },
      { 'Status', 'Response.Status [= string]', 'Línea de estado HTTP (ej. "404 Not Found").' },
      { 'CacheControl', 'Response.CacheControl [= string]', 'Cabecera Cache-Control.' },
      { 'BinaryWrite', 'Response.BinaryWrite(datos)', 'Escribe datos binarios sin conversión.' },
    },
  },
  Request = {
    doc = 'Accede a los datos enviados por el cliente en la petición HTTP.',
    members = {
      { 'QueryString', 'Request.QueryString(clave)', 'Valores de la cadena de consulta (GET).' },
      { 'Form', 'Request.Form(clave)', 'Valores enviados por POST.' },
      { 'ServerVariables', 'Request.ServerVariables(nombre)', 'Variables de servidor/entorno.' },
      { 'Cookies', 'Request.Cookies(nombre)', 'Cookies enviadas por el cliente.' },
      { 'TotalBytes', 'Request.TotalBytes', 'Bytes totales del cuerpo de la petición.' },
      { 'BinaryRead', 'Request.BinaryRead(cuenta)', 'Lee datos binarios del cuerpo POST.' },
      { 'ClientCertificate', 'Request.ClientCertificate(clave)', 'Campos del certificado de cliente.' },
    },
  },
  Server = {
    doc = 'Utilidades del servidor: creación de objetos, rutas y codificación.',
    members = {
      { 'CreateObject', 'Server.CreateObject(progID)', 'Instancia un componente COM por su ProgID.' },
      { 'MapPath', 'Server.MapPath(ruta)', 'Convierte una ruta virtual en física.' },
      { 'HTMLEncode', 'Server.HTMLEncode(string)', 'Escapa caracteres HTML.' },
      { 'URLEncode', 'Server.URLEncode(string)', 'Codifica una cadena para URL.' },
      { 'Execute', 'Server.Execute(ruta)', 'Ejecuta otra página ASP y vuelve.' },
      { 'Transfer', 'Server.Transfer(ruta)', 'Transfiere la ejecución a otra página.' },
      { 'ScriptTimeout', 'Server.ScriptTimeout [= segundos]', 'Tiempo máximo de ejecución del script.' },
      { 'GetLastError', 'Server.GetLastError()', 'Devuelve el objeto ASPError del último error.' },
    },
  },
  Session = {
    doc = 'Estado por usuario, persistente entre peticiones de una sesión.',
    members = {
      { 'SessionID', 'Session.SessionID', 'Identificador único de la sesión.' },
      { 'Timeout', 'Session.Timeout [= minutos]', 'Minutos de inactividad antes de expirar.' },
      { 'Abandon', 'Session.Abandon()', 'Destruye la sesión al terminar la petición.' },
      { 'Contents', 'Session.Contents(clave)', 'Colección de variables de sesión.' },
      { 'StaticObjects', 'Session.StaticObjects(clave)', 'Objetos declarados con <object> scope=session.' },
      { 'CodePage', 'Session.CodePage [= entero]', 'Página de códigos para la sesión.' },
      { 'LCID', 'Session.LCID [= entero]', 'Identificador de configuración regional.' },
    },
  },
  Application = {
    doc = 'Estado compartido por todos los usuarios de la aplicación.',
    members = {
      { 'Contents', 'Application.Contents(clave)', 'Colección de variables de aplicación.' },
      { 'StaticObjects', 'Application.StaticObjects(clave)', 'Objetos <object> scope=application.' },
      { 'Lock', 'Application.Lock()', 'Bloquea el objeto Application para escritura segura.' },
      { 'Unlock', 'Application.Unlock()', 'Libera el bloqueo de Application.' },
    },
  },
}

-- Índice interno normalizado: lowercase → objeto con members indexados.
local index = {}
for name, obj in pairs(DATA) do
  local members_by_key = {}
  local members_list = {}
  for _, m in ipairs(obj.members) do
    local entry = { name = m[1], signature = m[2], doc = m[3] }
    members_by_key[m[1]:lower()] = entry
    table.insert(members_list, entry)
  end
  index[name:lower()] = {
    name = name, doc = obj.doc,
    members = members_by_key, members_list = members_list,
  }
end

---@param name string
---@return table|nil
function M.object(name)
  if type(name) ~= 'string' then return nil end
  return index[name:lower()]
end

---@param obj_name string
---@param member_name string
---@return table|nil
function M.member(obj_name, member_name)
  local obj = M.object(obj_name)
  if not obj or type(member_name) ~= 'string' then return nil end
  return obj.members[member_name:lower()]
end

---@return string[]
function M.object_names()
  local out = {}
  for _, obj in pairs(index) do table.insert(out, obj.name) end
  return out
end

---@param obj_name string
---@return table[]
function M.members_of(obj_name)
  local obj = M.object(obj_name)
  return obj and obj.members_list or {}
end

return M
