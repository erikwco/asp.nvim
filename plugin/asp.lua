if vim.g.loaded_asp_nvim then
  return
end
vim.g.loaded_asp_nvim = true

vim.treesitter.language.register('aspclassic', 'asp')

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'asp',
  group = vim.api.nvim_create_augroup('asp_nvim', { clear = true }),
  callback = function(args)
    -- pcall: si el parser no está compilado aún, no romper la apertura
    -- del buffer; :checkhealth asp (Task 6) diagnostica el motivo.
    pcall(vim.treesitter.start, args.buf, 'aspclassic')

    -- vim.treesitter.foldexpr() sólo pliega las capas inyectadas que ya
    -- están parseadas: la vbscript se parsea antes del primer plegado.
    if require('asp').options.folds ~= false then
      pcall(require('asp.ts').parse_vbscript, args.buf)
    end

    pcall(function()
      require('asp.lsp').start(args.buf)
    end)

    -- Diagnósticos: al abrir (diferido), al guardar (abajo) y con espera
    -- tras cada edición (asp.diagnostics.attach).
    pcall(function()
      require('asp.diagnostics').attach(args.buf)
    end)
    vim.schedule(function()
      pcall(function()
        require('asp.diagnostics').refresh(args.buf)
      end)
    end)
  end,
})

-- Patrones case-insensitive (IIS no distingue mayúsculas). *.js: los `.js`
-- de <script src> que lee asp.js desde disco; .htm/.html: fuentes del
-- barrido de usos de página (asp.pages); .css: destino de los diagnósticos
-- de páginas inexistentes.
vim.api.nvim_create_autocmd('BufWritePost', {
  pattern = {
    '*.[aA][sS][pP]', '*.[iI][nN][cC]', '*.[hH][tT][mM]',
    '*.[hH][tT][mM][lL]', '*.[jJ][sS]', '*.[cC][sS][sS]',
  },
  group = vim.api.nvim_create_augroup('asp_nvim_writes', { clear = true }),
  callback = function(args)
    pcall(function()
      local path = vim.api.nvim_buf_get_name(args.buf)
      require('asp.pages').invalidate(path)
      require('asp.symbols').invalidate(path)
      require('asp.js').invalidate(path)
      require('asp.includes').invalidate(path)
      local diagnostics = require('asp.diagnostics')
      if vim.bo[args.buf].filetype == 'asp' then
        diagnostics.refresh(args.buf)
      end
      -- El archivo guardado puede ser un include, o el destino de un
      -- enlace, de otra página abierta.
      for _, buf in ipairs(diagnostics.affected(path, args.buf)) do
        diagnostics.schedule(buf)
      end
    end)
  end,
})
