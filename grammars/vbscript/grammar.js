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
  return new RegExp(word, 'i');
}

module.exports = grammar({
  name: 'vbscript',

  extras: $ => [/\s/, $.comment, $._line_continuation, ':'],

  conflicts: $ => [
    [$.function_call, $.primary_expression],
    [$.dim_statement],
    [$.block, $._statement],
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

    comment: $ => token(seq("'", /[^\n]*/)),
    _line_continuation: $ => /_[ \t]*\r?\n/,

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
      optional(choice(ci('Public'), ci('Private'), ci('Friend'), ci('Static'))),
      ci('Sub'), $.identifier, $._arg_list,
      optional($.block), ci('End'), ci('Sub'),
    ),

    function_statement: $ => seq(
      optional(choice(ci('Public'), ci('Private'), ci('Friend'), ci('Static'))),
      ci('Function'), $.identifier, $._arg_list,
      optional($.block), ci('End'), ci('Function'),
    ),

    property_statement: $ => seq(
      optional(choice(ci('Public'), ci('Private'), ci('Static'))),
      ci('Property'), choice(ci('Get'), ci('Let'), ci('Set')),
      $.identifier, $._arg_list,
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

    _arg_list: $ => seq('(', optional(seq($._arg, repeat(seq(',', $._arg)))), ')'),

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
      ci('If'), $.expression, ci('Then'),
      optional($.block),
      repeat($.elseif_clause),
      optional($.else_clause),
      ci('End'), ci('If'),
    ),

    _inline_if: $ => prec.right(seq(
      ci('If'), $.expression, ci('Then'),
      $._statement,
      optional(seq(ci('Else'), $._statement)),
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
      repeat($.case_clause), optional(seq(ci('Case'), ci('Else'), $.block)),
      ci('End'), ci('Select'),
    ),
    case_clause: $ => seq(ci('Case'), choice($.expression, seq(ci('Is'), $.expression)), optional($.block)),

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
    let_statement: $ => prec(4, seq(optional(ci('Let')), $.expression, '=', $.expression)),
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
      $.identifier,
      optional($._array_dim),
      optional(seq('=', $.expression)),
      repeat(seq(',', $.identifier, optional($._array_dim))),
    ),

    _array_dim: $ => seq('(', optional(seq($.expression, repeat(seq(',', $.expression)))), ')'),

    const_statement: $ => seq(
      optional(choice(ci('Public'), ci('Private'))),
      ci('Const'), $.identifier, '=', $.expression,
    ),

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

    member_expression: $ => prec.left(10, seq(
      choice($.primary_expression, $.function_call, $.call_expression, $.member_expression),
      '.', $.identifier,
    )),

    assignment_expression: $ => prec.right(-1, seq($.expression, '=', $.expression)),

    binary_expression: $ => choice(
      prec.left(1, seq($.expression, choice('+', '-', '*', '/', '\\', ci('Mod'), '^'), $.expression)),
      prec.left(2, seq($.expression, '&', $.expression)),
      prec.left(3, seq($.expression, choice('=', '<>', '<', '>', '<=', '>='), $.expression)),
      prec.left(4, seq($.expression, choice(ci('And'), ci('Or'), ci('Xor'), ci('Eqv'), ci('Imp')), $.expression)),
    ),

    unary_expression: $ => prec.left(5, seq(choice(ci('Not'), '-'), $.expression)),

    function_call: $ => seq($.identifier, '(', optional($._arg_expression_list), ')'),
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
      /\d+\.\d*([eE][+-]?\d+)?/, /\d+[eE][+-]?\d+/, /\d+/,
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
