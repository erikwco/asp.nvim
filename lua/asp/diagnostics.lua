local M = {}

-- Un solo namespace para todas las familias (su nombre viene de cuando
-- solo había diagnósticos de includes).
M.ns = vim.api.nvim_create_namespace('asp_includes')

-- Espera del refresco tras editar (TextChanged/InsertLeave), en ms.
M.debounce_ms = 500

-- Familias y severidad por defecto. La de sintaxis es HINT porque la
-- gramática vbscript marca como error construcciones válidas comunes
-- (`x Is Nothing`, `Case 1, 2`, `Const A = 1, B = 2`, `.Campo` dentro de
-- un With): ver la sección de diagnósticos de :help asp.
local DEFAULTS = {
  includes = 'WARN',
  syntax = 'HINT',
  undeclared = 'WARN',
  unknown_call = 'WARN',
  missing_page = 'WARN',
}

local warned = {}

local function warn_once(key, msg)
  if warned[key] then return end
  warned[key] = true
  vim.notify('asp.nvim: ' .. msg, vim.log.levels.WARN)
end

---Severidad de cada familia según `setup({ diagnostics = ... })`: un
---entero de vim.diagnostic.severity, o false si la familia está apagada.
---Un valor inválido avisa una sola vez y usa el de por defecto.
---@return table<string, integer|false>
function M.config()
  local opts = require('asp').options.diagnostics
  local out = {}
  if opts == false then
    for key in pairs(DEFAULTS) do out[key] = false end
    return out
  end
  if opts ~= nil and type(opts) ~= 'table' then
    warn_once('diagnostics', ('diagnostics debe ser una tabla o false, no %s'):format(vim.inspect(opts)))
    opts = {}
  end
  opts = opts or {}
  for key in pairs(opts) do
    if DEFAULTS[key] == nil then
      local known = vim.tbl_keys(DEFAULTS)
      table.sort(known)
      warn_once('key:' .. tostring(key), ('diagnostics.%s no es una familia conocida (%s)'):format(
        tostring(key), table.concat(known, ', ')))
    end
  end
  local severity = vim.diagnostic.severity
  for key, default in pairs(DEFAULTS) do
    local value, sev = opts[key], nil
    if value == nil or value == true then
      sev = severity[default]
    elseif value == false then
      sev = false
    elseif type(value) == 'number' and type(severity[value]) == 'string' then
      sev = severity[severity[value]]
    elseif type(value) == 'string' and type(severity[value:upper()]) == 'number' then
      sev = severity[value:upper()]
    end
    if sev == nil then
      warn_once(('value:%s:%s'):format(key, vim.inspect(value)), ([[diagnostics.%s = %s no es válido ]]
        .. [[(ERROR, WARN, INFO, HINT, un entero de vim.diagnostic.severity o false); se usa %s]]):format(
        key, vim.inspect(value), default))
      sev = severity[default]
    end
    out[key] = sev
  end
  return out
end

-- Regiones de código de la plantilla y la directiva de página.
local TEMPLATE_QUERY = [[
(code) @code
(page_directive) @page
]]

---Árbol VBScript del buffer sin tocar sus capas HTML ni JS: la capa top
---(aspclassic) del propio buffer da las regiones `(code)` y un parser
---string de vbscript parsea solo esas, en una región combinada como la
---injection. `parse(true)` sobre el buffer parsearía también HTML, JS, CSS
---y regex.
---@param bufnr integer
---@param content string
---@return table|nil { root, code: integer[][], jscript: boolean, parser }
local function vbscript_tree(bufnr, content)
  local parser = vim.treesitter.get_parser(bufnr, 'aspclassic')
  if not parser then return nil end
  local troot = parser:parse()[1]:root()
  local query = vim.treesitter.query.parse('aspclassic', TEMPLATE_QUERY)
  -- `code` guarda el rango de cada bloque ({fila, col, byte} de inicio y
  -- de fin): set_included_regions convierte en rangos los nodos que recibe.
  local nodes, code, jscript = {}, {}, false
  for id, node in query:iter_captures(troot, bufnr) do
    if query.captures[id] == 'code' then
      table.insert(nodes, node)
      table.insert(code, { node:range(true) })
    else
      local lang = vim.treesitter.get_node_text(node, bufnr):lower():match('language%s*=%s*["\']?%s*(%a+)')
      if lang and lang ~= 'vbscript' then jscript = true end
    end
  end
  if #nodes == 0 then return nil end
  local vparser = vim.treesitter.get_string_parser(content, 'vbscript')
  vparser:set_included_regions({ nodes })
  return { root = vparser:parse(true)[1]:root(), code = code, jscript = jscript, parser = vparser }
