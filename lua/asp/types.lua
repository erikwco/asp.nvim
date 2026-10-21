local M = {}
local com = require('asp.com')

local SCOPES = { sub_statement = true, function_statement = true, property_statement = true }

local function unwrap(node)
  while node and (node:type() == 'expression' or node:type() == 'primary_expression')
    and node:named_child_count() == 1 do
    node = node:named_child(0)
  end
  return node
end

local function member_of(node, source)
  if not node or node:type() ~= 'member_expression' then return nil end
  local object = unwrap(node:named_child(0))
  local member = node:named_child(1)
  if not object or object:type() ~= 'identifier' or not member then return nil end
  return vim.treesitter.get_node_text(object, source), vim.treesitter.get_node_text(member, source)
end

local function assignment(node, source)
  local target = unwrap(node:named_child(0))
  if not target or target:type() ~= 'identifier' then return nil end
  local entry = { name = vim.treesitter.get_node_text(target, source):lower() }
  local ancestor = node:parent()
  while ancestor do
    if not entry.scope_id and SCOPES[ancestor:type()] then entry.scope_id = ancestor:id() end
    if not entry.class_id and ancestor:type() == 'class_statement' then entry.class_id = ancestor:id() end
    ancestor = ancestor:parent()
  end
  entry.range = { node:range() }
  local rhs = unwrap(node:named_child(1))
  if not rhs then return entry end
  -- `Set x = Nothing` libera la referencia: no fija ni oculta un tipo, ni
  -- en una Sub que cierra un objeto de página.
  if rhs:type() == 'nothing_literal' then return nil end
  local text = vim.treesitter.get_node_text(rhs, source)
  if rhs:type() == 'identifier' and text:lower() == 'new' then
    -- La gramática separa `New RegExp` en dos expresiones. Solo se acepta
    -- el identificador contiguo en la misma línea, dentro del mismo scope.
    local next_node = node:next_named_sibling()
    if next_node and next_node:start() == select(3, node:range()) then
      local following = unwrap(next_node)
      local row, col, byte = node:end_()
      local _, next_col, next_byte = next_node:start()
      local gap = type(source) == 'string' and source:sub(byte + 1, next_byte)
        or table.concat(vim.api.nvim_buf_get_text(source, row, col, row, next_col, {}))
      if following and following:type() == 'identifier'
        and gap:match('^%s*$')
        and vim.treesitter.get_node_text(following, source):lower() == 'regexp' then
        entry.type = 'RegExp'
      end
    end
    return entry
  end
  local callable, argument
  if rhs:type() == 'function_call' then
    callable = vim.treesitter.get_node_text(rhs:named_child(0), source):lower()
    argument = unwrap(rhs:named_child(1))
  elseif rhs:type() == 'call_expression' then
    local object, member = member_of(rhs:named_child(0), source)
    if object and object:lower() == 'server' and member:lower() == 'createobject' then
      callable, argument = 'createobject', unwrap(rhs:named_child(1))
    else
      entry.object, entry.member = object, member
      entry.indexed = true
    end
  else
    entry.object, entry.member = member_of(rhs, source)
  end
  if callable == 'createobject' and argument and argument:type() == 'string_literal' then
    local progid = vim.treesitter.get_node_text(argument, source):match('^"(.-)"$')
    local obj = com.from_progid(progid)
    entry.type = obj and obj.id or nil
  end
  return entry
end

---Hechos de asignación extraídos de árboles existentes; no lee ni parsea disco.
function M.scan(roots, source)
  local out = {}
  local query = vim.treesitter.query.parse('vbscript', '(set_statement) @set')
  local lines, normalized
  if type(source) == 'number' then
    lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
    normalized = vim.split(require('asp.vbscript_scan').source(table.concat(lines, '\n')), '\n')
  end
  for _, root in ipairs(roots) do
    for _, node in query:iter_captures(root, source) do
      local row, col = node:start()
      -- El árbol inyectado aún puede ver instrucciones dentro de un Rem.
      if not lines or lines[row + 1]:sub(1, col) == normalized[row + 1]:sub(1, col) then
        local entry = assignment(node, source)
        if entry then out[#out + 1] = entry end
      end
    end
  end
  table.sort(out, function(a, b)
    return a.range[1] < b.range[1] or (a.range[1] == b.range[1] and a.range[2] < b.range[2])
  end)
  return out
end

---Tipo COM: primera asignación del scope más cercano. Un retorno de un
---miembro puede seguir una asignación directa, pero no otra cadena de retornos.
function M.infer(bufnr, position, name)
  local symbols = require('asp.symbols')
  local current = symbols.help(bufnr)
  local scope = symbols.scope_at(current.entries, position)
  local files
  local function first(data, wanted, scope_id)
    for _, entry in ipairs(data.assignments) do
      if entry.name == wanted and entry.scope_id == scope_id
        and (scope_id or not entry.class_id) then return entry end
    end
  end
  local function find(wanted, local_scope)
    if local_scope then
      local entry = first(current, wanted, local_scope)
      if entry then return entry, local_scope end
      for _, decl in ipairs(current.entries) do
        if decl.scope_id == local_scope and decl.name:lower() == wanted then return nil end
      end
    end
    local entry = first(current, wanted)
    if entry then return entry end
    files = files or require('asp.includes').buffer_graph(bufnr).order
    for _, file in ipairs(files) do
      entry = first(symbols.file_help(file), wanted)
      if entry then return entry end
    end
  end
  local function resolve(wanted, local_scope, depth)
    local entry, owner_scope = find(wanted:lower(), local_scope)
    if not entry then return nil end
    if entry.type then return com.object(entry.type) end
    if depth == 0 or not entry.object then return nil end
    local owner = resolve(entry.object, owner_scope, depth - 1)
    local member = owner and com.member(owner.id, entry.member)
    local result = member and com.object(member.returns)
    if result and entry.indexed and member.kind == 'property' and #member.params == 0 then
      local item = com.member(result.id, 'Item')
      return item and com.object(item.returns) or nil
    end
    return result
  end
  return resolve(name, scope, 1)
end

return M
