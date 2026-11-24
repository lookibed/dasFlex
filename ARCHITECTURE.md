# dasFlex architecture

This document follows `ARCHITECTURE_COMMON.md` (a copy sits at this package's root). dasFlex is a
pure daslang lexer generator: rules written as regular expressions inside a `[flex]` function are
compiled at compile time into one deterministic automaton per rule set, and the function becomes the
scanner that drives it. It depends on `daslib/regex` for parsing regex text and on nothing under
`modules/`.

## File charters

- `flex/flex_regex.das` - the regex tree of `daslib/regex` to a byte NFA (`Nfa`, `FlexRule`,
  `build_nfa`). Owns the UTF-8 shapes of `.` and the list of regex forms a DFA cannot carry. Never
  parses regex text itself.
- `flex/flex_dfa.das` - the NFA to tables (`FlexTables`, `build_tables`, `flex_tables`): byte
  equivalence classes, subset construction, the rule an accepting state carries. Knows nothing of
  source code or macros.
- `flex/flex.das` - the run-time scanner state (`FlexLexer`, `FlexToken`), the actions a rule body
  calls (`emit`, `begin`, `text`, `text_is`), the error text (`flex_error_text`), and the
  matcher and position tracking of the `matcher="call"` shape (`flex_match_table`,
  `flex_consume`). No regex, no AST.
- `flex/flex_macro.das` - the `[flex]` function annotation: collects `rule` and `condition` calls,
  builds the tables through `flex_tables`, stores them as private module globals and rewrites the
  function body into the scanner loop, in table or goto mode. The only file that touches the AST.
- `examples/c_lexer/` - the C11 lexer on dasFlex (`c_lexer.das`), its goto-mode twin, a demo and the
  four-way comparison and timing driver.
- `tests/` - the package's dastest tests.
- `tutorials/` - the one-page JSON lexer tutorial.

## One automaton per rule set {#one-automaton}

Every rule of a `[flex]` function joins one NFA: a start state per start condition with an epsilon
edge to each rule active in it, and the rule's own accepting state tagged with the rule's index.
Subset construction then yields one DFA whose accepting states carry the lowest rule index among
the NFA accepting states they hold, so when two rules match the same longest text the one written
first wins - flex's rule. Running the rules one at a time would cost a pass per rule per token;
the union automaton reads every byte once.

## Bytes, not code points {#bytes}

The automaton reads UTF-8 bytes. A literal above 127 is its byte sequence, `.` is the set of byte
shapes a UTF-8 code point other than newline can take (one byte below 128, or a lead byte followed
by one to three continuation bytes), and a byte set `[...]` is the 256-bit set `daslib/regex`
parses. The inner loop therefore never decodes; it maps a byte to its class and the class to the
next state. Columns are byte equivalence classes - the finest partition of 0..255 every edge of the
NFA is a union of, with byte 10 always alone in its class so a scanner counts lines by the class it
reads - so the transition table is `nstates x nclasses` (about seventy classes for the C lexer)
rather than `nstates x 256`.

## Longest match with fall-back {#longest-match}

The matcher runs the DFA from the cursor until no transition exists, remembering the last accepting
state and its position. The token is that remembered span; the bytes read past it are re-read by
the next token. An accepting start state (a rule matching the empty string) is refused as an error
at the cursor rather than accepted, since an empty token would never advance.

## Built at compile time {#compile-time}

The `[flex]` annotation runs in the macro context when the module compiles. It builds the tables
once and emits them as `to_array_move([...])` initialisers of private module globals named after
the function, so a program pays nothing for the construction at run time and the generated function
is ordinary code the interpreter, the JIT and the AOT compiler all see. A failed regex, a form a
DFA cannot carry (anchors, word boundaries, lookahead, lazy quantifiers) or an unknown start
condition fails the compile with the rule's text in the message.

## Two scanner shapes {#two-shapes}

`mode="table"` drives the DFA from the globals; `mode="goto"` emits it as straight-line code - a
label per state, a byte read, range tests per class and a `goto` to the next state - the way re2c and
Ragel generate scanners. The default follows the tier (below): the table function stays small whatever
the rule set, the goto code is what LLVM folds best.

In table mode `matcher="inline"` (the default) emits the byte loop into the scanner itself, through
raw pointers, over one merged table whose entry is `next * 256 + accept(next) + 1`: one load per
byte yields the next state and the rule it accepts, which caps an inline scanner at 254 rules.
`matcher="call"` calls `flex_match_table` instead. The JIT compiles each module as its own unit, so
a call into `flex/flex.das` stays a call per token, while code the macro emits inlines by
construction - hence the default.

The inline loop and the goto code count newlines as they read: `\n` is a class of its own and only
a move on it counts, while an accepting state records the count with the length. Taking the token
then sets line and column without reading its bytes again; the call shape walks them a second time
in `flex_consume`.

`dispatch` picks how the matched rule reaches its body: a computed `goto` into a label per rule, an
`if (rule == i)` chain, or a binary tree of `if (rule < m)`. Every shape takes the same rules and
produces the same tokens; the choice among them is a measurement. The default goes with the mode: a
computed `goto` in table mode, where it saves the interpreter the comparison chain, and the `if` chain
in goto mode, where LLVM already turns the chain into a `switch` and a computed `goto` adds a second
`switch` over label indices. An explicit `dispatch` overrides it.

The default follows the tier the program is compiled for, read from `compiling_program().policies.jit_enabled` while the
annotation runs: tables for the interpreter, where every simulation node costs and the table walk is the fewest nodes
per byte, straight-line code for the JIT and the exe, where LLVM folds the per-state tests into `switch` instructions.
`mode = "table"` or `mode = "goto"` on the annotation overrides it. The module cache keeps a record per tier, so a
module compiled for the interpreter is compiled again, not reused, when the same program runs under the JIT.

## Rule bodies run in place {#rule-bodies}

A rule's block is spliced into the generated function at its dispatch label or branch, so it sees
the function's parameter - the lexer - under the name the user gave it, and anything else the
function's module makes visible. `emit(lx, kind)` records the token kind and ends the scan; a body
that does not emit is a skip and the loop continues; `begin(lx, "NAME")` switches the start
condition, the macro replacing the name with its index at compile time. The matched text is a
byte span (`tok.start`, `tok.len`) until `text()` is asked for a string.

## The symbol table {#symbols}

`FlexLexer.symbols : table<string; int>` is the one channel from a parser back into the lexer: a
C parser puts `typedef` names there and the identifier rule reads it to decide between
`IDENTIFIER` and `TYPEDEF_NAME`. It is a field of the lexer, not a global, so two lexers never share
it by accident.

## Not carried by this version {#not-carried}

- Capture groups: a rule body sees the whole match only. Flex has no submatch either; when needed,
  tagged DFA (re2c's TDFA) is the shape that keeps one pass.
- Trailing context (`r/s`) and anchors.
- Unicode classes such as `[а-я]`: the set syntax of `daslib/regex` is byte-wise, so a class over
  code points above 127 is written as an alternation of literals.