end

---Nodos ERROR y MISSING más externos del árbol, en orden.
---@param root TSNode
---@return TSNode[]
local function syntax_errors(root)
  local out = {}
  local function visit(node)
    if node:type() == 'ERROR' or node:missing() then
      table.insert(out, node)
      return
    end
    if not node:has_error() then return end
    for child in node:iter_children() do visit(child) end
  end
  visit(root)
  return out
end

---Columna (0-indexada) donde empieza un comentario `Rem` en `line`, o nil.
local function rem_col(line)
  local init = 1
  while true do
    local s, e = line:find('[Rr][Ee][Mm]', init)
    if not s then return nil end
    local before = line:sub(1, s - 1)
    if not line:sub(e + 1, e + 1):match('[%w_]')
      and (before:match('^%s*$') or before:match(':%s*$') or before:match('<%%%s*$')) then
      return s - 1
    end
    init = e + 1
  end
end

---Texto que parsea la capa VBScript: el del buffer con cada comentario
---`Rem` escrito como `'` del mismo largo (`Rem x` → `'em x`). La gramática
---no conoce `Rem`: lo lee como código y el texto libre que sigue puede
---arrastrar al error las declaraciones de las líneas siguientes. Las
---posiciones no cambian.
---@param lines string[]
---@return string
local function vbscript_source(lines)
  local out
  for i, line in ipairs(lines) do
    local col = line:find('[Rr][Ee][Mm]') and rem_col(line)
    if col then
      out = out or vim.list_slice(lines)
      out[i] = line:sub(1, col) .. "'" .. line:sub(col + 2)
    end
  end
  return table.concat(out or lines, '\n')
end

-- Contexto de un refresh: lo que comparten las familias, calculado una vez.
local function context(bufnr)
  local ctx = { bufnr = bufnr }
  ctx.lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  ctx.content = table.concat(ctx.lines, '\n')
  ctx.vcontent = vbscript_source(ctx.lines)
  return ctx
end

local function graph_of(ctx)
  if ctx.graph == nil then
    local ok, g = pcall(require('asp.includes').buffer_graph, ctx.bufnr)
    ctx.graph = ok and g or false
  end
  return ctx.graph or nil
end

local function tree_of(ctx)
  if ctx.tree == nil then
    local ok, tree = pcall(vbscript_tree, ctx.bufnr, ctx.vcontent)
    ctx.tree = ok and tree or false
    if ctx.tree then ctx.errors = syntax_errors(ctx.tree.root) end
  end
  return ctx.tree or nil
end

local function diag(family, severity, lnum, col, end_lnum, end_col, message)
  return {
    lnum = lnum, col = col, end_lnum = end_lnum, end_col = end_col,
    severity = severity, source = 'asp-ls', code = family, message = message,
  }
end

