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
        .. 'references, workspace/symbol, hover, completion, diagnósticos de includes)'
    )
  end

  health.ok('diagnósticos de includes activos (namespace asp_includes)')
end

return M
