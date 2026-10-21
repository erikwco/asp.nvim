-- Indentación de páginas ASP (indentexpr). El VBScript de los bloques
-- <% %> se indenta por la profundidad de sus bloques en el árbol de
-- tree-sitter; el HTML, por el indent/html.vim de Neovim (HtmlIndent),
-- más los bloques VBScript que lo envuelven (`<% If x Then %>` ...
-- `<% End If %>`). Donde la capa vbscript tiene un ERROR (código a medio
-- escribir), la indentación sale del texto de la línea anterior.
local M = {}

local api = vim.api

-- Posiciones normalizadas: fila y columna relativa a la indentación de la
-- fila, en un solo número comparable. Así no cambian cuando `=` reindenta
-- las filas ya procesadas y el árbol se edita sin volver a parsear.
local ROW = 2 ^ 24

local function pos(row, ncol)
  return row * ROW + math.min(ncol, ROW - 1)
end

local function getline(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
end

local function lead(text)
  return (text:find('%S') or #text + 1) - 1
end

local QUERY = [[
[
  (sub_statement) (function_statement) (property_statement)
  (class_statement) (for_statement) (for_each_statement)
  (while_statement) (do_statement) (with_statement)
] @block
(if_statement "End") @block
(select_case_statement) @select
["Else" "ElseIf"] @branch
(ERROR) @error
]]

local CLOSERS = { End = true, Next = true, Loop = true, Wend = true }

local query, verbatim_query
local function blocks_query()
  if query == nil then
    local ok, parsed = pcall(vim.treesitter.query.parse, 'vbscript', QUERY)
    query = ok and parsed or false
  end
  return query or nil
end

---Palabra de cierre de un bloque (End, Next, Loop o Wend).
---@param node TSNode
---@return TSNode|nil
local function closer(node)
  for i = node:child_count() - 1, 0, -1 do
    local child = node:child(i)
    if CLOSERS[child:type()] and not child:missing() then return child end
  end
end

---@class asp.IndentState
---@field tick integer
---@field parser vim.treesitter.LanguageTree
---@field opens number[] inicio de cada bloque, ordenados
---@field closes number[] palabra de cierre de cada bloque, ordenados
---@field branches table<number, true> Else y ElseIf
---@field errors number[][] rangos de los ERROR de la capa vbscript
---@field rows table<integer, asp.IndentRow>
---@field verbatim table<integer, integer> filas de pre/textarea → fila de su apertura
---@field html_lnum integer? última línea que indentó HtmlIndent sin ajuste

---@class asp.IndentRow
---@field kind 'code'|'close'|'html'
---@field open integer? fila del `<%` (líneas de código y `%>`)
---@field key number posición cuya profundidad vale para la línea

-- Por buffer, válido mientras no cambie b:changedtick. Neovim no lo
-- incrementa hasta terminar un `=`, así que `gg=G` usa un solo estado.
---@type table<integer, asp.IndentState>
local states = {}

api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
  group = api.nvim_create_augroup('asp_indent', { clear = true }),
  callback = function(args) states[args.buf] = nil end,
})

