local M = {}
local ts = require('asp.ts')

function M.check()
  local health = vim.health

  health.start('asp.nvim')

  if vim.fn.has('nvim-0.10') == 1 then
    health.ok('Neovim >= 0.10')
  else
    health.error('asp.nvim requiere Neovim >= 0.10')
  end

  local function check_parser(lang, report, install_advice, detail)
    local added, err = ts.add(lang)
    if added then
      health.ok(('parser %s encontrado%s'):format(lang, detail or ''))
      return
    end
    err = tostring(err)
    if err:lower():find('no parser for', 1, true) then
      report(('parser %s no encontrado'):format(lang), { install_advice })
      return
    end
    local advice = {}
    if err:find('ABI version mismatch', 1, true) then
      advice[1] = 'Neovim 0.10 solo carga ABI 13–14: instalalo con nvim-treesitter rama `master`, '
        .. 'o compilá con `tree-sitter generate --abi 14`; o pasá a Neovim 0.11+'
    end
    report(('parser %s instalado pero no carga: %s'):format(lang, err), advice)
  end

  for _, lang in ipairs({ 'aspclassic', 'vbscript' }) do
    check_parser(lang, health.error, 'Ejecuta `make parsers` en el directorio del plugin.')
  end

  check_parser('html', health.error, 'Instálalo con nvim-treesitter (`:TSInstall html`).')
  check_parser('javascript', health.warn,
    'Instálalo con nvim-treesitter (`:TSInstall javascript`) para resaltar el JavaScript '
      .. 'del cliente y navegar sus definiciones/referencias en los <script>.',
    ' (resaltado y definición/referencias en <script>, <script src> e includes)')
  check_parser('css', health.warn,
    'Instálalo con nvim-treesitter (`:TSInstall css`) para resaltar el CSS del cliente.',
    ' (resaltado dentro de <style>)')

  local asp_clients = vim.lsp.get_clients({ name = 'asp-ls' })
  if #asp_clients > 0 then
    health.ok(('asp-ls activo (%d cliente(s))'):format(#asp_clients))
  else
    health.info(
      'asp-ls se adjunta al abrir un archivo .asp (documentSymbol, definition, '
        .. 'references, documentHighlight, workspace/symbol, hover, completion, diagnósticos de includes)'
    )
  end

  health.ok('diagnósticos de includes activos (namespace asp_includes)')

  M.check_layout(health)
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
