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

// Consume `word` (en minúsculas) sin distinguir mayúsculas. Devuelve true
// si la palabra está completa y no sigue otro carácter de identificador.
// La palabra empieza en la posición actual, que puede ser el inicio de un
// rango; un inicio de rango más adelante la corta.
static bool match_word(TSLexer *lexer, const char *word) {
  for (const char *p = word; *p; p++) {
    if (lexer->eof(lexer) || (p != word && lexer->is_at_included_range_start(lexer))
        || lower(lexer->lookahead) != *p) {
      return false;
    }
    lexer->advance(lexer, false);
  }
  return at_boundary(lexer) || !is_word_char(lexer->lookahead);
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
      // comentario, es un extra.
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
    // `obj.Rem` es un miembro: tras el punto no hay blancos y no vale
    // ningún otro token externo.
    if (rem && !newline && !blank && !continued && !recovering
        && !valid_symbols[WITH_DOT] && !valid_symbols[MEMBER_DOT] && !valid_symbols[BLOCK_THEN]) {
      rem = false;
    }
    // Otra palabra: no hay punto ni comentario.
    if (!rem) code = true;
  }

  if (!recovering && valid_symbols[BLOCK_THEN]
      && (eof || newline || c == '\'' || rem)) {
    lexer->result_symbol = BLOCK_THEN;
    return true;
  }

  if (code) return false;

  if (rem || c == '\'') {
    if (!rem) lexer->advance(lexer, false);
    lexer->result_symbol = COMMENT;
    return comment_rest(lexer);
  }

  if (eof) return false;

  if (!recovering && valid_symbols[INLINE_ELSE] && !newline && (c == 'e' || c == 'E')) {
    if (!match_word(lexer, "else")) return false;
    lexer->result_symbol = INLINE_ELSE;
    return true;
  }

  if (c == '.') {
    bool with_first = newline || (blank && !continued);
    bool member = recovering || valid_symbols[MEMBER_DOT];
    bool with = recovering || valid_symbols[WITH_DOT];
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
