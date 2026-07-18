module.exports = grammar({
  name: 'aspclassic',

  extras: () => [],

  rules: {
    template: $ => repeat(choice(
      $.include_directive,
      $.page_directive,
      $.output_directive,
      $.code_directive,
      $.content,
    )),

    code_directive: $ => seq('<%', optional($.code), '%>'),

    output_directive: $ => seq('<%=', optional($.code), '%>'),

    page_directive: $ => seq(
      '<%@',
      optional(alias($.code, $.directive_attributes)),
      '%>',
    ),

    include_directive: $ => seq(
      '<!--#include',
      /\s+/,
      field('kind', alias(choice('file', 'virtual'), $.include_kind)),
      optional(/\s+/),
      '=',
      optional(/\s+/),
      field('path', $.quoted_path),
      optional(/\s+/),
      '-->',
    ),

    quoted_path: () => token(choice(/"[^"]*"/, /'[^']*'/)),

    // Todo lo que hay dentro de <% ... %>: cualquier char salvo un
    // '%' seguido de '>'.
    code: () => token(prec(-1, repeat1(choice(/[^%]+/, /%[^>]/)))),

    // Todo lo que hay fuera de los bloques. El '<' suelto cubre los
    // '<' de HTML que no abren un bloque ASP; el lexer prefiere los
    // tokens más largos ('<%', '<%=', '<%@') cuando aplican.
    content: () => token(prec(-1, /([^<]+|<[^%!]|<!([^-]|-[^-]|--[^#]|--#[^i]))+/)),
  },
});