---Familia includes: directivas que no resuelven y ciclos del grafo.
local function includes_family(ctx, severity)
  local g = graph_of(ctx)
  if not g then return {} end
  local out = {}
  for _, u in ipairs(g.unresolved) do
    table.insert(out, diag('includes', severity, u.lnum, u.col, u.lnum, u.end_col,
      ('include %s="%s" no resuelve a ningún archivo'):format(u.kind, u.text)))
  end
  for _, c in ipairs(g.cycles) do
    table.insert(out, diag('includes', severity, 0, 0, 0, 0,
      ('ciclo de includes detectado: %s vuelve a incluir %s'):format(
        vim.fs.basename(c.from), vim.fs.basename(c.to))))
  end
  return out
end

---Familia syntax: un diagnóstico por nodo ERROR o MISSING más externo de
---la capa VBScript, recortado al bloque `<% %>` donde empieza (un nodo de
---la región combinada puede cruzar HTML hasta el bloque siguiente).
local function syntax_family(ctx, severity)
  local tree = tree_of(ctx)
  if not tree or tree.jscript then return {} end
  local out = {}
  local region = 1
  for _, node in ipairs(ctx.errors) do
    local r0, c0, sb = node:start()
    local r1, c1, eb = node:end_()
    while tree.code[region + 1] and tree.code[region + 1][3] <= sb do
      region = region + 1
    end
    local code = tree.code[region]
    if eb > code[6] then r1, c1 = code[4], code[5] end
    local message = 'error de sintaxis de VBScript'
    if node:missing() then
      message = ('error de sintaxis de VBScript: falta "%s"'):format(node:type())
    end
    table.insert(out, diag('syntax', severity, r0, c0, r1, c1, message))
  end
  return out
end

---¿El identificador de `use` empieza una sentencia? Entonces es una
---llamada sin paréntesis (`MiSub a, b`). Se decide por el texto previo en
---su línea: el árbol no separa `MiSub a` de dos expresiones sueltas.
local function starts_statement(lines, use)
  local before = lines[use.lnum + 1]:sub(1, use.col)
  if before:find('<%%=%s*$') then return false end
  if before:find('<%%%s*$') or before:find(':%s*$') then return true end
  local word = before:match('([%a_][%w_]*)%s*$')
  if word then
    word = word:lower()
    return word == 'then' or word == 'else' or word == 'call'
  end
  if not before:find('^%s*$') then return false end
  -- Al principio de la línea, salvo que la anterior continúe con ` _`.
  local prev = use.lnum > 0 and lines[use.lnum] or ''
  return not (prev:find('%s_%s*$') or prev:find('^_%s*$'))
end

---La directiva include del buffer por la que entra `file` al grafo: los
---archivos de cada directiva de primer nivel ocupan un tramo contiguo del
---orden DFS de buffer_graph.
local function directive_for(bufnr, order, file)
  local tops = {}
  for _, item in ipairs(require('asp.includes').includes_of(nil, bufnr)) do
    if item.resolved and not tops[item.resolved] then tops[item.resolved] = item end
  end
  local current
  for _, f in ipairs(order) do
    current = tops[f] or current
    if f == file then return current end
  end
end

