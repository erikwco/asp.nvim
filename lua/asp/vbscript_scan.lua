local M = {}

---Columna (0-indexada) donde empieza un comentario `Rem` en `line`, o nil.
local function rem_col(line)
  local init = 1
  while true do
    local s, e = line:find('[Rr][Ee][Mm]', init)
    if not s then return nil end
    local before = line:sub(1, s - 1)
    local word = before:match('([%a_][%w_]*)%s*$')
    local branch = word and (word:lower() == 'then' or word:lower() == 'else')
    if not line:sub(s - 1, s - 1):match('[%w_]')
      and not line:sub(e + 1, e + 1):match('[%w_]')
      and (branch or before:match('^%s*$') or before:match(':%s*$') or before:match('<%%%s*$')) then
      return s - 1
    end
    init = e + 1
  end
end

---Normaliza Rem antes de parsear VBScript en buffers e includes, sin
---cambiar la cantidad de bytes ni las posiciones del texto original.
---@param content string
---@return string
function M.source(content)
  return (content:gsub('[^\n]+', function(line)
    local col = line:find('[Rr][Ee][Mm]') and rem_col(line)
    if col then return line:sub(1, col) .. "'" .. line:sub(col + 2) end
  end))
end

-- Recorrido de un árbol VBScript en una sola query para los diagnósticos
-- (asp.diagnostics): usos de identificadores con su contexto, las
-- declaraciones que asp.symbols no recoge (ReDim, variable de For),
-- Option Explicit y el primer Eval/Execute/ExecuteGlobal.
--
-- Como en asp.symbols, los scopes se siguen por posición: iter_captures
-- entrega los nodos por byte de inicio, así que cada identificador cae en
-- el último Sub/Function/Property (o Class) abierto que todavía no terminó.
-- Subir con node:parent() desde cada identificador cuesta mucho más.

-- Patrones de contexto:
--   @use    identificador como valor (incluye el de más a la izquierda de
--           una cadena obj.a.b: los miembros son hijos directos de
--           member_expression y no entran en ningún patrón).
--   @call   nombre de `nombre(args)`: llamada o índice de un arreglo.
--   @stmt   identificador suelto como statement. Si además empieza la
--           sentencia (lo decide asp.diagnostics mirando el texto), es una
--           llamada sin paréntesis: `MiSub a, b`, `Call MiSub`, `Then MiSub`.
--   @decl   ReDim y variable de For/For Each.
local USES = [[
[(sub_statement) (function_statement) (property_statement)] @scope
(class_statement) @class
(option_statement) @option
(primary_expression (identifier) @use)
(function_call . (identifier) @call)
(mid_statement (identifier) @use)
(label_statement (identifier) @stmt)
(source_file (expression (primary_expression (identifier) @stmt)))
(block (expression (primary_expression (identifier) @stmt)))
(if_statement (expression (primary_expression (identifier) @stmt)))
(call_statement (expression (primary_expression (identifier) @stmt)))
(for_statement . (identifier) @decl)
(for_each_statement . (identifier) @decl)
(redim_statement (expression (primary_expression (identifier) @decl)))
(redim_statement (expression (function_call . (identifier) @decl)))
]]

-- Candidatos a Eval o Execute de un include (ver M.facts).
local DYNAMIC_USES = [[
(primary_expression (identifier) @use)
(function_call . (identifier) @call)
]]

local DYNAMIC = { eval = true, execute = true, executeglobal = true }

