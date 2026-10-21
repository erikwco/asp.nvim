local M = { globals = {}, count = 0 }

-- Catálogo parcial basado en los estándares públicos del DOM y ECMAScript.
-- Firmas abreviadas para ayuda de edición; no modelan tipos ni sobrecargas.
-- https://dom.spec.whatwg.org/
-- https://html.spec.whatwg.org/multipage/indices.html#interfaces
-- https://tc39.es/ecma262/multipage/global-object.html
-- https://console.spec.whatwg.org/
-- https://drafts.csswg.org/cssom-view/
-- https://fetch.spec.whatwg.org/
-- https://xhr.spec.whatwg.org/
-- https://html.spec.whatwg.org/multipage/webstorage.html
local groups = {
  document = {
    { 'getElementById(id)', 'Busca un elemento por su id; devuelve null si no existe.' },
    { 'getElementsByClassName(names)', 'Colección viva de elementos con las clases indicadas.' },
    { 'getElementsByTagName(name)', 'Colección viva de elementos con ese nombre de etiqueta.' },
    { 'querySelector(selectors)', 'Primer elemento que coincide con el selector CSS, o null.' },
    { 'querySelectorAll(selectors)', 'Lista estática de elementos que coinciden con el selector CSS.' },
    { 'createElement(localName, options)', 'Crea un elemento; options es opcional.' },
    { 'createTextNode(data)', 'Crea un nodo de texto sin interpretar HTML.' },
    { 'createDocumentFragment()', 'Crea un fragmento para agrupar nodos.' },
    { 'addEventListener(type, callback, options)', 'Registra un listener; options es opcional.' },
    { 'removeEventListener(type, callback, options)', 'Quita el listener con el mismo tipo, callback y captura.' },
    { 'dispatchEvent(event)', 'Despacha el evento de forma síncrona.' },
    { 'forms', 'Colección de formularios del documento.' },
    { 'body', 'Elemento body del documento, o null.' },
    { 'head', 'Elemento head del documento, o null.' },
    { 'documentElement', 'Elemento raíz del documento.' },
    { 'title', 'Título del documento; admite lectura y escritura.' },
    { 'cookie', 'Lee las cookies accesibles o escribe una cookie con sus atributos.' },
    { 'readyState', 'Estado de carga: loading, interactive o complete.' },
    { 'location', 'Dirección del documento y operaciones de navegación.' },
    { 'activeElement', 'Elemento que recibe el foco actualmente.' },
  },
  window = {
    { 'alert(message)', 'Muestra un mensaje en un diálogo.' },
    { 'confirm(message)', 'Pide confirmación y devuelve un booleano.' },
    { 'prompt(message, defaultValue)', 'Pide texto; devuelve null al cancelar. Ambos argumentos son opcionales.' },
    { 'setTimeout(fn, ms, ...args)', 'Programa una ejecución y devuelve un identificador; ms y args son opcionales.' },
    { 'setInterval(fn, ms, ...args)', 'Programa ejecuciones periódicas; ms y args son opcionales.' },
    { 'clearTimeout(id)', 'Cancela un temporizador.' },
    { 'clearInterval(id)', 'Cancela un temporizador periódico.' },
    { 'open(url, target, features)', 'Abre una ventana o pestaña; los argumentos son opcionales.' },
    { 'close()', 'Solicita cerrar la ventana; el navegador puede impedirlo.' },
    { 'scrollTo(x, y)', 'Desplaza la ventana a esas coordenadas; también admite un objeto de opciones.' },
    { 'scrollBy(x, y)', 'Desplaza la ventana relativamente; también admite un objeto de opciones.' },
    { 'focus()', 'Solicita el foco para la ventana.' },
    { 'print()', 'Abre el diálogo de impresión.' },
    { 'requestAnimationFrame(callback)', 'Programa un callback antes del próximo repintado.' },
    { 'cancelAnimationFrame(id)', 'Cancela un callback de animación pendiente.' },
    { 'addEventListener(type, callback, options)', 'Registra un listener en la ventana; options es opcional.' },
    { 'removeEventListener(type, callback, options)', 'Quita un listener registrado en la ventana.' },
    { 'innerWidth', 'Ancho interior de la ventana, en píxeles CSS.' },
    { 'innerHeight', 'Alto interior de la ventana, en píxeles CSS.' },
  },
  console = {
    { 'log(...data)', 'Escribe valores en la consola.' },
    { 'error(...data)', 'Escribe un mensaje con nivel de error.' },
    { 'warn(...data)', 'Escribe un mensaje con nivel de advertencia.' },
    { 'table(data, properties)', 'Muestra datos en forma de tabla; properties es opcional.' },
  },
  Math = {
    { 'round(x)', 'Entero más cercano; los empates se resuelven hacia +Infinity.' },
    { 'floor(x)', 'Mayor entero que no supera x.' },
    { 'ceil(x)', 'Menor entero que no es inferior a x.' },
    { 'max(...values)', 'Mayor valor; sin argumentos devuelve -Infinity.' },
    { 'min(...values)', 'Menor valor; sin argumentos devuelve Infinity.' },
    { 'abs(x)', 'Valor absoluto de x.' },
    { 'random()', 'Número pseudoaleatorio entre 0 incluido y 1 excluido; no es criptográfico.' },
    { 'pow(base, exponent)', 'Eleva base a exponent.' },
    { 'sqrt(x)', 'Raíz cuadrada de x.' },
    { 'PI', 'Relación entre la circunferencia y el diámetro.' },
  },
  JSON = {
    { 'parse(text, reviver)', 'Convierte texto JSON en un valor; reviver es opcional.' },
    { 'stringify(value, replacer, space)', 'Serializa un valor a JSON; replacer y space son opcionales.' },
  },
  localStorage = {
    { 'getItem(key)', 'Devuelve el valor almacenado como texto, o null.' },
    { 'setItem(key, value)', 'Guarda el valor como texto; puede fallar por cuota o permisos.' },
    { 'removeItem(key)', 'Elimina la clave indicada.' },
    { 'clear()', 'Elimina todas las claves de este almacenamiento.' },
    { 'length', 'Cantidad de claves almacenadas.' },
  },
  sessionStorage = {
    { 'getItem(key)', 'Devuelve el valor almacenado en esta pestaña como texto, o null.' },
    { 'setItem(key, value)', 'Guarda el valor como texto hasta cerrar la pestaña; puede fallar por cuota.' },
    { 'removeItem(key)', 'Elimina la clave indicada.' },
    { 'clear()', 'Elimina todas las claves de la sesión.' },
    { 'length', 'Cantidad de claves almacenadas.' },
  },
  location = {
    { 'href', 'URL completa; asignarla inicia una navegación.' },
    { 'hash', 'Fragmento con #, o cadena vacía.' },
    { 'search', 'Consulta con ?, o cadena vacía.' },
    { 'pathname', 'Ruta de la URL.' },
    { 'host', 'Nombre de host y puerto, si corresponde.' },
    { 'hostname', 'Nombre de host sin puerto.' },
    { 'protocol', 'Esquema de la URL con los dos puntos.' },
    { 'reload()', 'Recarga la página actual.' },
    { 'replace(url)', 'Navega sustituyendo la entrada actual del historial.' },
    { 'assign(url)', 'Navega a la URL indicada.' },
  },
  navigator = {
    { 'userAgent', 'Identificador del navegador; no es una detección fiable de capacidades.' },
    { 'language', 'Idioma preferido del usuario.' },
    { 'languages', 'Lista de idiomas preferidos.' },
    { 'onLine', 'Indica si el navegador cree tener conexión; no garantiza acceso a Internet.' },
    { 'cookieEnabled', 'Indica si el navegador permite cookies.' },
  },
  history = {
    { 'back()', 'Retrocede una entrada en el historial.' },
    { 'forward()', 'Avanza una entrada en el historial.' },
    { 'go(delta)', 'Avanza o retrocede delta entradas; sin argumento recarga.' },
    { 'pushState(data, unused, url)', 'Añade una entrada del mismo origen sin cargar la página; url es opcional.' },
    { 'replaceState(data, unused, url)', 'Modifica la entrada actual; url es opcional.' },
    { 'length', 'Cantidad de entradas del historial de sesión.' },
  },
  Object = {
    { 'keys(obj)', 'Array con los nombres de las propiedades enumerables propias.' },
    { 'values(obj)', 'Array con los valores de las propiedades enumerables propias.' },
    { 'entries(obj)', 'Array de pares [clave, valor] de las propiedades enumerables propias.' },
    { 'assign(target, ...sources)', 'Copia las propiedades enumerables propias de sources en target y lo devuelve.' },
    { 'freeze(obj)', 'Impide agregar, quitar o cambiar propiedades; no congela los objetos anidados.' },
    { 'create(proto, propertiesObject)', 'Crea un objeto con proto como prototipo; propertiesObject es opcional.' },
    { 'defineProperty(obj, prop, descriptor)', 'Define o modifica una propiedad con su descriptor.' },
    { 'fromEntries(iterable)', 'Crea un objeto desde pares [clave, valor].' },
    { 'getPrototypeOf(obj)', 'Prototipo de obj, o null.' },
  },
  Date = {
    { 'now()', 'Milisegundos transcurridos desde el 1 de enero de 1970 UTC.' },
    { 'parse(dateString)', 'Milisegundos desde 1970 de una fecha en texto, o NaN; solo el formato ISO es portable.' },
    { 'UTC(year, monthIndex, day, hours, minutes, seconds, milliseconds)', 'Milisegundos desde 1970 de una fecha UTC; el mes va de 0 a 11 y todo salvo year es opcional.' },
  },
  String = {
    { 'fromCharCode(...codes)', 'Cadena formada por las unidades UTF-16 indicadas.' },
  },
  Number = {
    { 'isInteger(value)', 'Indica si value es un número entero, sin convertirlo.' },
    { 'isNaN(value)', 'Indica si value es NaN, sin convertirlo como el isNaN global.' },
    { 'isFinite(value)', 'Indica si value es un número finito, sin convertirlo.' },
    { 'parseFloat(string)', 'Igual que el parseFloat global.' },
    { 'parseInt(string, radix)', 'Igual que el parseInt global; conviene indicar radix.' },
    { 'MAX_SAFE_INTEGER', 'Mayor entero seguro: 2^53 - 1; por encima no se distinguen todos los enteros consecutivos.' },
    { 'EPSILON', 'Diferencia entre 1 y el menor número mayor que 1.' },
  },
  Promise = {
    { 'resolve(value)', 'Devuelve una promesa que adopta el estado de value si es una promesa o thenable, incluido su rechazo; con otros valores se cumple con value.' },
    { 'reject(reason)', 'Promesa rechazada con reason.' },
    { 'all(iterable)', 'Se cumple con todos los valores, o se rechaza con el primer rechazo.' },
    { 'allSettled(iterable)', 'Se cumple cuando todas terminan, con el estado y el valor o motivo de cada una.' },
    { 'race(iterable)', 'Termina como la primera promesa que se cumple o se rechaza.' },
    { 'any(iterable)', 'Se cumple con la primera que se cumple; se rechaza con AggregateError si fallan todas.' },
  },
  -- Miembros de las instancias: asp.js_help los ofrece para un binding
  -- declarado como `var x = new XMLHttpRequest()`.
  ['XMLHttpRequest.prototype'] = {
    { 'open(method, url, async, user, password)', 'Inicializa la solicitud; async es true por defecto y los tres últimos son opcionales.' },
    { 'send(body)', 'Envía la solicitud; body es opcional y se ignora en GET y HEAD.' },
    { 'setRequestHeader(name, value)', 'Agrega una cabecera después de open y antes de send.' },
    { 'getResponseHeader(name)', 'Valor de una cabecera de la respuesta, o null.' },
    { 'getAllResponseHeaders()', 'Todas las cabeceras de la respuesta, una por línea con CRLF.' },
    { 'abort()', 'Cancela la solicitud en curso.' },
    { 'overrideMimeType(mime)', 'Fuerza el tipo MIME con que se interpreta la respuesta; antes de send.' },
    { 'readyState', 'Estado: 0 UNSENT, 1 OPENED, 2 HEADERS_RECEIVED, 3 LOADING, 4 DONE.' },
    { 'status', 'Código de estado HTTP; 0 antes de la respuesta o si falló la red.' },
    { 'statusText', 'Texto del estado HTTP.' },
    { 'responseText', 'Cuerpo de la respuesta como texto; requiere responseType vacío o "text".' },
    { 'responseXML', 'Cuerpo de la respuesta como documento XML o HTML, o null.' },
    { 'response', 'Cuerpo de la respuesta según responseType.' },
    { 'responseType', 'Tipo de response: "", "text", "json", "blob", "arraybuffer" o "document".' },
    { 'timeout', 'Milisegundos de espera antes de cancelar; 0 sin límite.' },
    { 'withCredentials', 'Envía cookies y credenciales en solicitudes a otro origen.' },
    { 'onreadystatechange', 'Manejador que se llama cada vez que cambia readyState.' },
    { 'onload', 'Manejador que se llama al completar la solicitud, también con un estado de error HTTP.' },
    { 'onerror', 'Manejador que se llama si falla la red.' },
  },
  Array = {
    { 'isArray(value)', 'Indica si value es un array.' },
    { 'from(items, mapFn, thisArg)', 'Crea un array desde un iterable o un objeto tipo array (arguments, colecciones del DOM); mapFn y thisArg son opcionales.' },
    { 'of(...items)', 'Crea un array con los argumentos como elementos.' },
  },
}

