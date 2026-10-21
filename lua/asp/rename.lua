-- Renombrar símbolos de VBScript y de JavaScript de cliente
-- (textDocument/prepareRename y textDocument/rename). El rename es tan
-- completo como las referencias de cada capa, y usa sus cachés sin
-- lecturas propias: asp.symbols.references (alcance de sitio, sin los
-- miembros de objeto) y asp.js.references (los <script>, manejadores
-- `on*`, URLs `javascript:`, `.js` de <script src> e includes). Este
-- módulo decide si la posición se puede renombrar, valida el nombre nuevo,
-- acota los miembros de clase (ver vbscript_locations) y arma el
-- WorkspaceEdit.
--
-- Cuando no se puede renombrar, prepare y rename devuelven nil y un error
-- LSP (InvalidParams) con el motivo, no un nil a secas: Neovim muestra el
-- mensaje del error ("Error on prepareRename: ...") y ante un nil solo
-- dice "Nothing to rename".
local M = {}

local INVALID_PARAMS = -32602
local INTERNAL_ERROR = -32603

local function fail(message, code)
  return nil, { code = code or INVALID_PARAMS, message = message }
end

local function node_range(node)
  local r0, c0, r1, c1 = node:range()
  return { start = { line = r0, character = c0 }, ['end'] = { line = r1, character = c1 } }
end

-- ¿`pos` cae dentro de `range` (límites inclusivos)?
local function contains(range, pos)
  local s, e = range.start, range['end']
  if pos.line < s.line or (pos.line == s.line and pos.character < s.character) then return false end
  if pos.line > e.line or (pos.line == e.line and pos.character > e.character) then return false end
  return true
end

local function text_at(bufnr, range)
  local line = vim.api.nvim_buf_get_lines(bufnr, range.start.line, range.start.line + 1, true)[1]
  return line:sub(range.start.character + 1, range['end'].character)
end

-- Palabra de `chars` (una clase de Lua) que contiene la columna `col`
-- (0-indexed) de la línea: solo para nombrar lo que no se renombra.
local function word_at(bufnr, position, chars)
  local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, true)[1]
  local s, e = position.character + 1, position.character
  while s > 1 and line:sub(s - 1, s - 1):match(chars) do s = s - 1 end
  while e < #line and line:sub(e + 1, e + 1):match(chars) do e = e + 1 end
  return line:sub(s, e)
end

local VBSCRIPT_GROUPS = {
  keywords = 'una palabra clave de VBScript',
  functions = 'una función nativa de VBScript',
  constants = 'una constante nativa de VBScript',
  objects = 'un objeto nativo de VBScript',
}

---Por qué `name` no puede ser el nombre de un símbolo del usuario en
---VBScript (sin distinguir mayúsculas), o nil.
local function vbscript_reserved(name)
  if require('asp.intrinsics').object(name) then return 'un objeto intrínseco de ASP' end
  local builtin = require('asp.vbscript_builtins').lookup(name)
  return builtin and VBSCRIPT_GROUPS[builtin.group]
end

-- Palabras reservadas de ECMAScript (también las de modo estricto y las
-- futuras) y los literales: ninguna puede ser el nombre de un binding.
local JS_RESERVED = {}
for word in ([[
  await break case catch class const continue debugger default delete do
  else enum export extends false finally for function if implements import
  in instanceof interface let new null package private protected public
  return static super switch this throw true try typeof var void while
  with yield
]]):gmatch('%S+') do
  JS_RESERVED[word] = true
end

local function validate_vbscript(new, old)
  if new == old then return 'el nombre nuevo es igual al actual' end
  if not new:match('^[A-Za-z][A-Za-z0-9_]*$') then
    return ('`%s` no es un identificador de VBScript: una letra seguida de letras, dígitos o _'):format(new)
  end
  if #new > 255 then return 'VBScript admite nombres de hasta 255 caracteres' end
  local reason = vbscript_reserved(new)
  if reason then return ('`%s` es %s'):format(new, reason) end
  return nil
end

local function validate_javascript(new, old)
  if new == old then return 'el nombre nuevo es igual al actual' end
  if not new:match('^[A-Za-z_$][A-Za-z0-9_$]*$') then
    return ('`%s` no es un identificador de JavaScript: una letra, _ o $ seguida de letras, dígitos, _ o $')
      :format(new)
  end
  if JS_RESERVED[new] then return ('`%s` es una palabra reservada de JavaScript'):format(new) end
  return nil
