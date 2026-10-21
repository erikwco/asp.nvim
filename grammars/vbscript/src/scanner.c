// Scanner externo de tree-sitter-vbscript (asp.nvim). GPL-3.0, como el
// resto de grammars/vbscript; ver NOTICE.md.
//
// Los saltos de línea son extras en esta gramática, así que el `Then` no
// alcanza para distinguir un If de bloque (`If x Then` + salto de línea ...
// `End If`) de uno de una línea (`If x Then y = 1`). Sin esa distinción, un
// If de una línea seguido de un If de bloque se parseaba como un If de
// bloque que se apropiaba del `End If` ajeno.
//
// BLOCK_THEN es un token de ancho cero que sólo se emite tras el `Then` de
// un If de bloque: cuando en la misma línea sólo quedan blancos y después
// fin de línea, un comentario, un `:` o el fin del bloque `<% %>` (el inicio
// del siguiente rango incluido en la inyección combinada de asp.nvim).

#include "tree_sitter/parser.h"

enum TokenType {
  BLOCK_THEN,
  ERROR_SENTINEL,
};

void *tree_sitter_vbscript_external_scanner_create(void) { return NULL; }

void tree_sitter_vbscript_external_scanner_destroy(void *payload) { (void)payload; }

unsigned tree_sitter_vbscript_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}

void tree_sitter_vbscript_external_scanner_deserialize(void *payload, const char *buffer,
                                                       unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

bool tree_sitter_vbscript_external_scanner_scan(void *payload, TSLexer *lexer,
                                               const bool *valid_symbols) {
  (void)payload;
  // En la recuperación de errores todos los símbolos son válidos: no emitir.
  if (valid_symbols[ERROR_SENTINEL] || !valid_symbols[BLOCK_THEN]) return false;

  lexer->result_symbol = BLOCK_THEN;
  lexer->mark_end(lexer);
  for (;;) {
    if (lexer->eof(lexer) || lexer->is_at_included_range_start(lexer)) return true;
    int32_t c = lexer->lookahead;
    if (c == ' ' || c == '\t') {
      lexer->advance(lexer, true);
      continue;
    }
    return c == '\n' || c == '\r' || c == '\'' || c == ':';
  }
}
