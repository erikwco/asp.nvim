// tree-sitter-vbscript — fork of arrmee-wt/tree-sitter-vba (GPL-3.0)
// adapted for VBScript as used in Classic ASP. Changes from upstream are
// tracked in NOTICE.md (GPL v3 §5). This directory is GPL-3.0; the rest
// of the asp.nvim repository is MIT.

// tree-sitter-vba — Tree-sitter grammar for Visual Basic for Applications (VBA)
// Based on Microsoft VBA Language Specification (MS-VBAL)
// License: MIT
//
// This grammar is an independent implementation based on the publicly available
// Microsoft VBA language specification. It does not derive from any GPL-licensed
// ANTLR4 grammar or other third-party VBA parser implementation.

function ci(word) {
  return alias(new RegExp(word, 'i'), word);
}

module.exports = grammar({
  name: 'vbscript',

  extras: $ => [/\s/, $.comment, $._line_continuation, ':', $._block_delimiter],

  // src/scanner.c decide lo que depende de los fines de línea, que son
  // extras: el Then de un If de bloque (_block_then), el Else y los `:` de
  // uno de una línea (_inline_else, _inline_colon), el `(` de los
  // parámetros en la línea del nombre (_args_open), el `.` de un acceso o
  // el inicial de un With (_member_dot, _with_dot) y los comentarios, que
  // terminan también en el `%>` del bloque.
  externals: $ => [
    $._block_then, $._inline_else, $._inline_colon, $._args_open,
    $._member_dot, $._with_dot, $.comment, $._error_sentinel,
  ],

  conflicts: $ => [
    [$.function_call, $.primary_expression],
  ],

  rules: {
    source_file: $ => repeat(choice(
      $.option_statement,
      $.class_statement,
      $.sub_statement,
      $.function_statement,
      $.property_statement,
      $._statement,
    )),

    _line_continuation: $ => /_[ \t]*\r?\n/,

    // Delimitadores del bloque: la inyección de asp.nvim incluye el bloque
    // entero, así un token no sigue en el bloque siguiente.
    _block_delimiter: $ => token(choice('<%=', '<%', '%>')),

    option_statement: $ => seq(
      ci('Option'),
      choice(
        ci('Explicit'),
        seq(ci('Compare'), choice(ci('Binary'), ci('Text'), ci('Database'))),
        seq(ci('Base'), choice('0', '1')),
        seq(ci('Private'), ci('Module')),
      ),
    ),

    sub_statement: $ => seq(
      optional(choice(seq(ci('Public'), optional(ci('Default'))), ci('Private'), ci('Friend'), ci('Static'))),
      ci('Sub'), $.identifier, optional($._arg_list),
      optional($.block), ci('End'), ci('Sub'),
    ),

    function_statement: $ => seq(
      optional(choice(seq(ci('Public'), optional(ci('Default'))), ci('Private'), ci('Friend'), ci('Static'))),
      ci('Function'), $.identifier, optional($._arg_list),
      optional($.block), ci('End'), ci('Function'),
    ),

    property_statement: $ => seq(
      optional(choice(seq(ci('Public'), optional(ci('Default'))), ci('Private'), ci('Static'))),
      ci('Property'), choice(ci('Get'), ci('Let'), ci('Set')),
      $.identifier, optional($._arg_list),
      optional($.block), ci('End'), ci('Property'),
    ),

    class_statement: $ => seq(
      ci('Class'), field('name', $.identifier),
      repeat(choice(
        $.dim_statement,
        $.const_statement,
        $.sub_statement,
        $.function_statement,
        $.property_statement,
      )),
      ci('End'), ci('Class'),
    ),

    _arg_list: $ => seq(
      alias($._args_open, '('), optional(seq($._arg, repeat(seq(',', $._arg)))), ')',
    ),

    _arg: $ => seq(
      optional(choice(ci('Optional'), ci('ByVal'), ci('ByRef'), ci('ParamArray'))),
      $.identifier,
      optional($._array_dim),
      optional(seq('=', $.expression)),
    ),

    block: $ => repeat1(choice(
      $.if_statement, $.for_statement, $.for_each_statement,
      $.while_statement, $.do_statement, $.with_statement,
      $.select_case_statement, $.on_error_statement, $.resume_statement,
      $.erase_statement, $.redim_statement,
      $.set_statement, $.let_statement, $.call_statement,
      $.exit_statement, $.goto_statement,
      $.dim_statement, $.const_statement,
      $.label_statement, $.error_statement, $.mid_statement,
      $.expression,
    )),

    _statement: $ => choice(
      $.if_statement, $.for_statement, $.for_each_statement,
      $.while_statement, $.do_statement, $.with_statement,
      $.select_case_statement, $.on_error_statement, $.resume_statement,
      $.erase_statement, $.redim_statement,
      $.set_statement, $.let_statement, $.call_statement,
      $.exit_statement, $.goto_statement,
      $.dim_statement, $.const_statement,
      $.label_statement, $.error_statement, $.mid_statement,
      $.expression,
    ),

    label_statement: $ => seq($.identifier, ':'),

    error_statement: $ => seq(ci('Error'), $.expression),

    mid_statement: $ => seq(
      ci('Mid'), '(', $.identifier, ',', $.expression, ',', $.expression, ')', '=', $.expression,
    ),

    if_statement: $ => choice($._block_if, $._inline_if),

    _block_if: $ => seq(
      ci('If'), $.expression, ci('Then'), $._block_then,
      optional($.block),
      repeat($.elseif_clause),
      optional($.else_clause),
      ci('End'), ci('If'),
    ),

    _inline_if: $ => prec.right(seq(
      ci('If'), $.expression, ci('Then'),
      $._inline_statements,
      optional(seq($._inline_else, ci('Else'), $._inline_statements)),
    )),

    // `If a Then b = 1 : c = 2 Else d = 3`: todo lo de la línea es del If.
    _inline_statements: $ => prec.right(seq(
      $._statement, repeat(seq(alias($._inline_colon, ':'), $._statement)),
    )),

    elseif_clause: $ => seq(ci('ElseIf'), $.expression, ci('Then'), optional($.block)),
    else_clause: $ => seq(ci('Else'), optional($.block)),

    for_statement: $ => seq(
      ci('For'), $.identifier, '=', $.expression, ci('To'), $.expression,
      optional(seq(ci('Step'), $.expression)),
      optional($.block), ci('Next'),
    ),

    for_each_statement: $ => seq(
      ci('For'), ci('Each'), $.identifier, ci('In'), $.expression,
      optional($.block), ci('Next'),
    ),

    while_statement: $ => seq(ci('While'), $.expression, optional($.block), ci('Wend')),
    do_statement: $ => choice(
      seq(ci('Do'), choice(ci('While'), ci('Until')), $.expression, optional($.block), ci('Loop')),
      seq(ci('Do'), optional($.block), ci('Loop'), choice(ci('While'), ci('Until')), $.expression),
    ),
    with_statement: $ => seq(ci('With'), $.expression, optional($.block), ci('End'), ci('With')),

    select_case_statement: $ => seq(
      ci('Select'), ci('Case'), $.expression,
      repeat($.case_clause), optional(seq(ci('Case'), ci('Else'), optional($.block))),
      ci('End'), ci('Select'),
    ),
    case_clause: $ => seq(
      ci('Case'), $._case_value, repeat(seq(',', $._case_value)), optional($.block),
    ),
    _case_value: $ => choice($.expression, seq(ci('Is'), $.expression)),

    on_error_statement: $ => seq(
      ci('On'), ci('Error'),
      choice(
        seq(ci('GoTo'), $.expression),
        seq(ci('Resume'), ci('Next')),
        seq(ci('GoTo'), '0'),
      ),
    ),
    resume_statement: $ => seq(ci('Resume'), choice(ci('Next'), $.expression)),
    erase_statement: $ => seq(ci('Erase'), $.expression, repeat(seq(',', $.expression))),
    redim_statement: $ => seq(ci('ReDim'), optional(ci('Preserve')), $.expression, repeat(seq(',', $.expression))),
    let_statement: $ => prec(4, seq(
      optional(ci('Let')), choice($.expression, $._keyword_target), '=', $.expression,
    )),

    // `error = 1`, `call = 2`, `mid = 3`: la palabra clave de una
    // sentencia seguida de `=` es una variable (Error y Mid no son
    // reservadas en VBScript).
    _keyword_target: $ => alias($._keyword_primary, $.expression),
    _keyword_primary: $ => alias($._keyword_name, $.primary_expression),
    // El mismo token que ci(), con otro nombre en este lugar.
    _keyword_name: $ => choice(...['Error', 'Call', 'Mid'].map(word =>
      alias(new RegExp(word, 'i'), $.identifier))),
    set_statement: $ => seq(ci('Set'), $.expression, '=', $.expression),
    call_statement: $ => choice(
      seq(ci('Call'), $.expression),
      prec.left(1, seq(
        $.expression,
        repeat1(choice(
          seq(',', $.expression),
          seq($._omitted_run, $.expression),
        )),
      )),
    ),

    _omitted_run: $ => token(/,[ \t]*(,[ \t]*)+/),

    exit_statement: $ => seq(ci('Exit'), choice(ci('Sub'), ci('Function'), ci('Property'), ci('Do'), ci('For'), ci('While'))),
    goto_statement: $ => seq(ci('GoTo'), $.expression),

    dim_statement: $ => seq(
      choice(ci('Dim'), ci('Public'), ci('Private'), ci('Static')),
      $._dim_variable,
      optional(seq('=', $.expression)),
      repeat(seq(',', $._dim_variable)),
    ),

    _dim_variable: $ => prec.right(2, seq(
      $.identifier, optional($._array_dim),
    )),

    _array_dim: $ => seq('(', optional(seq($.expression, repeat(seq(',', $.expression)))), ')'),

    const_statement: $ => seq(
      optional(choice(ci('Public'), ci('Private'))),
      ci('Const'), $._const_item, repeat(seq(',', $._const_item)),
    ),

    _const_item: $ => seq($.identifier, '=', $.expression),

    // === Expressions ===
    expression: $ => choice(
      $.unary_expression,
      $.binary_expression,
      $.call_expression,
      $.member_expression,
      $.function_call,
      $.primary_expression,
    ),

    call_expression: $ => prec.left(5, seq(
      choice($.member_expression, $.function_call),
      '(', optional($._arg_expression_list), ')',
    )),

    member_expression: $ => prec.left(10, choice(
      seq(
        choice($.primary_expression, $.function_call, $.call_expression, $.member_expression),
        alias($._member_dot, '.'), $.identifier,
      ),
      // `.Campo` dentro de un With.
      seq(alias($._with_dot, '.'), $.identifier),
    )),

    assignment_expression: $ => prec.right(-1, seq($.expression, '=', $.expression)),

    binary_expression: $ => choice(
      prec.left(1, seq($.expression, choice('+', '-', '*', '/', '\\', ci('Mod'), '^'), $.expression)),
      prec.left(2, seq($.expression, '&', $.expression)),
      prec.left(3, seq($.expression, choice('=', '<>', '<', '>', '<=', '>=', ci('Is')), $.expression)),
      prec.left(4, seq($.expression, choice(ci('And'), ci('Or'), ci('Xor'), ci('Eqv'), ci('Imp')), $.expression)),
    ),

    unary_expression: $ => prec.left(5, seq(choice(ci('Not'), '-'), $.expression)),

    // `f(1)` es una llamada, no `f` seguido de `(1)`: los saltos de línea
    // son extras y la gramática admite expresiones yuxtapuestas.
    function_call: $ => prec.dynamic(1, seq($.identifier, '(', optional($._arg_expression_list), ')')),
    _arg_expression_list: $ => choice(
      seq($.expression, repeat(seq(',', optional($.expression)))),
      repeat1(seq(',', optional($.expression))),
    ),

    primary_expression: $ => choice(
      $.identifier, $.number_literal, $.string_literal, $.date_literal,
      $.boolean_literal, $.nothing_literal, $.null_literal, $.empty_literal,
      seq('(', $.expression, ')'),
    ),

    number_literal: $ => token(choice(
      /&H[0-9a-fA-F]+/, /&O[0-7]+/,
      /\d+\.\d*([eE][+-]?\d+)?/, /\.\d+([eE][+-]?\d+)?/, /\d+[eE][+-]?\d+/, /\d+/,
    )),

    string_literal: $ => token(seq('"', repeat(choice(/[^"]/, '""')), '"')),
    date_literal: () => /#[^#\r\n]+#/,
    boolean_literal: $ => choice(ci('True'), ci('False')),
    nothing_literal: $ => ci('Nothing'),
    null_literal: $ => ci('Null'),
    empty_literal: $ => ci('Empty'),

    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,
  },
});