end

---Identificador VBScript bajo el cursor que se puede renombrar. Devuelve
---nil sin error si la posición no es un identificador VBScript.
local function vbscript_target(bufnr, position)
  local symbols = require('asp.symbols')
  local node = symbols.identifier_at(bufnr, position)
  if not node then return nil end
  local name = vim.treesitter.get_node_text(node, bufnr)
  local range = node_range(node)
  -- La inyección combinada puede fundir el final de un bloque <% %> con
  -- el comienzo de otro en un solo `identifier` que cruza el HTML y el JS
  -- del medio (ver "Varios bloques <%= %>" en el README). Ese nodo no es
  -- un nombre: la posición queda para las capas siguientes.
  if range.start.line ~= range['end'].line or not name:match('^[%a_][%w_]*$') then return nil end
  if symbols.is_member(node, bufnr) then
    return fail(('`%s` es un miembro de objeto: asp-ls no renombra miembros'):format(name))
  end
  local reason = vbscript_reserved(name)
  if reason then return fail(('`%s` es %s: no se renombra'):format(name, reason)) end
  -- Sin declaración resoluble (un nombre sin Dim, sin Option Explicit) no
  -- hay símbolo que renombrar: references lo buscaría solo por su texto.
  if not symbols.definition(bufnr, position) then
    return fail(('`%s` no tiene una declaración en la página ni en sus includes'):format(name))
  end
  return { lang = 'vbscript', name = name, range = range }
end

---Identificador JS bajo el cursor que se puede renombrar. Devuelve nil
---sin error si la posición no es JavaScript.
local function javascript_target(bufnr, position)
  local js = require('asp.js')
  -- buffer_only: alcanza para ubicar el identificador sin cargar los
  -- archivos externos. {} es una propiedad (`obj.metodo`).
  local refs = js.references(bufnr, position, { buffer_only = true })
  if refs == nil then return nil end
  if #refs == 0 then
    local name = word_at(bufnr, position, '[%w_$]')
    return fail(('`%s` es una propiedad de objeto: asp-ls no renombra propiedades'):format(name))
  end
  local uri = vim.uri_from_bufnr(bufnr)
  local range
  for _, ref in ipairs(refs) do
    if ref.uri == uri and contains(ref.range, position) then range = ref.range end
  end
  if not range then return nil end
  local name = text_at(bufnr, range)
  if not js.definition(bufnr, position) then
    return fail(('`%s` no tiene una declaración en la página, sus .js ni sus includes'):format(name))
  end
  return { lang = 'javascript', name = name, range = range }
end

---Símbolo renombrable bajo `position`: {lang, name, range} o nil y
---el error que explica por qué no.
local function target(bufnr, position)
  if vim.api.nvim_buf_get_name(bufnr) == '' then
    return fail('el buffer no tiene nombre: guardalo antes de renombrar')
  end
  local t, err = vbscript_target(bufnr, position)
  if t or err then return t, err end
  t, err = javascript_target(bufnr, position)
  if t or err then return t, err end
  if require('asp.pages').definition(bufnr, position) then
    return fail('es un literal de página: asp-ls no renombra archivos')
  end
  return fail('no hay un símbolo de VBScript o JavaScript para renombrar en esta posición')
end

-- Rango de un entry de asp.symbols como rango LSP.
local function entry_range(r)
  return { start = { line = r[1], character = r[2] }, ['end'] = { line = r[3], character = r[4] } }
end

local function same_range(a, b)
  return a.start.line == b.start.line and a.start.character == b.start.character
    and a['end'].line == b['end'].line and a['end'].character == b['end'].character
end

local function where(bufnr, e)
  return ('%s:%d'):format(vim.fn.fnamemodify(e.file or vim.api.nvim_buf_get_name(bufnr), ':t'),
    e.selection[1] + 1)
end

