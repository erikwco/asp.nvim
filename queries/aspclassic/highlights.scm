[
  "<%"
  "<%="
  "<%@"
  "%>"
] @keyword.directive

"<!--#include" @keyword.import

"-->" @keyword.import

(include_kind) @variable.parameter

(quoted_path) @string.special.path

(directive_attributes) @attribute
