local M = {}

-- Nombres nativos de VBScript, agrupados. Los usan los diagnósticos
-- (asp.diagnostics) para no reportar como sin declarar ni como llamada
-- inexistente lo que el motor de VBScript ya trae. Los objetos intrínsecos
-- de ASP (Response, Request, Server, Session, Application) viven en
-- asp.intrinsics, con sus miembros.
--
-- Estructura: cada grupo es una lista de entradas y hoy cada entrada es
-- solo el nombre con su capitalización canónica. El cambio 3 del roadmap
-- (hover, completion y signatureHelp de nativos) convierte las entradas
-- que lo necesiten en tablas sin cambiar la API:
--
--   { 'Mid', signature = 'Mid(string, start[, length])', doc = '...' }
--
-- M.lookup ya acepta las dos formas y devuelve siempre una tabla con
-- `name` y `group` más los campos que tenga la entrada.

M.groups = {
  -- Funciones y procedimientos nativos (incluye las sentencias que se
  -- escriben como una llamada: Execute, ExecuteGlobal y Randomize).
  functions = {
    'Abs', 'Array', 'Asc', 'AscB', 'AscW', 'Atn', 'CBool', 'CByte', 'CCur',
    'CDate', 'CDbl', 'Chr', 'ChrB', 'ChrW', 'CInt', 'CLng', 'Cos',
    'CreateObject', 'CSng', 'CStr', 'Date', 'DateAdd', 'DateDiff',
    'DatePart', 'DateSerial', 'DateValue', 'Day', 'Escape', 'Eval',
    'Execute', 'ExecuteGlobal', 'Exp', 'Filter', 'Fix', 'FormatCurrency',
    'FormatDateTime', 'FormatNumber', 'FormatPercent', 'GetLocale',
    'GetObject', 'GetRef', 'Hex', 'Hour', 'InputBox', 'InStr', 'InStrB',
    'InStrRev', 'Int', 'IsArray', 'IsDate', 'IsEmpty', 'IsNull',
    'IsNumeric', 'IsObject', 'Join', 'LBound', 'LCase', 'Left', 'LeftB',
    'Len', 'LenB', 'LoadPicture', 'Log', 'LTrim', 'Mid', 'MidB', 'Minute',
    'Month', 'MonthName', 'MsgBox', 'Now', 'Oct', 'Randomize', 'Replace',
    'RGB', 'Right', 'RightB', 'Rnd', 'Round', 'RTrim', 'ScriptEngine',
    'ScriptEngineBuildVersion', 'ScriptEngineMajorVersion',
    'ScriptEngineMinorVersion', 'Second', 'SetLocale', 'Sgn', 'Sin',
    'Space', 'Split', 'Sqr', 'StrComp', 'String', 'StrReverse', 'Tan',
    'Time', 'Timer', 'TimeSerial', 'TimeValue', 'Trim', 'TypeName',
    'UBound', 'UCase', 'Unescape', 'VarType', 'Weekday', 'WeekdayName',
    'Year',
  },
  constants = {
    -- Literales (la gramática ya los reconoce; se listan por completitud).
    'True', 'False', 'Nothing', 'Empty', 'Null',
    -- Cadenas.
    'vbCr', 'vbCrLf', 'vbFormFeed', 'vbLf', 'vbNewLine', 'vbNullChar',
    'vbNullString', 'vbTab', 'vbVerticalTab',
    -- Comparación.
    'vbBinaryCompare', 'vbTextCompare', 'vbDatabaseCompare',
    -- Fechas: días, primera semana y formatos.
    'vbSunday', 'vbMonday', 'vbTuesday', 'vbWednesday', 'vbThursday',
    'vbFriday', 'vbSaturday', 'vbUseSystem', 'vbUseSystemDayOfWeek', 'vbFirstJan1',
    'vbFirstFourDays', 'vbFirstFullWeek', 'vbGeneralDate', 'vbLongDate',
    'vbShortDate', 'vbLongTime', 'vbShortTime',
    -- Tres estados (FormatNumber y familia).
    'vbUseDefault', 'vbTrue', 'vbFalse',
    -- VarType.
    'vbEmpty', 'vbNull', 'vbInteger', 'vbLong', 'vbSingle', 'vbDouble',
    'vbCurrency', 'vbDate', 'vbString', 'vbObject', 'vbError', 'vbBoolean',
    'vbVariant', 'vbDataObject', 'vbDecimal', 'vbByte', 'vbArray',
    -- Colores.
    'vbBlack', 'vbRed', 'vbGreen', 'vbYellow', 'vbBlue', 'vbMagenta',
    'vbCyan', 'vbWhite',
    -- MsgBox: botones, iconos y respuestas.
    'vbOKOnly', 'vbOKCancel', 'vbAbortRetryIgnore', 'vbYesNoCancel',
    'vbYesNo', 'vbRetryCancel', 'vbCritical', 'vbQuestion',
    'vbExclamation', 'vbInformation', 'vbDefaultButton1',
    'vbDefaultButton2', 'vbDefaultButton3', 'vbDefaultButton4',
    'vbApplicationModal', 'vbSystemModal', 'vbOK', 'vbCancel', 'vbAbort',
    'vbRetry', 'vbIgnore', 'vbYes', 'vbNo', 'vbMsgBoxHelpButton',
    'vbMsgBoxSetForeground', 'vbMsgBoxRight', 'vbMsgBoxRtlReading',
    -- Errores.
    'vbObjectError',
  },
  -- Palabras reservadas. La gramática consume la mayoría como tokens, pero
  -- algunas llegan como identificador cuando no hay regla que las tome
  -- (`New`, `Is`, `Me`, `Rem`, los tipos de un `As Integer` tolerado).
  keywords = {
    'And', 'As', 'Boolean', 'ByRef', 'Byte', 'ByVal', 'Call', 'Case',
    'Class', 'Const', 'Currency', 'Default', 'Dim', 'Do', 'Double', 'Each',
    'Else', 'ElseIf', 'End', 'EndIf', 'Enum', 'Eqv', 'Erase', 'Error',
    'Event', 'Exit', 'Explicit', 'For', 'Function', 'Get', 'GoTo', 'If',
    'Imp', 'Implements', 'In', 'Integer', 'Is', 'Let', 'Like', 'Long',
    'Loop', 'LSet', 'Me', 'Mod', 'New', 'Next', 'Not', 'On', 'Option',
    'Optional', 'Or', 'ParamArray', 'Preserve', 'Private', 'Property',
    'Public', 'RaiseEvent', 'ReDim', 'Rem', 'Resume', 'RSet', 'Select',
    'Set', 'Shared', 'Single', 'Static', 'Step', 'Stop', 'Sub', 'Then',
    'To', 'Type', 'TypeOf', 'Until', 'Variant', 'Wend', 'While', 'With',
    'Xor',
  },
  -- Objetos y clases nativos fuera de asp.intrinsics.
  objects = { 'Err', 'ObjectContext', 'ASPError', 'RegExp', 'Debug' },
}

-- Clases que acepta `New` además de las declaradas con Class.
M.classes = { 'RegExp' }

-- nombre en minúsculas → { name, group, ...campos de la entrada }
local index = {}
for group, entries in pairs(M.groups) do
  for _, entry in ipairs(entries) do
    local info = type(entry) == 'table' and vim.deepcopy(entry) or {}
    info.name = type(entry) == 'table' and entry[1] or entry
    info[1] = nil
    info.group = group
    index[info.name:lower()] = info
  end
end

local classes = {}
for _, name in ipairs(M.classes) do classes[name:lower()] = true end

---Entrada nativa de `name` (sin distinguir mayúsculas) o nil.
---@param name string
---@return table|nil { name, group, ... }
function M.lookup(name)
  if type(name) ~= 'string' then return nil end
  return index[name:lower()]
end

---¿`name` es una clase nativa que se puede instanciar con `New`?
---@param name string
---@return boolean
function M.is_class(name)
  return type(name) == 'string' and classes[name:lower()] == true
end

return M
