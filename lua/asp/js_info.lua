local M = {}

local FUNCTIONS = {
  function_declaration = true, generator_function_declaration = true,
  function_expression = true, generator_function = true,
  arrow_function = true, method_definition = true,
}

-- Default o rest que envuelve directamente al nombre de un parámetro.
local WRAPPERS = { assignment_pattern = 'left', object_assignment_pattern = 'left', rest_pattern = true }

---`(parámetro) alfa = 1`: el nombre con su default o su `...`, en una
---línea. Los nombres de un patrón (`{ a, b } = {}`) muestran solo el suyo.
local function parameter(entry, source)
  local node, parent = entry.decl, entry.decl:parent()
  local field = parent and WRAPPERS[parent:type()]
  if field == true or (field and parent:field(field)[1] and parent:field(field)[1]:equal(node)) then
    node = parent
  end
  local text = vim.treesitter.get_node_text(node, source):gsub('%s*\n%s*', ' ')
  return { name = entry.name, kind = 6, detail = '(parámetro) ' .. text }
end

-- Se extrae antes de detach: la caché de disco conserva texto y offsets,
-- sin retener los árboles ni necesitar otra lectura para mostrar ayuda.
function M.declaration(entry, source)
  if entry.parameter then return parameter(entry, source) end
  local decl, fn = entry.decl, entry.decl
  local kind = ({ [5] = 7, [6] = 2, [12] = 3 })[entry.kind] or 6
  if decl:type() == 'variable_declarator' then
    local name = decl:field('name')[1]
    fn = name and name:type() == 'identifier' and decl:field('value')[1] or nil
    if fn and FUNCTIONS[fn:type()] then kind = 3 end
  end
  local callable = fn and FUNCTIONS[fn:type()]
  local start = select(3, decl:start())
  local stop = select(3, decl:end_())
  local prefix = ''
  if decl:type() == 'variable_declarator' then
    prefix = vim.treesitter.get_node_text(decl:parent():child(0), source) .. ' '
  end
  local body = (callable or kind == 7) and fn:field('body')[1]
  if body then stop = select(3, body:start()) end
  local header = prefix .. source:sub(start + 1, stop)
  local detail = vim.trim(header:match('^[^\n]*'))
  if callable and fn:type() == 'arrow_function' then detail = detail .. ' ...' end
  local info = { name = entry.name, kind = kind, detail = detail }
  if callable then
    -- La firma completa mantiene los parámetros multilínea y los patrones;
    -- detail conserva la primera línea que se muestra en hover/completion.
    info.signature = vim.trim(header)
    info.parameters = {}
    local params = fn:field('parameters')[1]
    local single = fn:field('parameter')[1]
    local function add(node)
      if node:type() == 'comment' then return end
      local sb, eb = select(3, node:start()), select(3, node:end_())
      info.parameters[#info.parameters + 1] = { label = { #prefix + sb - start, #prefix + eb - start } }
    end
    if params then
      for node in params:iter_children() do if node:named() then add(node) end end
    elseif single then
      add(single)
    end
  end
  return info
end

function M.markdown(info)
  local value = ('```javascript\n%s\n```'):format(info.detail)
  if info.doc then value = value .. '\n\n' .. info.doc end
  if info.file then value = value .. '\n\nArchivo: `' .. vim.fn.fnamemodify(info.file, ':t') .. '`.' end
  return value
end

return M
