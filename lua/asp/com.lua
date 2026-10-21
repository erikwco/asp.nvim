local M = {}

-- Catálogo parcial basado en la documentación pública de Microsoft:
-- ADO: https://learn.microsoft.com/office/client-developer/access/desktop-database-reference/ado-api-reference
-- Scripting: https://learn.microsoft.com/previous-versions/d1wf56tt(v=vs.85)
-- MSXML: https://learn.microsoft.com/previous-versions/windows/desktop/ms763742(v=vs.85)
-- CDO: https://learn.microsoft.com/previous-versions/exchange-server/exchange-10/ms526318(v=exchg.10)
-- No enumera todos los miembros, interfaces ni componentes COM disponibles.
local function method(signature, doc, returns)
  return { name = signature:match('^[%w_]+'), signature = signature,
    doc = doc, kind = 'method', returns = returns }
end

local function property(signature, doc, returns)
  local entry = method(signature, doc, returns)
  entry.kind = 'property'
  return entry
end

M.types = {
  Connection = {
    progids = { 'ADODB.Connection' },
    doc = 'Conexión ADO a un origen de datos; ejecuta consultas y administra transacciones.',
    members = {
      method('Open([ConnectionString[, UserID[, Password[, Options]]]])', 'Abre la conexión al origen de datos.'),
      method('Close()', 'Cierra la conexión y sus recursos asociados.'),
      method('Execute(CommandText[, RecordsAffected[, Options]])', 'Ejecuta SQL o un comando; devuelve los registros si los hay.', 'Recordset'),
      method('BeginTrans()', 'Inicia una transacción y devuelve el nivel de anidamiento.', 'Long'),
      method('CommitTrans()', 'Confirma la transacción actual.'),
      method('RollbackTrans()', 'Revierte la transacción actual.'),
      property('ConnectionString', 'Cadena con proveedor y parámetros de conexión.'),
      property('State', 'Estado de la conexión, como adStateClosed o adStateOpen.'),
      property('CommandTimeout', 'Segundos de espera para ejecutar un comando.'),
      property('ConnectionTimeout', 'Segundos de espera para abrir la conexión.'),
      property('Provider', 'Nombre del proveedor OLE DB.'),
    },
  },
  Recordset = {
    progids = { 'ADODB.Recordset' },
    doc = 'Conjunto de registros ADO con cursor, campos y operaciones de actualización.',
    members = {
      method('Open([Source[, ActiveConnection[, CursorType[, LockType[, Options]]]]])', 'Abre un cursor sobre una consulta, tabla o comando.'),
      method('Close()', 'Cierra el conjunto de registros.'),
      method('MoveNext()', 'Avanza al siguiente registro.'),
      method('MovePrevious()', 'Retrocede al registro anterior.'),
      method('MoveFirst()', 'Sitúa el cursor en el primer registro.'),
      method('MoveLast()', 'Sitúa el cursor en el último registro.'),
      method('Move(NumRecords[, Start])', 'Desplaza el cursor una cantidad de registros.'),
      method('AddNew([FieldList[, Values]])', 'Crea un registro nuevo.'),
      method('Update([Fields[, Values]])', 'Guarda los cambios del registro actual.'),
      method('Delete([AffectRecords])', 'Elimina el registro actual o un grupo de registros.'),
      method('GetRows([Rows[, Start[, Fields]]])', 'Copia registros a un array de dos dimensiones.', 'Variant()'),
      method('Requery([Options])', 'Vuelve a ejecutar la consulta del cursor.'),
      method('NextRecordset([RecordsAffected])', 'Avanza al siguiente resultado de un comando.', 'Recordset'),
      method('Find(Criteria[, SkipRows[, SearchDirection[, Start]]])', 'Busca desde el registro actual el primero que cumple un criterio de una sola columna, como "nombre = \'Ana\'"; si no lo encuentra, queda en EOF, o en BOF al buscar hacia atrás.'),
      method('Supports(CursorOptions)', 'Indica si el cursor admite una funcionalidad, como adAddNew, adBookmark o adFind.', 'Boolean'),
      method('CancelUpdate()', 'Descarta los cambios del registro actual o el registro nuevo de AddNew, antes de llamar a Update.'),
      method('UpdateBatch([AffectRecords])', 'Guarda en el origen los cambios pendientes de una actualización por lotes.'),
      method('CancelBatch([AffectRecords])', 'Descarta los cambios pendientes de una actualización por lotes.'),
      property('EOF', 'True si el cursor está después del último registro o el conjunto está vacío.'),
      property('BOF', 'True si el cursor está antes del primer registro o el conjunto está vacío.'),
      property('Fields', 'Colección de campos del registro actual; usa Fields.Item(nombre).', 'Fields'),
      property('State', 'Estado del conjunto de registros.'),
      property('RecordCount', 'Cantidad de registros; vale -1 si el cursor no la conoce, como el adOpenForwardOnly por defecto.'),
      property('ActiveConnection', 'Conexión asociada al conjunto de registros.', 'Connection'),
      property('CursorType', 'Tipo de cursor: adOpenForwardOnly (0, por defecto), adOpenKeyset (1), adOpenDynamic (2) o adOpenStatic (3); se fija antes de Open.'),
      property('LockType', 'Bloqueo al editar: adLockReadOnly (1, por defecto), adLockPessimistic (2), adLockOptimistic (3) o adLockBatchOptimistic (4); se fija antes de Open.'),
      property('CursorLocation', 'Dónde vive el cursor: adUseServer (2, por defecto) o adUseClient (3); el de cliente conoce RecordCount y admite paginar.'),
      property('PageSize', 'Cantidad de registros por página; 10 por defecto.'),
      property('AbsolutePage', 'Página del registro actual, desde 1; al asignarla mueve el cursor al primer registro de esa página. Puede valer adPosUnknown (-1), adPosBOF (-2) o adPosEOF (-3).'),
      property('PageCount', 'Cantidad de páginas según PageSize; -1 si el proveedor no la conoce.'),
      property('AbsolutePosition', 'Posición del registro actual, desde 1; al asignarla mueve el cursor. Puede valer adPosUnknown (-1), adPosBOF (-2) o adPosEOF (-3).'),
      property('Bookmark', 'Marca del registro actual; asignarla vuelve a ese registro si el cursor lo admite.'),
      property('MaxRecords', 'Máximo de registros que devuelve la consulta; 0 sin límite. Se fija antes de Open.'),
      property('Filter', 'Filtro aplicado al conjunto de registros.'),
      property('Sort', 'Campos y orden de clasificación.'),
    },
  },
  Fields = {
    doc = 'Colección de campos ADO, accesibles por nombre o índice basado en cero.',
    members = {
      property('Count', 'Cantidad de campos.'),
      property('Item(Index)', 'Obtiene un campo por nombre o índice.', 'Field'),
      method('Append(Name, Type[, DefinedSize[, Attrib[, FieldValue]]])', 'Agrega una definición de campo.'),
      method('Refresh()', 'Actualiza los metadatos de la colección.'),
      method('Update()', 'Guarda cambios de la colección cuando el proveedor lo admite.'),
    },
  },
  Field = {
    doc = 'Campo ADO con valor, nombre y metadatos de tipo.',
    members = {
      property('Value', 'Valor del campo; puede ser Null.'),
      property('Name', 'Nombre del campo.'),
      property('Type', 'Tipo ADO del campo.'),
      property('DefinedSize', 'Tamaño máximo declarado del campo.'),
      property('ActualSize', 'Tamaño real del valor del campo.'),
    },
  },
  Command = {
    progids = { 'ADODB.Command' },
    doc = 'Comando ADO parametrizado, SQL o procedimiento almacenado.',
    members = {
      method('Execute([RecordsAffected[, Parameters[, Options]]])', 'Ejecuta el comando y devuelve sus registros.', 'Recordset'),
      method('CreateParameter([Name[, Type[, Direction[, Size[, Value]]]]])', 'Crea un parámetro; debe agregarse luego a Parameters.', 'Parameter'),
      property('CommandText', 'SQL, nombre de tabla o procedimiento que se ejecutará.'),
      property('CommandType', 'Tipo del comando, por ejemplo adCmdText o adCmdStoredProc.'),
      property('ActiveConnection', 'Conexión utilizada al ejecutar el comando.', 'Connection'),
      property('Parameters', 'Colección de parámetros del comando.', 'Parameters'),
      property('CommandTimeout', 'Segundos de espera al ejecutar el comando.'),
      property('Prepared', 'Indica si el proveedor debe preparar el comando.'),
      property('State', 'Estado de ejecución del comando.'),
    },
  },
  Parameters = {
    doc = 'Parámetros de un comando ADO, accesibles por nombre o índice.',
    members = {
      method('Append(Object)', 'Agrega un Parameter creado con CreateParameter.'),
      method('Delete(Index)', 'Elimina un parámetro por nombre o índice.'),
      method('Refresh()', 'Consulta los parámetros al proveedor.'),
      property('Count', 'Cantidad de parámetros.'),
      property('Item(Index)', 'Obtiene un parámetro por nombre o índice.', 'Parameter'),
    },
  },
  Parameter = {
    doc = 'Parámetro ADO con tipo, dirección, tamaño y valor.',
    members = {
      property('Name', 'Nombre del parámetro.'),
      property('Value', 'Valor de entrada o salida.'),
      property('Type', 'Tipo ADO del valor.'),
      property('Direction', 'Dirección: entrada, salida o valor de retorno.'),
      property('Size', 'Tamaño máximo del valor.'),
    },
  },
  Stream = {
    progids = { 'ADODB.Stream' },
    doc = 'Secuencia ADO de bytes o texto, con posición y codificación.',
    members = {
      method('Open([Source[, Mode[, OpenOptions[, UserName[, Password]]]]])', 'Abre la secuencia.'),
      method('Close()', 'Cierra la secuencia.'),
      method('Read([NumBytes])', 'Lee bytes de una secuencia binaria.', 'Byte()'),
      method('ReadText([NumChars])', 'Lee caracteres de una secuencia de texto.', 'String'),
      method('Write(Buffer)', 'Escribe bytes en una secuencia binaria.'),
      method('WriteText(Data[, Options])', 'Escribe texto y, opcionalmente, un separador de línea.'),
      method('LoadFromFile(FileName)', 'Reemplaza el contenido de la secuencia abierta por el del archivo y deja Position en 0.'),
      method('SaveToFile(FileName[, SaveOptions])', 'Guarda la secuencia en un archivo; adSaveCreateOverWrite (2) reemplaza uno existente.'),
      method('CopyTo(DestStream[, NumChars])', 'Copia bytes o caracteres desde la posición actual a otra secuencia abierta; sin NumChars, hasta el final.'),
      method('SetEOS()', 'Fija el final de la secuencia en la posición actual y descarta lo que sigue.'),
      method('SkipLine()', 'Avanza hasta después del próximo separador de línea de una secuencia de texto.'),
      method('Flush()', 'Envía al objeto subyacente el contenido que quedó en el búfer.'),
      property('Type', 'adTypeBinary (1) o adTypeText (2, por defecto); se cambia con Position en 0.'),
      property('Charset', 'Juego de caracteres de la secuencia de texto, como "utf-8" o "iso-8859-1"; "Unicode" por defecto.'),
      property('Position', 'Posición actual en bytes, basada en cero.'),
      property('Size', 'Tamaño de la secuencia en bytes; -1 si no se conoce.'),
      property('LineSeparator', 'Separador de línea de las secuencias de texto: adCRLF (-1, por defecto), adLF (10) o adCR (13).'),
      property('Mode', 'Permisos de acceso, como adModeRead (1), adModeWrite (2) o adModeReadWrite (3); se fija antes de Open.'),
      property('EOS', 'True si se alcanzó el final de la secuencia.'),
      property('State', 'Estado abierto o cerrado de la secuencia.'),
    },
  },
  FileSystemObject = {
    progids = { 'Scripting.FileSystemObject' },
    doc = 'Acceso a archivos, carpetas y unidades del sistema de archivos del servidor.',
    members = {
      method('OpenTextFile(filename[, iomode[, create[, format]]])', 'Abre texto para lectura (1), escritura (2) o anexado (8).', 'TextStream'),
      method('CreateTextFile(filename[, overwrite[, unicode]])', 'Crea un archivo de texto y lo abre para escritura.', 'TextStream'),
      method('FileExists(filespec)', 'Indica si existe un archivo.', 'Boolean'),
      method('FolderExists(folderspec)', 'Indica si existe una carpeta.', 'Boolean'),
      method('DeleteFile(filespec[, force])', 'Elimina archivos; force permite eliminar archivos de solo lectura.'),
      method('DeleteFolder(folderspec[, force])', 'Elimina carpetas y su contenido.'),
      method('CopyFile(source, destination[, overwrite])', 'Copia uno o varios archivos; source admite comodines en el último componente y overwrite es True por defecto.'),
      method('MoveFile(source, destination)', 'Mueve uno o varios archivos; un destino terminado en \\ es una carpeta existente y, si no, el nombre nuevo, que no debe existir.'),
      method('CopyFolder(source, destination[, overwrite])', 'Copia carpetas con su contenido; source admite comodines en el último componente y overwrite es True por defecto.'),
      method('MoveFolder(source, destination)', 'Mueve carpetas con su contenido; un destino terminado en \\ es una carpeta existente y, si no, el nombre nuevo, que no debe existir.'),
      method('GetFile(filespec)', 'Obtiene un archivo existente.', 'File'),
      method('GetFolder(folderspec)', 'Obtiene una carpeta existente.', 'Folder'),
      method('GetDrive(drivespec)', 'Obtiene una unidad.', 'Drive'),
      method('CreateFolder(foldername)', 'Crea una carpeta.', 'Folder'),
      method('BuildPath(path, name)', 'Une una ruta y un nombre, agregando el separador si hace falta; no comprueba que exista.', 'String'),
      method('GetAbsolutePathName(pathspec)', 'Ruta completa y sin ambigüedades de pathspec, relativa a la carpeta actual.', 'String'),
      method('GetExtensionName(path)', 'Extensión del último componente sin el punto, o cadena vacía.', 'String'),
      method('GetFileName(pathspec)', 'Último componente de la ruta; no comprueba que exista.', 'String'),
      method('GetBaseName(path)', 'Último componente de la ruta sin su extensión; no comprueba que exista.', 'String'),
      method('GetParentFolderName(path)', 'Ruta de la carpeta que contiene el último componente; no comprueba que exista.', 'String'),
      method('GetDriveName(path)', 'Unidad de la ruta, como "C:" o el recurso compartido UNC.', 'String'),
      method('GetTempName()', 'Nombre aleatorio para un archivo o carpeta temporal; no crea nada.', 'String'),
      method('GetSpecialFolder(folderspec)', 'Carpeta especial: WindowsFolder (0), SystemFolder (1) o TemporaryFolder (2).', 'Folder'),
      method('DriveExists(drivespec)', 'Indica si existe la unidad; en unidades extraíbles no comprueba si hay medio.', 'Boolean'),
      property('Drives', 'Colección de unidades disponibles.', 'Drives'),
    },
  },
  TextStream = {
    doc = 'Archivo de texto abierto por FileSystemObject para lectura o escritura.',
    members = {
      method('Read(characters)', 'Lee la cantidad indicada de caracteres.', 'String'),
      method('ReadAll()', 'Lee todo el texto restante.', 'String'),
      method('ReadLine()', 'Lee una línea sin el salto de línea.', 'String'),
      method('Write(string)', 'Escribe texto sin agregar un salto de línea.'),
      method('WriteLine([string])', 'Escribe texto seguido de un salto de línea.'),
      method('WriteBlankLines(lines)', 'Escribe la cantidad indicada de líneas vacías.'),
      method('Skip(characters)', 'Omite caracteres durante la lectura.'),
      method('SkipLine()', 'Omite la siguiente línea.'),
      method('Close()', 'Cierra el archivo de texto.'),
      property('AtEndOfStream', 'True cuando no queda texto por leer.'),
      property('AtEndOfLine', 'True cuando el cursor está al final de una línea.'),
      property('Line', 'Número de línea actual, desde 1.'),
      property('Column', 'Número de columna actual, desde 1.'),
    },
  },
  Folder = {
    doc = 'Carpeta del sistema de archivos, con archivos y subcarpetas.',
    members = {
      property('Name', 'Nombre de la carpeta.'),
      property('Path', 'Ruta de la carpeta.'),
      property('Files', 'Archivos de la carpeta.', 'Files'),
      property('SubFolders', 'Subcarpetas inmediatas.', 'Folders'),
      property('ParentFolder', 'Carpeta contenedora.', 'Folder'),
      property('Drive', 'Unidad que contiene la carpeta.', 'Drive'),
      property('Size', 'Tamaño total de archivos y subcarpetas en bytes.'),
      method('CreateTextFile(filename[, overwrite[, unicode]])', 'Crea un archivo de texto en la carpeta.', 'TextStream'),
      method('Delete([force])', 'Elimina la carpeta y su contenido.'),
      method('Copy(destination[, overwrite])', 'Copia la carpeta.'),
      method('Move(destination)', 'Mueve la carpeta.'),
    },
  },
  File = {
    doc = 'Archivo del sistema de archivos, con ruta, tamaño y atributos.',
    members = {
      property('Name', 'Nombre del archivo.'),
      property('Path', 'Ruta del archivo.'),
      property('Size', 'Tamaño en bytes.'),
      property('DateLastModified', 'Fecha de la última modificación.'),
      property('Attributes', 'Máscara de atributos del archivo.'),
      property('ParentFolder', 'Carpeta contenedora.', 'Folder'),
      property('Drive', 'Unidad que contiene el archivo.', 'Drive'),
      method('OpenAsTextStream([iomode[, format]])', 'Abre el archivo como texto.', 'TextStream'),
      method('Delete([force])', 'Elimina el archivo.'),
      method('Copy(destination[, overwrite])', 'Copia el archivo.'),
      method('Move(destination)', 'Mueve el archivo.'),
    },
  },
  Drive = {
    doc = 'Unidad del sistema de archivos con capacidad y estado.',
    members = {
      property('DriveLetter', 'Letra de la unidad.'),
      property('Path', 'Ruta de la unidad.'),
      property('IsReady', 'Indica si la unidad está disponible.'),
      property('FreeSpace', 'Espacio libre en bytes.'),
      property('TotalSize', 'Capacidad total en bytes.'),
      property('RootFolder', 'Carpeta raíz de la unidad.', 'Folder'),
    },
  },
  Files = {
    doc = 'Colección de archivos de una carpeta.',
    members = { property('Count', 'Cantidad de archivos.'),
      property('Item(key)', 'Obtiene un archivo por su nombre.', 'File') },
  },
  Folders = {
    doc = 'Colección de subcarpetas.',
    members = { property('Count', 'Cantidad de carpetas.'),
      property('Item(key)', 'Obtiene una carpeta por su nombre.', 'Folder'),
      method('Add(foldername)', 'Crea una subcarpeta.', 'Folder') },
  },
  Drives = {
    doc = 'Colección de unidades del sistema.',
    members = { property('Count', 'Cantidad de unidades.'),
      property('Item(key)', 'Obtiene una unidad por su letra.', 'Drive') },
  },
  Dictionary = {
    progids = { 'Scripting.Dictionary' },
    doc = 'Diccionario de pares clave y valor con comparación configurable.',
    members = {
      method('Add(key, item)', 'Agrega una clave y su valor; falla si la clave ya existe.'),
      method('Exists(key)', 'Indica si la clave existe.', 'Boolean'),
      method('Keys()', 'Devuelve un array de claves.', 'Variant()'),
      method('Items()', 'Devuelve un array de valores.', 'Variant()'),
      method('Remove(key)', 'Elimina una clave y su valor.'),
      method('RemoveAll()', 'Vacía el diccionario.'),
      property('Item(key)', 'Lee o asigna el valor de una clave.'),
      property('Count', 'Cantidad de pares almacenados.'),
      property('CompareMode', 'Modo de comparación de claves; se fija antes de agregar datos.'),
      property('Key(key)', 'Cambia una clave existente.'),
    },
  },
  DOMDocument = {
    progids = { 'MSXML2.DOMDocument', 'Microsoft.XMLDOM' },
    doc = 'Documento XML de MSXML con carga, serialización y consultas XPath.',
    members = {
      method('load(xmlSource)', 'Carga un documento desde una ruta, URL u objeto compatible.', 'Boolean'),
      method('loadXML(xml)', 'Carga un documento desde una cadena XML.', 'Boolean'),
      method('save(destination)', 'Guarda el documento en un archivo, en el objeto Response o en otro DOMDocument.'),
      method('selectSingleNode(queryString)', 'Obtiene el primer nodo que coincide con XPath, o Nothing.', 'XMLNode'),
      method('selectNodes(queryString)', 'Obtiene los nodos que coinciden con XPath.', 'XMLNodes'),
      method('createElement(tagName)', 'Crea un elemento sin agregarlo al documento; se agrega con appendChild.', 'XMLNode'),
      method('createTextNode(data)', 'Crea un nodo de texto; el contenido se escapa al serializar.', 'XMLNode'),
      method('createAttribute(name)', 'Crea un atributo sin valor; se asigna con setAttributeNode.', 'XMLNode'),
      method('createCDATASection(data)', 'Crea una sección CDATA.', 'XMLNode'),
      method('createProcessingInstruction(target, data)', 'Crea una instrucción de procesamiento, como la declaración <?xml ...?>.', 'XMLNode'),
      method('getElementsByTagName(tagName)', 'Elementos descendientes con ese nombre, en orden del documento; "*" devuelve todos.', 'XMLNodes'),
      method('appendChild(newChild)', 'Agrega un hijo al final, como el elemento raíz, y devuelve el nodo agregado.', 'XMLNode'),
      method('removeChild(childNode)', 'Quita un hijo y devuelve el nodo quitado.', 'XMLNode'),
      method('setProperty(name, value)', 'Configura una propiedad como SelectionLanguage, SelectionNamespaces o ServerHTTPRequest.'),
      method('getProperty(name)', 'Lee una propiedad configurada con setProperty.'),
      property('documentElement', 'Elemento raíz del documento.', 'XMLNode'),
      property('parseError', 'Último error de load o loadXML; errorCode vale 0 si no hubo error.', 'ParseError'),
      property('childNodes', 'Colección de hijos del documento.', 'XMLNodes'),
      property('firstChild', 'Primer hijo del documento, o Nothing.', 'XMLNode'),
      property('xml', 'Serialización XML del documento.'),
      property('text', 'Texto contenido en el documento.'),
      property('async', 'True por defecto: load vuelve antes de terminar. En ASP se fija en False antes de cargar.'),
      property('preserveWhiteSpace', 'Conserva los espacios entre elementos; False por defecto.'),
      property('validateOnParse', 'Controla la validación al cargar.'),
      property('resolveExternals', 'Controla la resolución de recursos externos.'),
    },
  },
  XMLNode = {
    doc = 'Nodo DOM de MSXML; los miembros disponibles dependen de su clase de nodo.',
    members = {
      method('selectSingleNode(queryString)', 'Obtiene el primer nodo relativo que coincide con XPath.', 'XMLNode'),
      method('selectNodes(queryString)', 'Obtiene nodos relativos que coinciden con XPath.', 'XMLNodes'),
      method('appendChild(newChild)', 'Agrega un hijo al final y devuelve el nodo agregado.', 'XMLNode'),
      method('insertBefore(newChild, refChild)', 'Inserta un hijo antes de refChild, o al final si refChild es Nothing.', 'XMLNode'),
      method('removeChild(childNode)', 'Quita un hijo y devuelve el nodo quitado.', 'XMLNode'),
      method('replaceChild(newChild, oldChild)', 'Reemplaza un hijo y devuelve el nodo reemplazado.', 'XMLNode'),
      method('cloneNode(deep)', 'Copia el nodo; con deep en True copia también sus descendientes.', 'XMLNode'),
      method('hasChildNodes()', 'Indica si el nodo tiene hijos.', 'Boolean'),
      method('getAttribute(name)', 'Valor del atributo como texto, o Null si no existe; solo en elementos.'),
      method('setAttribute(name, value)', 'Crea o cambia un atributo; solo en elementos.'),
      method('removeAttribute(name)', 'Quita un atributo; solo en elementos.'),
      method('getElementsByTagName(tagName)', 'Elementos descendientes con ese nombre; "*" devuelve todos. Solo en elementos.', 'XMLNodes'),
      property('nodeName', 'Nombre del nodo: la etiqueta de un elemento, el nombre de un atributo o "#text".'),
      property('nodeValue', 'Valor de un nodo de texto, atributo o comentario; Null en elementos.'),
      property('nodeType', 'Clase del nodo: 1 elemento, 2 atributo, 3 texto, 4 CDATA, 8 comentario, 9 documento.'),
      property('text', 'Texto del nodo y sus descendientes.'),
      property('xml', 'Serialización XML del nodo.'),
      property('attributes', 'Atributos de un elemento; Nothing en otras clases de nodo.', 'NamedNodeMap'),
      property('childNodes', 'Colección de hijos.', 'XMLNodes'),
      property('firstChild', 'Primer hijo, o Nothing.', 'XMLNode'),
      property('lastChild', 'Último hijo, o Nothing.', 'XMLNode'),
      property('nextSibling', 'Siguiente hermano, o Nothing.', 'XMLNode'),
      property('previousSibling', 'Hermano anterior, o Nothing.', 'XMLNode'),
      property('parentNode', 'Nodo padre.', 'XMLNode'),
      property('ownerDocument', 'Documento al que pertenece el nodo.', 'DOMDocument'),
    },
  },
  XMLNodes = {
    doc = 'Lista de nodos DOM de MSXML, con índices basados en cero.',
    members = {
      property('length', 'Cantidad de nodos.'),
      property('item(index)', 'Obtiene un nodo por índice.', 'XMLNode'),
      method('nextNode()', 'Avanza al siguiente nodo de la lista.', 'XMLNode'),
      method('reset()', 'Reinicia el recorrido con nextNode.'),
    },
  },
  NamedNodeMap = {
    doc = 'Atributos de un elemento de MSXML, accesibles por nombre o por índice basado en cero.',
    members = {
      property('length', 'Cantidad de atributos.'),
      property('item(index)', 'Obtiene un atributo por índice.', 'XMLNode'),
      method('getNamedItem(name)', 'Obtiene un atributo por nombre, o Nothing.', 'XMLNode'),
      method('removeNamedItem(name)', 'Quita un atributo por nombre y lo devuelve.', 'XMLNode'),
      method('setNamedItem(newItem)', 'Agrega o reemplaza un atributo creado con createAttribute.', 'XMLNode'),
    },
  },
  ParseError = {
    doc = 'Error de análisis del último load o loadXML de un DOMDocument.',
    members = {
      property('errorCode', 'Código del error; 0 si el documento cargó bien.'),
      property('reason', 'Descripción del error.'),
      property('line', 'Línea donde ocurrió el error, desde 1.'),
      property('linepos', 'Columna del error dentro de la línea, desde 1.'),
      property('srcText', 'Texto completo de la línea con el error.'),
      property('url', 'URL del documento que se estaba cargando.'),
      property('filepos', 'Posición absoluta del error en el archivo.'),
    },
  },
  ServerXMLHTTP = {
    progids = { 'MSXML2.ServerXMLHTTP' },
    doc = 'Cliente HTTP de MSXML pensado para solicitudes desde el servidor.',
    members = {
      method('open(method, url[, async[, user[, password]]])', 'Inicializa una solicitud; async es False por defecto.'),
      method('send([body])', 'Envía la solicitud con un cuerpo opcional.'),
      method('setRequestHeader(header, value)', 'Agrega una cabecera después de open y antes de send.'),
      method('getResponseHeader(header)', 'Valor de una cabecera de la respuesta, sin distinguir mayúsculas en el nombre.', 'String'),
      method('getAllResponseHeaders()', 'Todas las cabeceras de la respuesta, una por línea con CRLF.', 'String'),
      method('setTimeouts(resolveTimeout, connectTimeout, sendTimeout, receiveTimeout)', 'Fija los cuatro tiempos de espera en milisegundos, antes de open; por defecto 0 (infinito), 60.000, 30.000 y 30.000.'),
      method('setOption(option, value)', 'Fija una opción, como SXH_OPTION_IGNORE_SERVER_SSL_CERT_ERROR_FLAGS (2) con 13056 para ignorar errores de certificado.'),
      method('getOption(option)', 'Lee una opción fijada con setOption.'),
      method('setProxy(proxySetting[, varProxyServer[, varBypassList]])', 'Configura el proxy: 0 el del registro, 1 conexión directa, 2 el servidor indicado.'),
      method('setProxyCredentials(username, password)', 'Credenciales para un proxy que las pide.'),
      method('waitForResponse([timeoutInSeconds])', 'Espera una respuesta asíncrona.', 'Boolean'),
      method('abort()', 'Cancela la solicitud.'),
      property('responseText', 'Cuerpo de la respuesta convertido a texto.'),
      property('responseXML', 'Cuerpo de la respuesta como documento XML.', 'DOMDocument'),
      property('responseBody', 'Cuerpo de la respuesta como array de bytes.'),
      property('status', 'Código de estado HTTP.'),
      property('statusText', 'Texto del estado HTTP.'),
      property('readyState', 'Estado de avance de la solicitud.'),
    },
  },
  XMLHTTP = {
    progids = { 'Microsoft.XMLHTTP', 'MSXML2.XMLHTTP' },
    doc = 'Cliente HTTP de MSXML basado en la pila de red del cliente.',
    members = {
      method('open(method, url[, async[, user[, password]]])', 'Inicializa una solicitud; async es True por defecto.'),
      method('send([body])', 'Envía la solicitud con un cuerpo opcional.'),
      method('setRequestHeader(header, value)', 'Agrega una cabecera después de open y antes de send.'),
      method('getResponseHeader(header)', 'Valor de una cabecera de la respuesta, sin distinguir mayúsculas en el nombre.', 'String'),
      method('getAllResponseHeaders()', 'Todas las cabeceras de la respuesta, una por línea con CRLF.', 'String'),
      method('abort()', 'Cancela la solicitud.'),
      property('responseText', 'Cuerpo de la respuesta convertido a texto.'),
      property('responseXML', 'Cuerpo de la respuesta como documento XML.', 'DOMDocument'),
      property('responseBody', 'Cuerpo de la respuesta como array de bytes.'),
      property('status', 'Código de estado HTTP.'),
      property('statusText', 'Texto del estado HTTP.'),
      property('readyState', 'Estado de avance de la solicitud.'),
    },
  },
  Message = {
    progids = { 'CDO.Message' },
    doc = 'Mensaje de correo CDO con remitente, destinatarios, cuerpo y configuración de envío.',
    members = {
      property('From', 'Dirección del remitente.'),
      property('To', 'Destinatarios principales, separados por comas, no por punto y coma.'),
      property('CC', 'Destinatarios en copia, separados por comas.'),
      property('BCC', 'Destinatarios en copia oculta, separados por comas.'),
      property('ReplyTo', 'Direcciones a las que se responde, separadas por comas.'),
      property('Sender', 'Dirección de quien envía en nombre del remitente From, si es distinta.'),
      property('Subject', 'Asunto del mensaje.'),
      property('TextBody', 'Cuerpo de texto sin formato.'),
      property('HTMLBody', 'Cuerpo en formato HTML.'),
      property('Configuration', 'Configuración de transporte y autenticación.', 'Configuration'),
      method('Send()', 'Envía el mensaje usando su configuración.'),
      method('AddAttachment(URL[, UserName[, Password]])', 'Adjunta un archivo por ruta o URL (file://, http://) y devuelve la parte agregada.', 'BodyPart'),
      method('CreateMHTMLBody(URL[, Flags[, UserName[, Password]]])', 'Arma un cuerpo HTML desde una página web o un archivo, con sus imágenes y recursos.'),
      property('Attachments', 'Adjuntos del mensaje.', 'BodyParts'),
      property('BodyPart', 'Parte raíz del contenido MIME del mensaje.', 'BodyPart'),
    },
  },
  BodyPart = {
    doc = 'Parte MIME de un mensaje CDO, como un adjunto.',
    members = {
      property('FileName', 'Nombre de archivo de la parte.'),
      property('ContentMediaType', 'Tipo de contenido, como "text/plain".'),
      property('Fields', 'Campos de cabecera de la parte; llama a Fields.Update tras modificarlos.', 'Fields'),
      method('SaveToFile(FileName)', 'Guarda el contenido decodificado en un archivo.'),
    },
  },
  BodyParts = {
    doc = 'Colección de partes MIME de un mensaje CDO, con índices basados en uno.',
    members = {
      property('Count', 'Cantidad de partes.'),
      property('Item(Index)', 'Obtiene una parte por índice.', 'BodyPart'),
      method('Delete(Index)', 'Quita una parte por índice.'),
      method('DeleteAll()', 'Quita todas las partes.'),
    },
  },
  Configuration = {
    progids = { 'CDO.Configuration' },
    doc = 'Opciones de CDO, como servidor SMTP, puerto y autenticación.',
    members = { property('Fields', 'Campos de configuración; llama a Fields.Update tras modificarlos.', 'Fields'),
      method('Load(LoadFrom[, URL])', 'Carga opciones desde el origen indicado.') },
  },
  RegExp = {
    progids = { 'VBScript.RegExp' },
    doc = 'Expresión regular de VBScript; se crea con New RegExp o CreateObject.',
    members = {
      property('Pattern', 'Patrón de la expresión regular.'),
      property('Global', 'True para buscar todas las coincidencias; False por defecto.'),
      property('IgnoreCase', 'True para ignorar diferencias entre mayúsculas y minúsculas.'),
      property('Multiline', 'Hace que ^ y $ reconozcan comienzos y finales de línea.'),
      method('Test(string)', 'Indica si hay alguna coincidencia.', 'Boolean'),
      method('Replace(string1, string2)', 'Reemplaza coincidencias; admite $1, $2 y otros grupos capturados.', 'String'),
      method('Execute(string)', 'Obtiene las coincidencias del patrón.', 'Matches'),
    },
  },
  Matches = {
    doc = 'Coincidencias devueltas por RegExp.Execute, con índices basados en cero.',
    members = { property('Count', 'Cantidad de coincidencias.'),
      property('Item(index)', 'Obtiene una coincidencia por índice.', 'Match') },
  },
  Match = {
    doc = 'Coincidencia de una expresión regular, con texto, posición y grupos.',
    members = {
      property('Value', 'Texto de la coincidencia.'),
      property('FirstIndex', 'Posición inicial, basada en cero.'),
      property('Length', 'Longitud de la coincidencia.'),
      property('SubMatches', 'Grupos capturados por el patrón.', 'SubMatches'),
    },
  },
  SubMatches = {
    doc = 'Textos de los grupos capturados de una coincidencia.',
    members = { property('Count', 'Cantidad de grupos.'),
      property('Item(index)', 'Texto del grupo, con índice basado en cero.') },
  },
}

local index, progid_index, progids = {}, {}, {}
for id, obj in pairs(M.types) do
  obj.name = obj.progids and obj.progids[1] or id
  obj.id = id
  obj.by_name = {}
  index[id:lower()] = obj
  for _, progid in ipairs(obj.progids or {}) do
    progid_index[progid:lower()] = obj
    progids[#progids + 1] = progid
  end
  for _, member in ipairs(obj.members) do
    member.signature = obj.name .. '.' .. member.signature
    member.params = require('asp.signature_info').parameters(member.signature)
    obj.by_name[member.name:lower()] = member
  end
end
table.sort(progids)

function M.from_progid(progid)
  if type(progid) ~= 'string' then return nil end
  local key = progid:lower():gsub('%.%d[%d%.]*$', '')
  return progid_index[key]
end

function M.object(name)
  if type(name) ~= 'string' then return nil end
  return index[name:lower()] or M.from_progid(name)
end

function M.member(type_name, member_name)
  local obj = M.object(type_name)
  return obj and obj.by_name[member_name:lower()] or nil
end

function M.progids()
  return progids
end

return M