---Una declaración con el nombre nuevo en el mismo alcance juntaría dos
---símbolos en uno: VBScript lo rechaza ("Name redefined") o, entre
---archivos, en runtime gana la última. Se mira el buffer y, para un
---símbolo de página, las declaraciones de página de su grafo de includes:
---las de la caché de asp.symbols.collect_file, que los diagnósticos ya
---llenan con todo el grafo al abrir la página.
local function vbscript_conflict(bufnr, entries, decl, new_name)
  local new = new_name:lower()
  local function same_scope(e)
    if decl and decl.scope_id then return e.scope_id == decl.scope_id end
    if decl and decl.class_id then return e.class_id == decl.class_id and not e.scope_id end
    return not e.scope_id and not e.class_id
  end
  for _, e in ipairs(entries) do
    if e.name:lower() == new and same_scope(e) then return e end
  end
  if decl and (decl.scope_id or decl.class_id) then return nil end
  local symbols = require('asp.symbols')
  for _, file in ipairs(require('asp.includes').buffer_graph(bufnr).order) do
    for _, e in ipairs(symbols.collect_file(file)) do
      if e.name:lower() == new and not e.scope_id and not e.class_id then return e end
    end
  end
  return nil
end

---Ubicaciones VBScript a renombrar: references con alcance de sitio, sin
---los miembros de objeto (`obj.Total`, `Me.Total`).
---
---Un miembro de clase solo es visible como identificador suelto dentro de
---su clase: con el cursor en una clase del buffer que declara ese nombre
---(y fuera de un local homónimo), se renombra el miembro y nada más que
---dentro de la clase. references no separa esos miembros de un nombre de
---página homónimo (ver "Heredado del resolver" en la spec): un rename de
---página que tocaría una de esas clases del buffer se rechaza, para no
---renombrar la declaración del miembro y dejar sus `Me.x` sin cambiar.
local function vbscript_locations(bufnr, position, t, new_name)
  local symbols = require('asp.symbols')
  local wanted = t.name:lower()
  local refs, binding = symbols.references(bufnr, position, { buffer_only = true, skip_members = true })
  local entries = symbols.collect(bufnr)
  local members = {}
  for _, e in ipairs(entries) do
    if e.class_id and not e.scope_id and e.name:lower() == wanted then members[e.class_id] = true end
  end
  local classes, class = {}, nil
  for _, e in ipairs(entries) do
    if members[e.decl_id] then
      local c = { entry = e, range = entry_range(e.range) }
      table.insert(classes, c)
      if not (binding and binding.scope_id) and contains(c.range, position) then class = c end
    end
  end

  if new_name:lower() ~= wanted then
    local decl = class and { class_id = class.entry.decl_id } or (binding and binding.scope_id and binding) or nil
    local clash = vbscript_conflict(bufnr, entries, decl, new_name)
    if clash then
      return fail(('ya hay una declaración `%s` en el mismo alcance (%s)'):format(clash.name, where(bufnr, clash)))
    end
  end
  if class then
    return vim.tbl_filter(function(ref) return contains(class.range, ref.range.start) end, refs)
  end
  -- Un local no sale del buffer: references ya devolvió todo.
  if binding and binding.scope_id then return refs end
  local all = symbols.references(bufnr, position, { skip_members = true })
  local own = vim.uri_from_bufnr(bufnr)
  for _, ref in ipairs(all) do
    for _, c in ipairs(ref.uri == own and classes or {}) do
      if contains(c.range, ref.range.start) then
        return fail(('la clase `%s` (%s) declara un miembro `%s` que asp-ls no separa del nombre '
          .. 'de página: renombrá el miembro desde adentro de la clase'):format(c.entry.name, where(bufnr, c.entry), t.name))
      end
    end
  end
  return all
end

---Las declaraciones JS del buffer no se pueden juntar con otra del mismo
---alcance: se mira el scope de la declaración renombrada (o el global si
---está en un archivo externo).
local function javascript_conflict(bufnr, position, new_name)
  local js = require('asp.js')
  local def = js.definition(bufnr, position)
  local decls = js.collect(bufnr) or {}
  local decl
  if def and def.uri == vim.uri_from_bufnr(bufnr) then
    for _, e in ipairs(decls) do
      if not e.member and same_range(node_range(e.node), def.range) then decl = e end
    end
  end
  for _, e in ipairs(decls) do
    if e.name == new_name and not e.member then
      local same
      if decl and decl.scope then
        same = e.scope ~= nil and e.scope:equal(decl.scope)
      else
        same = e.global
      end
      if same then return e end
    end
  end
  return nil
end

local function javascript_locations(bufnr, position, _, new_name)
  local clash = javascript_conflict(bufnr, position, new_name)
  if clash then
    return fail(('ya hay una declaración `%s` en el mismo alcance (%s:%d)'):format(new_name,
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':t'), clash.node:range() + 1))
  end
  -- Solo las ubicaciones: el segundo valor de references es el binding.
  return (require('asp.js').references(bufnr, position, { rename_to = new_name }))