---Familias undeclared y unknown_call: usos de identificadores VBScript
---contra las declaraciones del buffer y de su grafo de includes.
---
---Solo con Option Explicit en la página o en su grafo. Sin él, asignar
---declara (`x = Array(1)` hace de `x(0)` un índice) y el archivo suele ser
---una librería que llama a lo que declaran los demás includes de la página
---que la incluye, invisibles desde ella.
local function vbscript_family(ctx, undeclared, unknown_call)
  local tree, g = tree_of(ctx), graph_of(ctx)
  if not tree or tree.jscript or not g then return {} end
  -- Con un include sin resolver faltan declaraciones: cualquier nombre
  -- podría venir de ahí. Ya lo marca la familia includes.
  if #g.unresolved > 0 then return {} end

  local symbols = require('asp.symbols')
  local scan = require('asp.vbscript_scan').buffer({ tree.root }, ctx.vcontent, ctx.lines)

  local option_explicit, dynamic = scan.option_explicit, scan.dynamic
  local facts = {}
  for i, file in ipairs(g.order) do
    facts[i] = symbols.file_facts(file)
    option_explicit = option_explicit or facts[i].option_explicit
    if not dynamic and facts[i].dynamic then
      dynamic = vim.tbl_extend('force', facts[i].dynamic, { file = file })
    end
  end
  if not option_explicit then return {} end

  if dynamic then
    local lnum, col, where = dynamic.lnum, dynamic.col, ''
    if dynamic.file then
      local item = directive_for(ctx.bufnr, g.order, dynamic.file)
      lnum, col = item and item.lnum or 0, item and item.col or 0
      where = (' en %s:%d'):format(vim.fs.basename(dynamic.file), dynamic.lnum + 1)
    end
    return { diag('dynamic', vim.diagnostic.severity.HINT, lnum, col, lnum, col,
      ('%s%s ejecuta código dinámico: no se revisan variables sin declarar ni llamadas inexistentes')
        :format(dynamic.name, where)) }
  end

  -- Declaraciones visibles: locales por scope, miembros por clase y nombres
  -- de página (buffer e includes), todos en minúsculas.
  local locals, members, page, classes = {}, {}, {}, {}
  local function declare(lower, scope_id, class_id)
    if scope_id then
      locals[scope_id] = locals[scope_id] or {}
      locals[scope_id][lower] = true
    elseif class_id then
      members[class_id] = members[class_id] or {}
      members[class_id][lower] = true
    else
      page[lower] = true
    end
  end
  for _, e in ipairs(symbols.collect_roots({ tree.root }, ctx.vcontent)) do
    local lower = e.name:lower()
    declare(lower, e.scope_id, e.class_id)
    if e.kind == 5 then classes[lower] = true end
  end
  for _, d in ipairs(scan.decls) do declare(d.lower, d.scope_id, d.class_id) end
  for _, file in ipairs(g.order) do
    for _, e in ipairs(symbols.collect_file(file)) do
      if not e.scope_id and not e.class_id then
        local lower = e.name:lower()
        page[lower] = true
        if e.kind == 5 then classes[lower] = true end
      end
    end
  end
  -- Un error de sintaxis puede tragarse una declaración (`Const A = 1,
  -- B = 2`): todo nombre de una línea que toca un error cuenta como
  -- declarado, para no reportar sus usos de más abajo. Por líneas y no por
  -- el texto del nodo porque la forma del ERROR cambia con la versión de
  -- tree-sitter de cada Neovim.
  local error_rows = {}
  for _, node in ipairs(ctx.errors) do
    local r0, _, r1 = node:range()
    for row = r0, r1 do error_rows[row] = true end
  end
  for row in pairs(error_rows) do
    for word in (ctx.lines[row + 1] or ''):gmatch('[%a_][%w_]*') do
      page[word:lower()] = true
    end
  end

  local builtins, intrinsics = require('asp.vbscript_builtins'), require('asp.intrinsics')
  local function known(use)
    local lower = use.lower
    return (use.scope_id and locals[use.scope_id] and locals[use.scope_id][lower])
      or (use.class_id and members[use.class_id] and members[use.class_id][lower])
      or page[lower] or builtins.lookup(lower) or intrinsics.object(lower)
  end

  local out = {}
  local errors, e = ctx.errors, 1
  for _, use in ipairs(scan.uses) do
    while errors[e] and select(3, errors[e]:end_()) <= use.start do e = e + 1 end
    local in_error = errors[e] and select(3, errors[e]:start()) <= use.start
    if (use.use or use.call or use.stmt) and not in_error then
      local line = ctx.lines[use.lnum + 1]
      local before = line:sub(1, use.col)
      local prev = before:match('([%a_][%w_]*)%s*$')
      -- `nombre(` es llamada o índice aunque el árbol diga otra cosa: la
      -- gramática lee `x = f(1) + g(2)` como `x = f` seguido de `(1) + g(2)`.
      local call = use.call or line:find('^%s*%(', use.end_col + 1) ~= nil
      if prev and prev:lower() == 'new' then
        -- `New` toma clases: una Function homónima no sirve.
        if unknown_call and not classes[use.lower] and not builtins.is_class(use.lower) then
          table.insert(out, diag('unknown_call', unknown_call, use.lnum, use.col, use.lnum, use.end_col,
            ('la clase "%s" no está declarada en la página ni en sus includes'):format(use.name)))
        end
      elseif call or (use.stmt and starts_statement(ctx.lines, use)) then
        if unknown_call and not known(use) then
          table.insert(out, diag('unknown_call', unknown_call, use.lnum, use.col, use.lnum, use.end_col,
            ('"%s" no es una Sub, Function ni variable de la página ni de sus includes'):format(use.name)))
        end
      elseif undeclared and not known(use) then
        table.insert(out, diag('undeclared', undeclared, use.lnum, use.col, use.lnum, use.end_col,
          ('variable "%s" sin declarar (Option Explicit)'):format(use.name)))
      end
    end
  end
  return out