---@param buf integer
---@param tick integer
---@return asp.IndentState|nil
local function build(buf, tick)
  local parser, vbscript = require('asp.ts').parse_vbscript(buf)
  if not parser then return nil end
  local st = { tick = tick, parser = parser, opens = {}, closes = {}, branches = {}, errors = {}, rows = {}, verbatim = {} }
  local html = parser:children().html
  if html and vim.fn.search('\\c<\\%(textarea\\|pre\\)\\>', 'nw') > 0 then
    verbatim_query = verbatim_query or vim.treesitter.query.parse('html', '(start_tag (tag_name) @name)')
    html:parse()
    for _, tree in ipairs(html:trees()) do
      for _, tag in verbatim_query:iter_captures(tree:root(), buf) do
        local name = vim.treesitter.get_node_text(tag, buf):lower()
        if name == 'pre' or name == 'textarea' then
          local node = tag:parent()
          local first = node:end_()
          local element = node:parent()
          local last = element:named_child(element:named_child_count() - 1)
          local stop = element:type() == 'element' and last:type() == 'end_tag'
            and last:start() or api.nvim_buf_line_count(buf) - 1
          for row = first + 1, stop do st.verbatim[row] = node:start() end
        end
      end
    end
  end
  local q = vbscript and blocks_query()
  if not q then return st end

  local lines = {}
  local function at(row, col)
    local text = lines[row]
    if not text then
      text = getline(buf, row)
      lines[row] = text
    end
    return pos(row, col - lead(text))
  end
  local function start(node)
    local row, col = node:start()
    return at(row, col)
  end
  local function add(from, to)
    st.opens[#st.opens + 1] = from
    st.closes[#st.closes + 1] = to
  end

  for _, tree in ipairs(vbscript:trees()) do
    for id, node in q:iter_captures(tree:root(), buf) do
      local name = q.captures[id]
      if name == 'block' then
        local close = closer(node)
        if close then add(start(node), start(close)) end
      elseif name == 'select' then
        local close = closer(node)
        if close then
          add(start(node), start(close))
          -- Cada Case abre un nivel más hasta el Case siguiente o el End.
          -- Los comentarios de una rama quedan como hijos del Select.
          local from
          for i = 2, node:child_count() - 1 do
            local child = node:child(i)
            local kind = child:type()
            local next_child = node:child(i + 1)
            if kind == 'case_clause' or child:equal(close)
              or (kind == 'Case' and next_child and next_child:type() == 'Else') then
              if from then add(from, start(child)) end
              if child:equal(close) then break end
              from = start(child)
            end
          end
        end
      elseif name == 'branch' then
        st.branches[start(node)] = true
      else
        local sr, sc, er, ec = node:range()
        st.errors[#st.errors + 1] = { at(sr, sc), at(er, ec) }
      end
    end
  end
  table.sort(st.opens)
  table.sort(st.closes)
  return st
end

---@param buf integer
---@return asp.IndentState|nil
local function state(buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local st = states[buf]
  if st and st.tick == tick then return st end
  st = build(buf, tick)
  states[buf] = st
  return st
end

---Cantidad de elementos de `list` (ordenada) menores que `x`, o menores
---o iguales si `inclusive`.
local function count(list, x, inclusive)
  local lo, hi = 1, #list
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if list[mid] < x or (inclusive and list[mid] == x) then lo = mid + 1 else hi = mid - 1 end
  end
  return lo - 1
end

---Bloques abiertos en `key`: los que empezaron antes y cierran después
---(la línea de su End/Next/Loop/Wend ya no cuenta), menos uno en Else y
---ElseIf.
local function depth(st, key)
  local d = count(st.opens, key, false) - count(st.closes, key, true)
  if st.branches[key] then d = d - 1 end
  return math.max(d, 0)
end

local function in_error(st, key)
  for _, range in ipairs(st.errors) do
    if range[1] <= key and key <= range[2] then return true end
  end
  return false
end

---Primer token de código del bloque que abre en `row` (salteando las
---líneas que sólo tienen un comentario), o el final de su `<%`.
local function first_code_key(buf, directive, row)
  for child in directive:iter_children() do
    if child:type() == 'code' then
      local sr, sc, er, ec = child:range()
      for r = sr, er do
        local text = getline(buf, r)
        local from = r == sr and sc or 0
        local to = r == er and ec or #text
        local s = text:find('%S', from + 1)
        if s and s <= to then
          local rest = text:sub(s, to)
          if not (rest:find("^'") or rest:lower():find('^rem%f[^%w_]')) then
            return pos(r, s - 1 - lead(text))
          end
        end
      end
    end
  end
  return pos(row, 2)
end

---Qué es la línea `row` y desde qué posición se mide su profundidad.
---@return asp.IndentRow
local function row_info(st, buf, row)
  local info = st.rows[row]
  if info then return info end
  local text = getline(buf, row)
  local first = text:find('%S')
  local col = first and first - 1 or 0
  info = { kind = 'html', key = pos(row, 0) }
  local tree = st.parser:trees()[1]
  local node = tree and tree:root():descendant_for_range(row, col, row, col + 1)
  local directive = node
  while directive and directive:parent() and directive:parent():type() ~= 'template' do
    directive = directive:parent()
  end
  local dtype = directive and directive:type()
  if node and (dtype == 'code_directive' or dtype == 'output_directive') then
    local dsr = directive:start()
    local ntype = node:type()
    if dsr < row and ntype == 'code' then
      info = { kind = 'code', open = dsr, key = info.key }
    elseif dsr < row and first and ntype == '%>' then
      info = { kind = 'close', open = dsr, key = info.key }
    elseif first and dsr == row and (ntype == '<%' or ntype == '<%=') then
      info.key = first_code_key(buf, directive, row)
    end
  end
  st.rows[row] = info
  return info
end

-- Texto VBScript de una línea, sin strings ni comentarios.
local function code_of(text)
  text = text:gsub('^%s*<%%=?', ''):gsub('%%>.*', ''):gsub('"[^"]*"', '""')
  local quote = text:find("'", 1, true)
  if quote then text = text:sub(1, quote - 1) end
  text = vim.trim(text)
  if text:lower():find('^rem%f[^%w_]') then return '' end
  return text
end

local function continues(text)
  local code = code_of(text)
  return code:find('%s_$') ~= nil or code == '_'
end

local MODIFIERS = { public = true, private = true, friend = true, static = true, default = true }

local OPENERS = {
  '^if%f[^%w_].*%f[%w_]then$', '^elseif%f[^%w_].*%f[%w_]then$', '^else$',
  '^case%f[^%w_]', '^select%s+case%f[^%w_]', '^class%f[^%w_]', '^with%f[^%w_]',
  '^for%f[^%w_]', '^do%f[^%w_]', '^while%f[^%w_]',
  '^sub%f[^%w_]', '^function%f[^%w_]', '^property%f[^%w_]',
}

local CLOSING = {
  '^end%f[^%w_]', '^else%f[^%w_]', '^elseif%f[^%w_]', '^case%f[^%w_]',
  '^next%f[^%w_]', '^loop%f[^%w_]', '^wend%f[^%w_]',
}

local function matches(text, patterns)
  for _, pattern in ipairs(patterns) do
    if text:find(pattern) then return true end
  end
  return false
end

---¿La línea abre un bloque? Por texto, para el respaldo.
local function opens(code)
  code = code:lower()
  for _ = 1, 2 do
    code = code:gsub('^(%a+)%s+', function(word) if MODIFIERS[word] then return '' end end)
  end
  -- `For ... : Next` y compañía abren y cierran en la misma línea.
  if code:find(':%s*end%f[^%w_]') or code:find(':%s*next%f[^%w_]')
    or code:find(':%s*loop%f[^%w_]') or code:find(':%s*wend%f[^%w_]') then
    return false
  end
  return matches(code, OPENERS)
end

---Niveles a sumar por texto: uno si la línea anterior abre un bloque,
---menos uno si la actual lo cierra o reabre (End Select cierra dos: el
---Case y el Select).
local function text_delta(prev_code, code)
  local p, c = prev_code:lower(), code:lower()
  local d = opens(prev_code) and 1 or 0
  local after_select = p:find('^select%s+case%f[^%w_]') ~= nil
  if c:find('^end%s+select%f[^%w_]') then
    d = d - (after_select and 1 or 2)
  elseif matches(c, CLOSING) and not (after_select and c:find('^case%f[^%w_]')) then
    d = d - 1
  end
  return d
end

local html_loaded
---Carga indent/html.vim en un buffer auxiliar para definir HtmlIndent()
---sin que fije su indentexpr en el buffer ASP.
local function load_html()
  if html_loaded == nil then
    if vim.fn.exists('*HtmlIndent') == 0 then
      local scratch = api.nvim_create_buf(false, true)
      pcall(api.nvim_buf_call, scratch, function() vim.cmd.runtime('indent/html.vim') end)
      pcall(api.nvim_buf_delete, scratch, { force = true })
    end
    html_loaded = vim.fn.exists('*HtmlIndent') == 1
  end
  return html_loaded
end

---¿Está disponible HtmlIndent()? Lo usa :checkhealth asp.
function M.html_available()
  return load_html()
end

---Indentación HTML de la línea `lnum` (v:lnum): HtmlIndent() o, si no
---está, la de la línea anterior no vacía.
---@return integer indent
---@return boolean from_html
local function html_indent(st, buf, lnum)
  if load_html() then
    local hi = vim.b[buf].hi_indent
    if hi == nil then
      pcall(vim.fn.HtmlIndent_CheckUserSettings)
      vim.b[buf].hi_indent = { lnum = -1 }
    elseif st and st.html_lnum and hi.lnum == st.html_lnum and st.html_lnum == vim.fn.prevnonblank(lnum - 1) then
      -- HtmlIndent sigue desde el estado de la línea anterior sólo si
      -- b:changedtick avanzó uno desde entonces, pero Neovim no lo
      -- incrementa durante `=`: sin esto, `gg=G` recalcula el estado
      -- desde el texto en cada línea y crece cuadrático.
      vim.b[buf].hi_lasttick = st.tick - 1
    end
    local ok, ind = pcall(vim.fn.HtmlIndent)
    if ok and type(ind) == 'number' then return ind, true end
  end
  local prev = vim.fn.prevnonblank(lnum - 1)
  return prev > 0 and vim.fn.indent(prev) or 0, false
end

local function html_depth(st, buf, row)
  local col = lead(getline(buf, row))
  local html = st.parser:children().html
  local tree = html:trees()[1]
  local node = tree:root():named_descendant_for_range(row, col, row, col + 1)
  local d = 0
  while node do
    local open = node:named_child(0)
    if open and open:type() == 'start_tag' and open:start() < row then
      local tag = open:named_child(0)
      local name = vim.treesitter.get_node_text(tag, buf):lower()
      if name == 'script' or name == 'style' then return nil end
      if vim.fn.HtmlIndent_IsOpenTag(name) == 1 then d = d + 1 end
    end
    node = node:parent()
  end
  return d
end

---@param buf integer
---@param lnum integer
---@return integer
local function compute(buf, lnum)
  local st = state(buf)
  if not st then return (html_indent(nil, buf, lnum)) end
  local row = lnum - 1
  if st.verbatim[row] then return -1 end
  local sw = vim.fn.shiftwidth()
  local info = row_info(st, buf, row)

  if info.kind == 'close' then return vim.fn.indent(info.open + 1) end

  local prev = vim.fn.prevnonblank(lnum - 1)
  local prev_info = prev > 0 and row_info(st, buf, prev - 1) or nil
  local fallback = in_error(st, info.key) or (prev_info ~= nil and in_error(st, prev_info.key))

  if info.kind == 'code' then
    -- Continuación con ` _`: un nivel más que la primera línea de la
    -- sentencia.
    if continues(getline(buf, row - 1)) then
      local first = row - 1
      while first > info.open and continues(getline(buf, first - 1)) do first = first - 1 end
      return vim.fn.indent(first + 1) + sw
    end
    if fallback then
      if not prev_info then return 0 end
      local d = text_delta(code_of(getline(buf, prev - 1)), code_of(getline(buf, row)))
      return math.max(vim.fn.indent(prev) + d * sw, 0)
    end
    local open = row_info(st, buf, info.open)
    return vim.fn.indent(info.open + 1) + sw * math.max(depth(st, info.key) - depth(st, open.key), 0)
  end

  -- HTML: si la línea anterior es VBScript, se mide desde su `<%`; si es
  -- HTML, desde lo que diga HtmlIndent. Una etiqueta de cierre siempre se
  -- alinea con su apertura, que HtmlIndent busca por nombre.
  local base, from_html = html_indent(st, buf, lnum)
  if base < 0 then
    st.html_lnum = nil
    return base
  end
  local base_key
  local closing_tag = prev_info and prev_info.kind ~= 'html' and getline(buf, row):find('^%s*</') ~= nil
  local verbatim_open = prev > 0 and st.verbatim[prev - 1]
  local after_verbatim = verbatim_open and from_html and not getline(buf, row):find('^%s*</')
    and html_depth(st, buf, row)
  if after_verbatim then
    -- Los espacios antes del cierre de pre/textarea son contenido literal.
    base = vim.fn.indent(verbatim_open + 1) + sw * (after_verbatim - html_depth(st, buf, verbatim_open))
    base_key = row_info(st, buf, verbatim_open).key
    from_html = false
  elseif not prev_info or prev_info.kind == 'html' or closing_tag then
    base_key = closing_tag and info.key or prev_info and prev_info.key
  else
    base = vim.fn.indent(prev_info.open + 1)
    base_key = row_info(st, buf, prev_info.open).key
    from_html = false
  end

  local delta
  if closing_tag then
    delta = 0
  elseif fallback then
    -- Sólo cuenta el VBScript: una línea de código, o el bloque <% %> con
    -- que empieza una línea HTML.
    local function code_at(r, kind)
      local text = getline(buf, r)
      if kind == 'code' or (kind == 'html' and text:find('^%s*<%%')) then return code_of(text) end
      return ''
    end
    delta = text_delta(prev_info and code_at(prev - 1, prev_info.kind) or '', code_at(row, 'html'))
  else
    delta = depth(st, info.key) - (base_key and depth(st, base_key) or 0)
  end
  -- HtmlIndent guarda la base de la línea siguiente a partir de su propio
  -- resultado; si le sumamos niveles, que la recalcule desde el texto.
  st.html_lnum = nil
  if from_html then
    if delta == 0 then
      st.html_lnum = lnum
    else
      vim.b[buf].hi_indent = { lnum = -1 }
    end
  end
  return math.max(base + delta * sw, 0)
end

---indentexpr de los buffers asp (ver ftplugin/asp.lua). Nunca lanza: si
---algo falla, devuelve -1 y Neovim conserva la indentación.
---@return integer
function M.indentexpr()
  local ok, result = pcall(compute, api.nvim_get_current_buf(), vim.v.lnum)
  if ok and type(result) == 'number' then return result end
  return -1
end

return M