local objects = {
  { 'document', 'Documento HTML de la página.' },
  { 'window', 'Ventana y contexto global del navegador.' },
  { 'console', 'Salida de diagnóstico del navegador.' },
  { 'Math', 'Funciones matemáticas y constantes.' },
  { 'JSON', 'Conversión entre valores JavaScript y texto JSON.' },
  { 'localStorage', 'Almacenamiento persistente por origen.' },
  { 'sessionStorage', 'Almacenamiento por origen que dura mientras la pestaña está abierta.' },
  { 'location', 'URL de la página y navegación.' },
  { 'navigator', 'Información y capacidades del navegador.' },
  { 'history', 'Historial de sesión de la ventana.' },
}
local functions = {
  { 'parseInt(string, radix)', 'Lee un entero; conviene indicar la base radix.' },
  { 'parseFloat(string)', 'Lee un número decimal al comienzo de una cadena.' },
  { 'isNaN(value)', 'Convierte a número e indica si el resultado es NaN.' },
  { 'isFinite(value)', 'Convierte a número e indica si es finito.' },
  { 'encodeURIComponent(component)', 'Codifica un componente de URL en UTF-8 con escapes porcentuales.' },
  { 'decodeURIComponent(component)', 'Decodifica un componente de URL; falla con escapes inválidos.' },
  { 'encodeURI(uri)', 'Codifica una URL completa; conserva los caracteres reservados como / ? & y #.' },
  { 'decodeURI(uri)', 'Decodifica una URL completa sin decodificar los escapes de caracteres reservados.' },
  { 'escape(string)', 'Obsoleta: codifica con %XX y %uXXXX, como Escape de VBScript; para URLs usá encodeURIComponent.' },
  { 'unescape(string)', 'Obsoleta: decodifica %XX y %uXXXX; para URLs usá decodeURIComponent.' },
  { 'eval(x)', 'Evalúa una cadena como código JavaScript; cualquier otro valor lo devuelve tal cual.' },
  { 'fetch(resource, options)', 'Inicia una solicitud HTTP y devuelve una promesa con la respuesta; options es opcional.' },
  { 'String(value)', 'Convierte un valor a cadena.' },
  { 'Number(value)', 'Convierte un valor a número.' },
  { 'Boolean(value)', 'Convierte a booleano: false para 0, "", null, undefined y NaN.' },
  { 'Object(value)', 'Convierte un valor en objeto; sin argumento crea un objeto vacío.' },
  { 'Array(...items)', 'Crea un array; un único argumento numérico indica su longitud.' },
  { 'Date(year, monthIndex, day, hours, minutes, seconds, milliseconds)',
    'Con new crea una fecha: sin argumentos, la actual; con un número, milisegundos desde 1970; con texto, lo interpreta; con año y mes (de 0 a 11), la hora local. Sin new devuelve la fecha actual como texto.' },
  { 'RegExp(pattern, flags)', 'Crea una expresión regular; flags (g, i, m, s, u, y) es opcional.' },
  { 'Error(message, options)', 'Crea un error con su mensaje; options es opcional y puede llevar cause.' },
  { 'Promise(executor)', 'Con new crea una promesa; executor recibe las funciones resolve y reject.' },
  { 'XMLHttpRequest()', 'Con new crea una solicitud HTTP; se configura con open y se envía con send.' },
}

