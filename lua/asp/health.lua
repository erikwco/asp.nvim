local M = {}

function M.check()
  local health = vim.health

  health.start('asp.nvim')

  if vim.fn.has('nvim-0.10') == 1 then
    health.ok('Neovim >= 0.10')
  else
    health.error('asp.nvim requiere Neovim >= 0.10')
  end

  -- vim.treesitter.language.add() no lanza error si el parser no existe:
  -- devuelve `nil, mensaje` como valores de retorno normales. Un simple
  -- `pcall(...)` solo detecta excepciones Lua, así que su primer valor
  -- (`ok`) sería siempre `true` aquí y este chequeo jamás reportaría un
  -- parser faltante. Por eso miramos también el valor que `language.add`
  -- realmente retorna.
  for _, lang in ipairs({ 'aspclassic', 'vbscript' }) do
    local ok, added = pcall(vim.treesitter.language.add, lang)
    if ok and added then
      health.ok(('parser %s encontrado'):format(lang))
    else
      health.error(
        ('parser %s no encontrado'):format(lang),
        { 'Ejecuta `make parsers` en el directorio del plugin.' }
      )
    end
  end

  do
    -- html no se compila con `make parsers` (ese target solo produce los
    -- parsers propios del plugin); el usuario debe instalarlo con
    -- nvim-treesitter, igual que javascript/css.
    local ok, added = pcall(vim.treesitter.language.add, 'html')
    if ok and added then
      health.ok('parser html encontrado')
    else
      health.error(
        'parser html no encontrado',
        { 'Instálalo con nvim-treesitter (`:TSInstall html`).' }
      )
    end
  end

  do
    -- javascript alimenta además la capa de navegación JS (asp.js), que
    -- sin el parser devuelve nil en silencio: este warning es el único
    -- aviso de por qué definition/references no resuelven en <script>.
    local ok, added = pcall(vim.treesitter.language.add, 'javascript')
    if ok and added then
      health.ok('parser javascript encontrado (resaltado y definición/referencias en <script>, <script src> e includes)')
    else
      health.warn('parser javascript no encontrado', {
        'Instálalo con nvim-treesitter (`:TSInstall javascript`) para resaltar el JavaScript '
          .. 'del cliente y navegar sus definiciones/referencias en los <script>.',
      })
    end
  end

  do
    local ok, added = pcall(vim.treesitter.language.add, 'css')
    if ok and added then
      health.ok('parser css encontrado (resaltado dentro de <style>)')
    else
      health.warn(
        'parser css no encontrado',
        { 'Instálalo con nvim-treesitter (`:TSInstall css`) para resaltar el CSS del cliente.' }
      )
    end
  end

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
