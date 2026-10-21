-- Tokens semánticos de asp-ls (textDocument/semanticTokens/full y
-- /range): el tipo de cada identificador de VBScript y de JavaScript de
-- cliente según la declaración a la que resuelve. Las palabras clave, los
-- literales y los comentarios los resalta tree-sitter; acá solo van los
-- nombres que distinguen una función del usuario de una variable, un
-- parámetro, una clase o un nativo.
--
-- VBScript: las declaraciones salen de asp.symbols.help (cacheado por
-- changedtick) y cada uso se resuelve con los tiers de definition y
-- references (asp.symbols.pick): local del scope, página, miembro de
-- clase; después las declaraciones de página del grafo de includes (sus
-- cachés por mtime, sin lecturas nuevas en caliente) y por último los
-- nativos de VBScript y los objetos intrínsecos de ASP. Un miembro
-- (`obj.x`) solo lleva tipo si el objeto es `Me` o un intrínseco.
--
-- JavaScript: asp.js.semantic_tokens, desde el índice de la capa JS.
local M = {}

M.legend = {
  tokenTypes = { 'namespace', 'class', 'function', 'method', 'property', 'variable', 'parameter' },
  tokenModifiers = { 'declaration', 'readonly', 'defaultLibrary' },
}

local TYPE, MOD = {}, {}
for i, name in ipairs(M.legend.tokenTypes) do TYPE[name] = i - 1 end
for i, name in ipairs(M.legend.tokenModifiers) do MOD[name] = bit.lshift(1, i - 1) end

local DECLARATION, READONLY, LIBRARY = MOD.declaration, MOD.readonly, MOD.defaultLibrary

-- Scopes, clases, nombres de miembro e identificadores en una sola
-- pasada, en orden del documento (ver asp.symbols.parse_occurrences). Un
-- miembro también es un @id: llega primero, por el orden de los patrones.
local QUERY = [[
[(sub_statement) (function_statement) (property_statement)] @scope
(class_statement) @class
(member_expression (identifier) @member)
(identifier) @id
]]

---Tipo y modificadores de una declaración de VBScript (una entry de
---asp.symbols).
---@param e table
---@return integer type, integer modifiers
local function vbscript_kind(e)
  local member = e.class_id and not e.scope_id
  if e.kind == 5 then return TYPE.class, 0 end
  if e.kind == 7 then return TYPE.property, 0 end
  if e.kind == 12 then return member and TYPE.method or TYPE['function'], 0 end
  if e.kind == 14 then return member and TYPE.property or TYPE.variable, READONLY end
  -- Un parámetro es hijo de su Sub/Function/Property, que es su scope.
  if e.scope_id and e.decl_id == e.scope_id then return TYPE.parameter, 0 end
  return member and TYPE.property or TYPE.variable, 0
end

---Tipo de un nombre nativo de VBScript o intrínseco de ASP, o nil.
local function library_kind(lower)
  if require('asp.intrinsics').object(lower) then return TYPE.namespace, LIBRARY end
  local builtins = require('asp.vbscript_builtins')
  local b = builtins.lookup(lower)
  if not b then return nil end
  if b.group == 'functions' then return TYPE['function'], LIBRARY end
  if b.group == 'constants' then return TYPE.variable, READONLY + LIBRARY end
  if b.group == 'objects' then
    return builtins.is_class(lower) and TYPE.class or TYPE.namespace, LIBRARY
  end
  return nil
end

---Objeto de `obj.x` cuando es un nombre simple (`Me`, `Response`), por el
---texto de la línea antes del punto; nil para `f(1).x`, `a.b.x` o una
---continuación ` _`.
local function object_name(line, col)
  local before = line:sub(1, col)
  local s, _, name = before:find('([%a_][%w_]*)%s*%.%s*$')
  if not s or (s > 1 and before:sub(s - 1, s - 1):match('[%w_.]')) then return nil end
  return name:lower()
end

