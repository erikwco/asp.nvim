local M = {}

local intrinsics = require('asp.intrinsics')
local native = require('asp.vbscript_builtins')
local com = require('asp.com')

-- CompletionItemKind (LSP): Method=2, Field=5, Function=3, Variable=6,
-- Class=7, Constant=21, Module=9.
local KIND_METHOD = 2
local KIND_MODULE = 9

-- Mapa de SymbolKind (documentSymbol) → CompletionItemKind.
local SYM_TO_COMPL = {
  [5] = 7,   -- Class → Class
  [7] = 3,   -- Property → Function
  [12] = 3,  -- Function → Function
  [13] = 6,  -- Variable → Variable
  [14] = 21, -- Constant → Constant
}

local function item(label, kind, detail, doc)
  return {
    label = label, kind = kind, detail = detail,
    documentation = doc and { kind = 'markdown', value = doc } or nil,
  }
end

---@param bufnr integer
---@param position table {line, character}
---@return table[] CompletionItem[]
function M.complete(bufnr, position)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1] or ''
  local before = line:sub(1, position.character)

  local context = require('asp.call_context')
  local text = context.line(bufnr, position)
  if not text then return {} end
  if text.string_start then
    local call = context.active(text)
    if call and call.open and call.parameter == 0
      and (call.name:lower() == 'createobject' or call.name:lower() == 'server.createobject')
      and text.text:sub(call.open + 1, text.string_start - 1):match('^%s*$') then
      local prefix = text.text:sub(text.string_start + 1):lower()
      local out = {}
      for _, progid in ipairs(com.progids()) do
        if progid:lower():sub(1, #prefix) == prefix then
          local entry = item(progid, 7, 'ProgID COM', com.from_progid(progid).doc)
          entry.textEdit = {
            newText = progid,
            range = { start = { line = position.line, character = text.offset + text.string_start },
              ['end'] = position },
          }
          out[#out + 1] = entry
        end
      end
      return out
    end
    return {}
  end

  -- ¿contexto miembro? Objeto . prefijo. Un objeto sin tipo conocido (una
  -- clase del usuario, un COM fuera del catálogo o una cadena `a.b.`) cae
  -- al contexto general, sin nativos ni palabras clave.
  local start, _, obj_name, prefix = before:find('([%a_][%w_]*)%s*%.%s*([%w_]*)$')
  if obj_name then
    local preceding = before:sub(1, start - 1)
    local chained = preceding:match('%.%s*$') or preceding:match('[%w_]$')
    local members
    if not chained and intrinsics.object(obj_name) then
      members = intrinsics.members_of(obj_name)
    elseif not chained then
      local obj = require('asp.types').infer(bufnr, position, obj_name)
      members = obj and obj.members
    end
    if members then
      local out = {}
      local pfx = prefix:lower()
      for _, m in ipairs(members) do
        if pfx == '' or m.name:lower():sub(1, #pfx) == pfx then
          table.insert(out, item(m.name, m.kind == 'property' and 10 or KIND_METHOD, m.signature, m.doc))
        end
      end
      return out
    end
  end

  -- contexto general: objetos intrínsecos + símbolos del buffer y del grafo.
  local word = before:match('([%w_]*)$') or ''
  local pfx = word:lower()
  local seen = {}
  local out = {}
  local function add(label, kind, detail, doc)
    local key = label:lower() .. ':' .. kind
    if seen[key] then return end
    if pfx ~= '' and label:lower():sub(1, #pfx) ~= pfx then return end
    seen[key] = true
    table.insert(out, item(label, kind, detail, doc))
  end

  for _, name in ipairs(intrinsics.object_names()) do
    add(name, KIND_MODULE, 'objeto intrínseco ASP')
  end
  for _, group in ipairs({ 'functions', 'constants', 'keywords' }) do
    if not obj_name and (group ~= 'keywords' or #pfx >= 2) then
      for _, entry in ipairs(native.groups[group]) do
        local info = native.lookup(type(entry) == 'table' and entry[1] or entry)
        add(info.name, group == 'functions' and 3 or (group == 'constants' and 21 or 14),
          info.signature or info.value, info.doc)
      end
    end
  end
  for _, e in ipairs(require('asp.symbols').help(bufnr).entries) do
    add(e.name, SYM_TO_COMPL[e.kind] or 6, nil)
  end
  local ok, graph = pcall(require('asp.includes').buffer_graph, bufnr)
  if ok then
    for _, file in ipairs(graph.order) do
      for _, e in ipairs(require('asp.symbols').collect_file(file)) do
        if not e.scope_id and not e.class_id then
          add(e.name, SYM_TO_COMPL[e.kind] or 6, nil)
        end
      end
    end
  end
  return out
end

return M