local by_path, members = {}, {}
local function entry(row, object)
  local sig, doc = row[1], row[2]
  local name = sig:match('^[%w_$]+')
  local args = sig:match('%((.*)%)')
  local info = { name = name, detail = (object and object .. '.' or '') .. sig,
    doc = doc, kind = args and (object and 2 or 3) or 10 }
  if args then
    info.signature, info.parameters = info.detail, {}
    local from = #info.signature - #args
    for param in args:gmatch('[^,]+') do
      param = vim.trim(param)
      local s, e = info.signature:find(param, from, true)
      info.parameters[#info.parameters + 1] = { label = { s - 1, e } }
      from = e + 1
    end
  end
  M.count = M.count + 1
  by_path[(object and object .. '.' or '') .. name] = info
  return info
end

for _, row in ipairs(objects) do
  local info = entry(row)
  info.kind = 9
  M.globals[#M.globals + 1] = info
end
for _, row in ipairs(functions) do M.globals[#M.globals + 1] = entry(row) end
for object, rows in pairs(groups) do
  members[object] = {}
  for _, row in ipairs(rows) do
    local info = entry(row, object)
    members[object][#members[object] + 1] = info
    if object == 'window' then
      local global = vim.tbl_extend('force', {}, info, {
        detail = row[1], signature = info.signature and row[1], kind = info.signature and 3 or 10,
      })
      global.parameters = info.signature and {}
      for _, param in ipairs(info.parameters or {}) do
        global.parameters[#global.parameters + 1] = {
          label = { param.label[1] - 7, param.label[2] - 7 },
        }
      end
      M.globals[#M.globals + 1], by_path[info.name] = global, global
    end
  end
end
for _, info in ipairs(M.globals) do
  if not by_path['window.' .. info.name] then
    members.window[#members.window + 1] = info
    by_path['window.' .. info.name] = info
  end
end

local function object_path(path)
  if path == 'document.location' or path == 'window.location' then return 'location' end
  return path:match('^window%.([%w_$]+)$') or path
end

function M.members(path)
  return members[object_path(path)]
end

function M.lookup(path)
  if by_path[path] then return by_path[path] end
  local object, name = path:match('^(.*)%.([%w_$]+)$')
  return object and by_path[object_path(object) .. '.' .. name] or nil
end

return M