---Tokens de VBScript del buffer: {fila, columna, largo, tipo, modificadores}.
---@param bufnr integer
---@return table[]
local function vbscript_tokens(bufnr)
  local out = {}
  local parser = require('asp.ts').parse_vbscript(bufnr)
  local vbscript = parser and parser:children().vbscript
  if not vbscript then return out end
  local symbols = require('asp.symbols')
  local entries = symbols.help(bufnr).entries

  -- Declaraciones por nombre en minúsculas y por posición de su nombre.
  local by_name, declared = {}, {}
  for _, e in ipairs(entries) do
    local lower = e.name:lower()
    by_name[lower] = by_name[lower] or {}
    table.insert(by_name[lower], e)
    declared[e.selection[1] .. ':' .. e.selection[2]] = e
  end
  -- Página del grafo de includes, por nombre: el primero en orden DFS gana,
  -- como en definition. Se arma con el primer nombre que no resuelve acá.
  local included
  local function include_entry(lower)
    if not included then
      included = {}
      for _, file in ipairs(require('asp.includes').buffer_graph(bufnr).order) do
        for _, e in ipairs(symbols.collect_file(file)) do
          local n = e.name:lower()
          if not e.scope_id and not e.class_id and included[n] == nil then included[n] = e end
        end
      end
    end
    return included[lower]
  end

  local lines = {}
  local function line_of(row)
    local text = lines[row]
    if not text then
      text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
      lines[row] = text
    end
    return text
  end

  local query = vim.treesitter.query.parse('vbscript', QUERY)
  for _, tree in ipairs(vbscript:trees()) do
    -- Pilas de scopes y clases abiertos: su id y el byte donde terminan.
    local scopes, scope_stops, classes, class_stops = {}, {}, {}, {}
    local member_at
    for id, node in query:iter_captures(tree:root(), bufnr) do
      local cap = query.captures[id]
      local r0, c0, start = node:start()
      while scope_stops[1] and scope_stops[#scope_stops] <= start do
        scopes[#scopes], scope_stops[#scope_stops] = nil, nil
      end
      while class_stops[1] and class_stops[#class_stops] <= start do
        classes[#classes], class_stops[#class_stops] = nil, nil
      end
      if cap == 'scope' or cap == 'class' then
        local _, _, stop = node:end_()
        if cap == 'scope' then
          scopes[#scopes + 1], scope_stops[#scope_stops + 1] = node:id(), stop
        else
          classes[#classes + 1], class_stops[#class_stops + 1] = node:id(), stop
        end
      elseif cap == 'member' then
        member_at = start
      else
        local r1, c1 = node:end_()
        local line = line_of(r0)
        local text = r0 == r1 and line:sub(c0 + 1, c1) or ''
        if text:match('^[%a_][%w_]*$') then
          local lower = text:lower()
          local kind, mods
          local decl = declared[r0 .. ':' .. c0]
          if member_at == start then
            -- `Me.x` es un miembro de la clase que lo contiene; `Response.Write`,
            -- un miembro intrínseco. Los demás objetos no tienen tipo.
            local object = object_name(line, c0)
            if object == 'me' and classes[1] then
              for _, e in ipairs(by_name[lower] or {}) do
                if e.class_id == classes[#classes] and not e.scope_id then
                  kind, mods = vbscript_kind(e)
                  break
                end
              end
            elseif object then
              local m = require('asp.intrinsics').member(object, lower)
              if m then
                kind = m.signature:find('(', 1, true) and TYPE.method or TYPE.property
                mods = LIBRARY
              end
            end
          elseif decl then
            kind, mods = vbscript_kind(decl)
            mods = mods + DECLARATION
          else
            local e
            -- `New` toma clases, aunque una variable se llame igual.
            if line:sub(1, c0):lower():find('%f[%w_]new%s+$') then
              for _, d in ipairs(by_name[lower] or {}) do
                if d.kind == 5 then e = e or d end
              end
            end
            e = e or symbols.pick(by_name[lower] or {}, lower, scopes[#scopes], classes[#classes])
              or include_entry(lower)
            if e then
              kind, mods = vbscript_kind(e)
            else
              kind, mods = library_kind(lower)
            end
          end
          if kind then out[#out + 1] = { r0, c0, c1 - c0, kind, mods } end
        end
      end
    end
  end
  return out
end

---Tipo y modificadores de una declaración JS de asp.js.
local function javascript_kind(e)
  if e.member then return TYPE.method, 0 end
  if e.kind == 5 then return TYPE.class, 0 end
  if e.kind == 12 then return TYPE['function'], 0 end
  if e.kind == 14 then return TYPE.variable, READONLY end
  if e.parameter then return TYPE.parameter, 0 end
  return TYPE.variable, 0
end

---Tokens del buffer en orden: {fila, columna, largo, tipo, modificadores}.
---@param bufnr integer
---@return table[]
function M.tokens(bufnr)
  local out = vbscript_tokens(bufnr)
  for _, t in ipairs(require('asp.js').semantic_tokens(bufnr) or {}) do
    local kind, mods = javascript_kind(t[4])
    out[#out + 1] = { t[1], t[2], t[3], kind, mods + (t[5] and DECLARATION or 0) }
  end
  table.sort(out, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  return out
end

---Codificación relativa de LSP: por token, fila y columna respecto del
---anterior (la columna, solo en la misma fila), largo, tipo y bits de los
---modificadores. Descarta los que se solaparían con el anterior.
---@param tokens table[] ordenados
---@return integer[]
local function encode(tokens)
  local data = {}
  local prev_row, prev_col, prev_end = 0, 0, -1
  for _, t in ipairs(tokens) do
    local row, col = t[1], t[2]
    if t[3] > 0 and (row > prev_row or col >= prev_end) then
      data[#data + 1] = row - prev_row
      data[#data + 1] = row == prev_row and col - prev_col or col
      data[#data + 1] = t[3]
      data[#data + 1] = t[4]
      data[#data + 1] = t[5]
      prev_row, prev_col, prev_end = row, col, col + t[3]
    end
  end
  return data
end

---SemanticTokens del buffer entero. Nunca lanza: sin parser o ante un
---error devuelve { data = {} }.
---@param bufnr integer
---@return table { data: integer[] }
function M.full(bufnr)
  local ok, tokens = pcall(M.tokens, bufnr)
  return { data = ok and encode(tokens) or {} }
end

---SemanticTokens de los tokens que tocan `range` (LSP, fin exclusivo).
---@param bufnr integer
---@param range table {start, end}
---@return table { data: integer[] }
function M.range(bufnr, range)
  local ok, tokens = pcall(M.tokens, bufnr)
  if not ok then return { data = {} } end
  local s, e = range.start, range['end']
  local inside = vim.tbl_filter(function(t)
    if t[1] < s.line or (t[1] == s.line and t[2] + t[3] <= s.character) then return false end
    if t[1] > e.line or (t[1] == e.line and t[2] >= e.character) then return false end
    return true
  end, tokens)
  return { data = encode(inside) }
end

return M
