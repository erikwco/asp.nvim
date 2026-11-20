// Scanner externo de tree-sitter-vbscript (asp.nvim). GPL-3.0, como el
// resto de grammars/vbscript; ver NOTICE.md.
//
// Los saltos de línea son extras en esta gramática, así que la gramática
// sola no sabe dónde termina una línea. El scanner decide los tokens que
// dependen de eso, mirando lo que hay entre el token anterior y el
// siguiente:
//
// - BLOCK_THEN (ancho cero) marca el Then de un If de bloque: tras el
//   `Then` sólo quedan blancos y después fin de línea, un comentario, un
//   `:` o el fin del bloque `<% %>`.
// - INLINE_ELSE (ancho cero) va antes del `Else` de un If de una línea,
//   que tiene que estar en esa misma línea. INLINE_COLON es un `:` de
//   esa línea seguido de otra sentencia: también es del If.
// - INLINE_END (ancho cero) va antes del `End If` que cierra un If de una
//   línea en esa misma línea (`If a Then b = 1 Else c = 2 : End If`). El
//   `:` anterior es un extra. En otra línea, el `End If` es del If de
//   bloque que lo contiene.
// - INLINE_EOL (ancho cero) cierra el If de una línea donde termina su
//   línea, igual que BLOCK_THEN: fin de línea, comentario o fin del bloque
//   `<% %>`. Sin él, el `Else` o el `End If` que siguen a un `<%` se leían
//   en la misma línea: el `<%` es un extra y el escaneo siguiente empieza
//   después, sin ver el límite. También acota las sentencias yuxtapuestas
//   del If (`Response.Write "x"`) a su línea.
// - ARGS_OPEN es el `(` de la lista de parámetros de Sub, Function y
//   Property, en la línea del nombre. Sin él, el procedimiento no tiene
//   paréntesis y el `(` es el de la primera sentencia del cuerpo.
// - MEMBER_DOT y WITH_DOT son el `.` de `obj.Campo` y el `.Campo` inicial
//   de un With. Un `.` pegado al token anterior es un acceso; tras un salto
//   de línea, un `:`, el límite de un bloque `<% %>` o un blanco empieza
//   una expresión (`Response.Write .Campo`). Tras una continuación ` _`
//   sigue siendo un acceso.
// - COMMENT: `'` o `Rem` hasta el fin de línea, el `%>` del bloque o el
//   fin del rango incluido. Con la expresión regular de antes, un
//   comentario sin salto de línea antes del `%>` seguía en el bloque
//   siguiente de la inyección combinada.
//
// En la inyección combinada de asp.nvim cada rango incluido es un bloque
// entero, con sus `<%`, `<%=` y `%>`; is_at_included_range_start cubre
// además los rangos que sólo tienen el código.

#include "tree_sitter/parser.h"

