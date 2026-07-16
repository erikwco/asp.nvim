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
  for _, lang in ipairs({ 'aspclassic', 'vba' }) do
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

  for _, lang in ipairs({ 'javascript', 'css' }) do
    local ok, added = pcall(vim.treesitter.language.add, lang)
    if ok and added then
      health.ok(('parser %s encontrado (resaltado dentro de <script>/<style>)'):format(lang))
    else
      health.warn(
        ('parser %s no encontrado'):format(lang),
        { 'Instálalo con nvim-treesitter (`:TSInstall ' .. lang .. '`) para resaltar el JavaScript/CSS del cliente.' }
      )
    end
  end
end

return M
