local M = {}
local ts = require('asp.ts')

-- Un If de una línea seguido de un If de bloque: sin el scanner externo
-- de la gramática (un parser.c compilado sin scanner.c o anterior a él),
-- el primero se traga el End If del segundo y quedan anidados.
local SCANNER_PROBE = 'If a Then b = 1\nIf c Then\n  d = 2\nEnd If\n'

---¿El parser vbscript cargado distingue el If de bloque del de una línea?
---@return boolean
local function has_scanner()
  local ok, ifs = pcall(function()
    local root = vim.treesitter.get_string_parser(SCANNER_PROBE, 'vbscript'):parse()[1]:root()
    local count = 0
    for child in root:iter_children() do
      if child:type() == 'if_statement' then count = count + 1 end
    end
    return not root:has_error() and count
  end)
  return ok and ifs == 2
end

---Queries del plugin para `lang` que no compilan con el parser cargado
---(otro parser con el mismo nombre trae otros nodos).
---@param lang string
---@return string[] errores "nombre: mensaje"
local function query_errors(lang)
  local names, out = {}, {}
  for _, file in ipairs(vim.api.nvim_get_runtime_file('queries/' .. lang .. '/*.scm', true)) do
    names[vim.fn.fnamemodify(file, ':t:r')] = true
  end
  local sorted = vim.tbl_keys(names)
  table.sort(sorted)
  for _, name in ipairs(sorted) do
    local ok, err = pcall(vim.treesitter.query.get, lang, name)
    if not ok then out[#out + 1] = ('%s: %s'):format(name, tostring(err)) end
  end
  return out
end

function M.check()
  local health = vim.health

  health.start('asp.nvim')

  local v = vim.version()
  if vim.fn.has('nvim-0.10') == 1 then
    health.ok(('Neovim >= 0.10 (%d.%d.%d)'):format(v.major, v.minor, v.patch))
  else
    health.error('asp.nvim requiere Neovim >= 0.10')
  end

  local function check_parser(lang, report, install_advice, detail)
    local added, err = ts.add(lang)
    if added then
      health.ok(('parser %s encontrado%s'):format(lang, detail or ''))
      return true
    end
    err = tostring(err)
    if err:lower():find('no parser for', 1, true) then
      report(('parser %s no encontrado'):format(lang), { install_advice })
      return false
    end
    local advice = {}
    if err:find('ABI version mismatch', 1, true) then
      advice[1] = 'Neovim 0.10 solo carga ABI 13–14: instalalo con nvim-treesitter rama `master`, '
        .. 'o compilá con `tree-sitter generate --abi 14`; o pasá a Neovim 0.11+'
    end
    report(('parser %s instalado pero no carga: %s'):format(lang, err), advice)
    return false
  end

  local own = {
    'Ejecutá `make parsers` en el directorio del plugin: compila src/parser.c y src/scanner.c.',
    'Otro plugin o instalador puede traer un parser con el mismo nombre. Para ver las copias: '
      .. "`:lua vim.print(vim.api.nvim_get_runtime_file('parser/vbscript.*', true))`",
  }
  for _, lang in ipairs({ 'aspclassic', 'vbscript' }) do
    if check_parser(lang, health.error, 'Ejecuta `make parsers` en el directorio del plugin.') then
      local copies = vim.api.nvim_get_runtime_file('parser/' .. lang .. '.*', true)
      if #copies > 1 then
        health.warn(('hay %d parsers %s en runtimepath; Neovim carga el primero: %s'):format(
          #copies, lang, copies[1]), { (own[2]:gsub('vbscript', lang)) })
      end
      local errors = query_errors(lang)
      if #errors > 0 then
        health.error(('las queries de %s no compilan con el parser cargado: %s'):format(
          lang, table.concat(errors, '; ')), own)
      end
    end
  end
  if ts.add('vbscript') then
    if has_scanner() then
      health.ok('parser vbscript con su scanner externo: distingue el If de bloque del de una línea')
    else
      health.error('el parser vbscript no distingue el If de bloque del de una línea: '
        .. 'le falta el scanner externo o es de otra gramática', own)
    end
  end

  check_parser('html', health.error, 'Instálalo con nvim-treesitter (`:TSInstall html`).',
    ' (regiones HTML; ubica los <script> y atributos on* de la capa JavaScript)')
  check_parser('javascript', health.warn,
    'Instálalo con nvim-treesitter (`:TSInstall javascript`) para resaltar el JavaScript '
      .. 'del cliente y tener su navegación y su ayuda en los <script>.',
    ' (resaltado, navegación, rename y ayuda en <script>, on*, <script src> e includes)')
  check_parser('css', health.warn,
    'Instálalo con nvim-treesitter (`:TSInstall css`) para resaltar el CSS del cliente.',
    ' (resaltado dentro de <style>)')

  M.check_server(health)
  M.check_layout(health)
end

---Servidor asp-ls: si está adjunto, sus métodos y los diagnósticos con su
---severidad.
function M.check_server(health)
  health = health or vim.health
  health.start('asp.nvim: servidor asp-ls')
  local methods = {}
  for method in pairs(require('asp.lsp').handlers) do
    methods[#methods + 1] = (method:gsub('^textDocument/', ''))
  end
  table.sort(methods)
  local list = table.concat(methods, ', ')
  local asp_clients = vim.lsp.get_clients({ name = 'asp-ls' })
  if #asp_clients > 0 then
    local info = asp_clients[1].server_info or {}
    health.ok(('asp-ls %s activo (%d cliente(s)): %s'):format(info.version or '', #asp_clients, list))
  else
    health.info('asp-ls se adjunta al abrir un .asp o .inc y responde ' .. list)
  end

  local ok, cfg = pcall(require('asp.diagnostics').config)
  if not ok then
    health.warn('no se pudo leer la configuración de diagnósticos: ' .. tostring(cfg))
    return
  end
  local families, names = {}, vim.tbl_keys(cfg)
  table.sort(names)
  for _, family in ipairs(names) do
    if cfg[family] then
      families[#families + 1] = family .. ' ' .. vim.diagnostic.severity[cfg[family]]
    end
  end
  if #families == 0 then
    health.info('diagnósticos apagados (setup({ diagnostics = false }))')
  else
    health.ok('diagnósticos (namespace asp_includes): ' .. table.concat(families, ', '))
  end
end

---Ventana con un buffer asp: la actual, la del buffer alterno (la que
---había antes de :checkhealth) o la primera que lo muestre.
---@return integer|nil win
local function asp_window()
  local function is_asp(buf) return buf > 0 and vim.bo[buf].filetype == 'asp' end
  local win = vim.api.nvim_get_current_win()
  if is_asp(vim.api.nvim_win_get_buf(win)) then return win end
  local alt = vim.fn.bufnr('#')
  if is_asp(alt) then
    local wins = vim.fn.win_findbuf(alt)
    if #wins > 0 then return wins[1] end
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if is_asp(vim.api.nvim_win_get_buf(w)) then return w end
  end
end

---Plegado e indentación del buffer asp actual, y HtmlIndent.
function M.check_layout(health)
  health = health or vim.health
  health.start('asp.nvim: plegado e indentación')
  if require('asp.indent').html_available() then
    health.ok('HtmlIndent() disponible (indent/html.vim): indenta las líneas HTML')
  else
    health.warn('HtmlIndent() no disponible: las líneas HTML conservan la indentación de la anterior',
      { 'Revisá que $VIMRUNTIME/indent/html.vim exista.' })
  end

  local win = asp_window()
  if not win then
    health.info('abrí un .asp para ver si el plegado y la indentación están activos')
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t')
  if name == '' then name = ('buffer %d'):format(buf) end

  if vim.wo[win].foldexpr == 'v:lua.vim.treesitter.foldexpr()' then
    if vim.wo[win].foldmethod == 'expr' then
      health.ok(('plegado por tree-sitter activo en %s'):format(name))
    else
      health.info(('foldexpr de tree-sitter fijado en %s, pero foldmethod=%s'):format(name, vim.wo[win].foldmethod),
        { 'Activalo con `:setlocal foldmethod=expr` (o en un autocmd FileType asp).' })
    end
  else
    health.info(('foldexpr de %s no es el de asp.nvim: %s'):format(name, vim.wo[win].foldexpr),
      { 'asp.nvim no lo fija con `setup({ folds = false })`.' })
  end

  if vim.bo[buf].indentexpr:find('asp.indent', 1, true) then
    health.ok(('indentexpr de asp.nvim activo en %s'):format(name))
  else
    health.info(('indentexpr de %s no es el de asp.nvim: %s'):format(name, vim.bo[buf].indentexpr),
      { 'asp.nvim no lo fija con `setup({ indent = false })`.' })
  end
end

return M