end

---WorkspaceEdit con un TextEdit por ubicación, sin rangos repetidos y en
---orden descendente dentro de cada archivo. Las ubicaciones de un archivo
---abierto en otro buffer usan la uri de ese buffer; si tiene cambios sin
---guardar el rename se rechaza, porque sus posiciones salieron del disco.
local function workspace_edit(bufnr, locations, new_name)
  local own_uri = vim.uri_from_bufnr(bufnr)
  local function real(path)
    return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
  end
  local open = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= '' and vim.api.nvim_buf_is_loaded(b) then open[real(name)] = b end
  end
  local canonical = { [own_uri] = own_uri }
  local function uri_of(uri)
    if canonical[uri] then return canonical[uri] end
    local b = open[real(vim.uri_to_fname(uri))]
    if b and b ~= bufnr and vim.bo[b].modified then
      return nil, b
    end
    canonical[uri] = b and vim.uri_from_bufnr(b) or uri
    return canonical[uri]
  end

  local changes, seen = {}, {}
  for _, loc in ipairs(locations) do
    local uri, dirty = uri_of(loc.uri)
    if not uri then
      return fail(('%s tiene cambios sin guardar: guardalo antes de renombrar')
        :format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(dirty), ':~:.')))
    end
    local r = loc.range
    local key = ('%s:%d:%d:%d:%d'):format(uri, r.start.line, r.start.character, r['end'].line, r['end'].character)
    if not seen[key] then
      seen[key] = true
      changes[uri] = changes[uri] or {}
      table.insert(changes[uri], { range = r, newText = loc.newText or new_name })
    end
  end
  for _, edits in pairs(changes) do
    table.sort(edits, function(a, b)
      if a.range.start.line ~= b.range.start.line then return a.range.start.line > b.range.start.line end
      return a.range.start.character > b.range.start.character
    end)
  end
  return { changes = changes }
end

-- Ningún error escapa: un fallo inesperado vuelve como error LSP interno.
local function protected(fn, ...)
  local ok, result, err = pcall(fn, ...)
  if ok then return result, err end
  return fail('asp-ls no pudo renombrar: ' .. tostring(result), INTERNAL_ERROR)
end

---Rango y texto del símbolo bajo el cursor si se puede renombrar.
---@param bufnr integer
---@param position table {line, character} (utf-8, 0-indexed como LSP)
---@return table|nil {range, placeholder}
---@return table|nil err {code, message}
function M.prepare(bufnr, position)
  return protected(function()
    bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
    local t, err = target(bufnr, position)
    if not t then return nil, err end
    return { range = t.range, placeholder = t.name }
  end)
end

---WorkspaceEdit que renombra el símbolo bajo el cursor a `new_name`.
---@param bufnr integer
---@param position table {line, character}
---@param new_name string
---@return table|nil WorkspaceEdit {changes}
---@return table|nil err {code, message}
function M.rename(bufnr, position, new_name)
  return protected(function()
    bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
    local t, err = target(bufnr, position)
    if not t then return nil, err end
    if type(new_name) ~= 'string' then return fail('falta el nombre nuevo') end
    local validate = t.lang == 'vbscript' and validate_vbscript or validate_javascript
    local problem = validate(new_name, t.name)
    if problem then return fail(problem) end
    local locate = t.lang == 'vbscript' and vbscript_locations or javascript_locations
    local locations, lerr = locate(bufnr, position, t, new_name)
    if lerr then return nil, lerr end
    if not locations or #locations == 0 then
      return fail(('no se encontraron referencias de `%s` para renombrar'):format(t.name))
    end
    return workspace_edit(bufnr, locations, new_name)
  end)
end

---Buffer de una uri de los params, o nil y el error si es la de un buffer
---sin nombre: `file://` a secas (ruta `/`) resolvería a otro buffer.
---@param uri string
---@return integer|nil bufnr
---@return table|nil err
function M.buffer_for(uri)
  local fname = vim.uri_to_fname(uri)
  if fname == '' or fname == '/' then
    return fail('el buffer no tiene nombre: guardalo antes de renombrar')
  end
  return vim.uri_to_bufnr(uri)
end

return M