end

-- Comentarios HTML (no las directivas `<!--#...`), en bytes 1-indexados.
-- Un `<!--` dentro de un <script> no comenta su JavaScript: es el viejo
-- `<script><!-- ... //--></script>` para navegadores sin JS.
local function html_comments(content)
  local lower = content:lower()
  local spans, init = {}, 1
  local script = lower:find('<script[%s>]')
  while true do
    local s = content:find('<!--', init, true)
    if not s then break end
    -- El próximo <script> se busca de nuevo solo cuando quedó atrás: cada
    -- búsqueda avanza desde `init` y el recorrido sigue siendo lineal.
    if script and script < init then script = lower:find('<script[%s>]', init) end
    if script and script < s then
      -- Hay un <script> antes: el `<!--` es suyo si está antes del cierre.
      local close = lower:find('</script', script, true)
      if not close then break end
      init = close
    else
      local _, e = content:find('-->', s + 4, true)
      if content:sub(s + 4, s + 4) ~= '#' then
        table.insert(spans, { s, e or #content })
      end
      if not e then break end
      init = e + 1
    end
  end
  return spans
end

---Familia missing_page: literales de páginas y recursos (asp.pages) cuyo
---destino no existe en disco.
local function missing_page_family(ctx, severity)
  local literals = require('asp.pages').buffer_literals(ctx.bufnr, ctx.lines)
  if #literals == 0 then return {} end

  -- Byte (1-indexado) donde empieza cada línea, para ubicar los literales
  -- en los comentarios.
  local starts, offset = {}, 1
  for i, line in ipairs(ctx.lines) do
    starts[i] = offset
    offset = offset + #line + 1
  end
  local comments = html_comments(ctx.content)
  local tree = tree_of(ctx)
  if tree then
    local query = vim.treesitter.query.parse('vbscript', '(comment) @c')
    for _, node in query:iter_captures(tree.root, ctx.content) do
      local _, _, sb = node:start()
      local _, _, eb = node:end_()
      table.insert(comments, { sb + 1, eb })
    end
  end
  local function commented(byte)
    for _, span in ipairs(comments) do
      if byte >= span[1] and byte <= span[2] then return true end
    end
    return false
  end

  local exists, out = {}, {}
  for _, lit in ipairs(literals) do
    local line = ctx.lines[lit.lnum + 1] or ''
    local text = line:sub(lit.col + 1, lit.end_col)
    local path = text:match('^[^?#]*')
    local stem = path:match('([^/\\]*)%.%w+%s*$')
    -- Rutas armadas en runtime (`<%= %>`, `"x" & y`, `'x' + y`), nombres
    -- sin base (`".asp"`) y comodines no son enlaces verificables.
    local dynamic = text:find('<%', 1, true) or text:find('%>', 1, true)
      or line:sub(1, lit.col - 1):find('[&+]%s*$') or line:sub(lit.end_col + 2):find('^%s*[&+]')
    if not dynamic and stem and stem:match('%S') and not path:find('*', 1, true)
      and not commented(starts[lit.lnum + 1] + lit.col) then
      if exists[lit.target_abs] == nil then
        local stat = vim.uv.fs_stat(lit.target_abs)
        exists[lit.target_abs] = stat ~= nil and stat.type == 'file'
      end
      if not exists[lit.target_abs] then
        local kind = path:lower():match('%.(%w+)%s*$')
        local what = (kind == 'js' or kind == 'css') and 'el archivo' or 'la página'
        table.insert(out, diag('missing_page', severity, lit.lnum, lit.col, lit.end_lnum, lit.end_col,
          ('%s "%s" no existe'):format(what, vim.trim(path))))
      end
    end
  end
  return out
end

-- Errores de la última corrida por familia (para depurar; refresh nunca
-- lanza).
M.last_errors = {}

---Calcula y publica los diagnósticos de `bufnr`. Nunca lanza: si una
---familia falla, se publican las demás.
---@param bufnr integer
function M.refresh(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local ok_cfg, cfg = pcall(M.config)
  if not ok_cfg then
    cfg = {}
    for key, default in pairs(DEFAULTS) do cfg[key] = vim.diagnostic.severity[default] end
  end
  M.last_errors = {}
  if not next(vim.tbl_filter(function(sev) return sev end, cfg)) then
    pcall(vim.diagnostic.reset, M.ns, bufnr)
    return
  end
  local diags = {}
  local ok_ctx, ctx = pcall(context, bufnr)
  if not ok_ctx then
    M.last_errors.context = ctx
    return
  end
  local function run(name, fn, ...)
    local ok, list = pcall(fn, ctx, ...)
    if ok then
      vim.list_extend(diags, list)
    else
      M.last_errors[name] = list
    end
  end
  if cfg.includes then run('includes', includes_family, cfg.includes) end
  if cfg.syntax then run('syntax', syntax_family, cfg.syntax) end
  if cfg.undeclared or cfg.unknown_call then
    run('vbscript', vbscript_family, cfg.undeclared, cfg.unknown_call)
  end
  if cfg.missing_page then run('missing_page', missing_page_family, cfg.missing_page) end
  pcall(vim.diagnostic.set, M.ns, bufnr, diags)
end

-- Timer pendiente de cada buffer (ver M.schedule).
local timers = {}

local function cancel(bufnr)
  local timer = timers[bufnr]
  if not timer then return end
  timers[bufnr] = nil
  timer:stop()
  if not timer:is_closing() then timer:close() end
end

---Programa un refresh de `bufnr` en M.debounce_ms; otra llamada antes de
---que venza reinicia la espera. El timer se cierra al disparar o al
---descargar el buffer.
---@param bufnr integer
function M.schedule(bufnr)
  local timer = timers[bufnr]
  if not timer then
    timer = assert(vim.uv.new_timer())
    timers[bufnr] = timer
  end
  timer:stop()
  timer:start(M.debounce_ms, 0, function()
    vim.schedule(function()
      -- Si se reprogramó mientras esperaba el loop, sigue vivo.
      if timers[bufnr] == timer and not timer:is_active() then cancel(bufnr) end
      M.refresh(bufnr)
    end)
  end)
end

---Cantidad de refrescos pendientes (para los tests).
---@return integer
function M.pending()
  return vim.tbl_count(timers)
end

---Refresca `bufnr` con espera tras cada edición (TextChanged e
---InsertLeave) y cancela lo pendiente al descargarlo. Idempotente.
---@param bufnr integer
function M.attach(bufnr)
  local group = vim.api.nvim_create_augroup('asp_diagnostics_' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    buffer = bufnr,
    callback = function() M.schedule(bufnr) end,
  })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      cancel(bufnr)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M