---Recorre `roots` con `query_text`. `text_of(node)` da el texto de un
---nodo (ver M.buffer y M.facts) y `want_uses` decide si se guardan los
---usos o solo los indicios.
local function walk(roots, source, query_text, text_of, want_uses, out)
  local query = vim.treesitter.query.parse('vbscript', query_text)
  for _, root in ipairs(roots) do
    -- Pilas de scopes y clases abiertos: su id y el byte donde terminan.
    local scopes, scope_stops, classes, class_stops = {}, {}, {}, {}
    local last
    for id, node in query:iter_captures(root, source) do
      local cap = query.captures[id]
      local r0, c0, start = node:start()
      while scope_stops[1] and scope_stops[#scope_stops] <= start do
        scopes[#scopes], scope_stops[#scope_stops] = nil, nil
      end
      while class_stops[1] and class_stops[#class_stops] <= start do
        classes[#classes], class_stops[#class_stops] = nil, nil
      end
      if cap == 'scope' then
        local _, _, stop = node:end_()
        scopes[#scopes + 1], scope_stops[#scope_stops + 1] = node:id(), stop
      elseif cap == 'class' then
        local _, _, stop = node:end_()
        classes[#classes + 1], class_stops[#class_stops + 1] = node:id(), stop
      elseif cap == 'option' then
        if text_of(node):lower():find('explicit', 1, true) then out.option_explicit = true end
      else
        -- Varios patrones pueden capturar el mismo identificador; llegan
        -- seguidos porque ningún otro nodo capturado empieza en su byte.
        local rec = last
        if not (rec and rec.start == start) then
          local name = text_of(node)
          -- Un "identificador" que no es un nombre (ver asp.symbols.is_name)
          -- se descarta.
          if not name:match('^[%a_][%w_]*$') then
            rec = nil
          else
            local _, c1 = node:end_()
            rec = {
              start = start, name = name, lower = name:lower(),
              lnum = r0, col = c0, end_col = c1,
              scope_id = scopes[#scopes], class_id = classes[#classes],
            }
            if want_uses then out.uses[#out.uses + 1] = rec end
          end
          last = rec
        end
        if rec then
          if cap == 'decl' then
            table.insert(out.decls, rec)
          else
            rec[cap] = true
            if not out.dynamic and DYNAMIC[rec.lower] then
              out.dynamic = { name = rec.name, lnum = rec.lnum, col = rec.col }
            end
          end
        end
      end
    end
  end
  return out
end

local function empty()
  return { option_explicit = false, dynamic = nil, decls = {}, uses = {} }
end

---Usos e indicios del árbol VBScript de un buffer, parseado desde
---`content` (sus líneas unidas por saltos de línea). El texto de cada
---identificador sale de `lines`, más barato que cortarlo del contenido.
---@param roots TSNode[]
---@param content string
---@param lines string[]
---@return table { option_explicit, dynamic?, decls, uses }
function M.buffer(roots, content, lines)
  local function text_of(node)
    local r0, c0, r1, c1 = node:range()
    if r0 == r1 then return (lines[r0 + 1] or ''):sub(c0 + 1, c1) end
    return vim.treesitter.get_node_text(node, content)
  end
  return walk(roots, content, USES, text_of, true, empty())
end

---Indicios de un archivo de disco ya parseado (lo llama asp.symbols en el
---mismo parseo que sus declaraciones): Option Explicit y primer
---Eval/Execute/ExecuteGlobal. Se calculan en cada parseo en frío de un
---include (también para workspace/symbol y las referencias de sitio), así
---que evitan recorrer el árbol: VBScript exige que Option Explicit sea la
---primera sentencia y la query de Eval/Execute corre solo si el texto los
---menciona.
---@param vroot TSNode
---@param content string
---@return table { option_explicit, dynamic? }
function M.facts(vroot, content)
  local function text_of(node)
    local _, _, s = node:start()
    local _, _, e = node:end_()
    return content:sub(s + 1, e)
  end
  local out = { option_explicit = false }
  for child in vroot:iter_children() do
    if child:type() ~= 'comment' then
      out.option_explicit = child:type() == 'option_statement'
        and text_of(child):lower():find('explicit', 1, true) ~= nil
      break
    end
  end
  local lower = content:lower()
  if lower:find('eval', 1, true) or lower:find('execute', 1, true) then
    out.dynamic = walk({ vroot }, content, DYNAMIC_USES, text_of, false, empty()).dynamic
  end
  return out
end

return M