enum TokenType {
  BLOCK_THEN,
  INLINE_ELSE,
  INLINE_COLON,
  INLINE_END,
  INLINE_EOL,
  ARGS_OPEN,
  MEMBER_DOT,
  WITH_DOT,
  COMMENT,
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

static bool at_boundary(TSLexer *lexer) {
  return lexer->eof(lexer) || lexer->is_at_included_range_start(lexer);
}

static bool is_word_char(int32_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

static int32_t lower(int32_t c) { return (c >= 'A' && c <= 'Z') ? c - 'A' + 'a' : c; }

// Consume `rest` (en minúsculas), el resto de una palabra ya empezada, sin
// distinguir mayúsculas. Devuelve true si la palabra está completa y no
// sigue otro carácter de identificador. Un inicio de rango la corta.
static bool match_rest(TSLexer *lexer, const char *rest) {
  for (const char *p = rest; *p; p++) {
    if (at_boundary(lexer) || lower(lexer->lookahead) != *p) return false;
    lexer->advance(lexer, false);
  }
  return at_boundary(lexer) || !is_word_char(lexer->lookahead);
}

// Como match_rest, para una palabra que empieza en la posición actual,
// que puede ser el inicio de un rango.
static bool match_word(TSLexer *lexer, const char *word) {
  if (lexer->eof(lexer) || lower(lexer->lookahead) != word[0]) return false;
  lexer->advance(lexer, false);
  return match_rest(lexer, word + 1);
}

// Tras la `e` inicial: el resto de `End If`, las dos palabras en la misma
// línea y en el mismo rango.
static bool match_end_if_rest(TSLexer *lexer) {
  if (!match_rest(lexer, "nd")) return false;
  while (!at_boundary(lexer) && (lexer->lookahead == ' ' || lexer->lookahead == '\t')) {
    lexer->advance(lexer, false);
  }
  return !at_boundary(lexer) && match_word(lexer, "if");
}

// Resto de un comentario: hasta el fin de línea, el `%>` del bloque o el
// fin del rango. Marca el final después de cada carácter que le pertenece.
static bool comment_rest(TSLexer *lexer) {
  for (;;) {
    lexer->mark_end(lexer);
    if (at_boundary(lexer)) return true;
    int32_t c = lexer->lookahead;
    if (c == '\n' || c == '\r') return true;
    lexer->advance(lexer, false);
    if (c == '%' && !at_boundary(lexer) && lexer->lookahead == '>') return true;
  }
}

bool tree_sitter_vbscript_external_scanner_scan(void *payload, TSLexer *lexer,
                                               const bool *valid_symbols) {
  (void)payload;
  // En la recuperación de errores todos los símbolos son válidos: sólo se
  // reconocen los comentarios y los puntos, que no dependen del contexto.
  bool recovering = valid_symbols[ERROR_SENTINEL];

  // Los tokens de ancho cero terminan donde empieza el escaneo.
  lexer->mark_end(lexer);

  // Lo que separa del token anterior. `newline`: fin de línea, `:` o
  // límite de bloque; `blank`: espacios o tabs; `continued`: ` _`.
  // `code`: lo que sigue es código que no lee el scanner (un `_` que no
  // termina la línea, `<` o `%` sueltos, una palabra que no es Rem).
  bool newline = false, blank = false, continued = false, code = false;
  for (;;) {
    if (lexer->is_at_included_range_start(lexer)) newline = true;
    if (lexer->eof(lexer)) break;
    int32_t c = lexer->lookahead;
    if (c == ' ' || c == '\t') {
      blank = true;
      lexer->advance(lexer, true);
    } else if (c == ':' && !newline && !recovering && valid_symbols[INLINE_COLON]) {
      // Un `:` al final de la línea o del bloque, o antes de un
      // comentario o del `End If` del If de una línea, es un extra.
      lexer->advance(lexer, false);
      lexer->mark_end(lexer);
      while (!at_boundary(lexer) && (lexer->lookahead == ' ' || lexer->lookahead == '\t')) {
        lexer->advance(lexer, false);
      }
      if (at_boundary(lexer)) return false;
      int32_t next = lexer->lookahead;
      if (next == '\n' || next == '\r' || next == '\'' || next == ':') return false;
      if (next == '%') {
        lexer->advance(lexer, false);
        if (!at_boundary(lexer) && lexer->lookahead == '>') return false;
      } else if ((next == 'r' || next == 'R') && match_word(lexer, "rem")) {
        return false;
      } else if (next == 'e' || next == 'E') {
        lexer->advance(lexer, false);
        if (match_end_if_rest(lexer)) return false;
      }
      lexer->result_symbol = INLINE_COLON;
      return true;
    } else if (c == '\n' || c == '\r' || c == ':') {
      newline = true;
      lexer->advance(lexer, true);
    } else if (c == '_') {
      lexer->advance(lexer, true);
      while (!at_boundary(lexer) && (lexer->lookahead == ' ' || lexer->lookahead == '\t')) {
        lexer->advance(lexer, true);
      }
      if (!at_boundary(lexer) && lexer->lookahead == '\r') lexer->advance(lexer, true);
      // Un `_` que no termina la línea es parte de un identificador.
      if (at_boundary(lexer) || lexer->lookahead != '\n') {
        code = true;
        break;
      }
      lexer->advance(lexer, true);
      continued = true;
    } else if (c == '%') {
      lexer->advance(lexer, true);
      if (at_boundary(lexer) || lexer->lookahead != '>') {
        code = true;
        break;
      }
      lexer->advance(lexer, true);
      newline = true;
    } else if (c == '<') {
      lexer->advance(lexer, true);
      if (at_boundary(lexer) || lexer->lookahead != '%') {
        code = true;
        break;
      }
      lexer->advance(lexer, true);
      if (!at_boundary(lexer) && lexer->lookahead == '=') lexer->advance(lexer, true);
      newline = true;
    } else {
      break;
    }
  }

  bool eof = !code && lexer->eof(lexer);
  int32_t c = (eof || code) ? 0 : lexer->lookahead;

  // `Rem` sólo se mira una vez: consume la palabra.
  bool rem = false;
  if (c == 'r' || c == 'R') {
    rem = match_word(lexer, "rem");
    // Tras el punto se espera el nombre del miembro, también con blancos
    // o una continuación de línea antes de `Rem`.
    if (rem && !recovering
        && !valid_symbols[WITH_DOT] && !valid_symbols[MEMBER_DOT] && !valid_symbols[BLOCK_THEN]) {
      rem = false;
    }
    // Otra palabra: no hay punto ni comentario.
    if (!rem) code = true;
  }

  bool line_end = eof || newline || c == '\'' || rem;

  if (!recovering && valid_symbols[BLOCK_THEN] && line_end) {
    lexer->result_symbol = BLOCK_THEN;
    return true;
  }

  if (!recovering && valid_symbols[INLINE_EOL] && line_end) {
    lexer->result_symbol = INLINE_EOL;
    return true;
  }

  if (code) return false;

  if (valid_symbols[COMMENT] && (rem || c == '\'')) {
    if (!rem) lexer->advance(lexer, false);
    lexer->result_symbol = COMMENT;
    return comment_rest(lexer);
  }

  if (eof) return false;

  // `Else` y `End If` empiezan igual y la palabra sólo se lee una vez.
  if (!recovering && !newline && (c == 'e' || c == 'E')
      && (valid_symbols[INLINE_ELSE] || valid_symbols[INLINE_END])) {
    lexer->advance(lexer, false);
    int32_t second = at_boundary(lexer) ? 0 : lower(lexer->lookahead);
    if (second == 'l' && valid_symbols[INLINE_ELSE] && match_rest(lexer, "lse")) {
      lexer->result_symbol = INLINE_ELSE;
      return true;
    }
    if (second == 'n' && valid_symbols[INLINE_END] && match_end_if_rest(lexer)) {
      lexer->result_symbol = INLINE_END;
      return true;
    }
    return false;
  }

  if (c == '.') {
    bool with_first = newline || (blank && !continued);
    bool member = valid_symbols[MEMBER_DOT];
    bool with = valid_symbols[WITH_DOT];
    if (!member && !with) return false;
    lexer->advance(lexer, false);
    // `.5` es un número: lo lee el lexer interno.
    if (!at_boundary(lexer) && lexer->lookahead >= '0' && lexer->lookahead <= '9') return false;
    lexer->mark_end(lexer);
    lexer->result_symbol = (with && (with_first || !member)) ? WITH_DOT : MEMBER_DOT;
    return true;
  }

  if (!recovering && valid_symbols[ARGS_OPEN] && c == '(' && !newline) {
    lexer->advance(lexer, false);
    lexer->mark_end(lexer);
    lexer->result_symbol = ARGS_OPEN;
    return true;
  }

  return false;
}
