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
  calls (`emit`, `begin`, `text`, `text_is`), the capture-group re-match behind `group` and
  `group_span` (`flex_group`, `flex_group_span`, `flex_group_regex`), the error text (`flex_error_text`), and the
  matcher and position tracking of the `matcher="call"` shape (`flex_match_table`,
  `flex_consume`). No regex, no AST.
- `flex/flex_macro.das` - the `[flex]` function annotation and `[flex_text]`, the one the reader's
  output carries: each collects its rules into a `FlexSpec`, and `flex_generate` builds the tables
  through `flex_tables`, stores them as private module globals and rewrites the function body into
  the scanner loop, in table or goto mode. The only file that touches the AST of a rule set.
- `flex/flex_reader.das` - the `%flex~` reader macro: flex-like text to the source of a
  `[flex_text]` function (`flex_reader_source`). Text in, text out; no regex, no tables.
- `examples/c_lexer/` - the C11 lexer on dasFlex (`c_lexer.das`), its goto-mode twin, the same rules
  in `%flex~` form (`c_lexer_reader.das`), a demo and the comparison and timing driver.
- `tests/` - the package's dastest tests.
- `tutorials/` - the JSON lexer as `[flex]` rules (01) and as `%flex~` text (02), a config lexer
  reading capture groups (03).

## One automaton per rule set {#one-automaton}

Every rule of a `[flex]` function joins one NFA: a start state per start condition with an epsilon
edge to each rule active in it, and the rule's own accepting state tagged with the rule's index.
Subset construction then yields one DFA whose accepting states carry the lowest rule index among
the NFA accepting states they hold, so when two rules match the same longest text the one written
first wins - flex's rule. Running the rules one at a time would cost a pass per rule per token;
the union automaton reads every byte once.

After subset construction, Hopcroft's partition refinement merges every pair of DFA states that
accept the same rule and move into equivalent states on every byte class, so the tables are the
minimal automaton for the rule set; the start state of each condition keeps its identity, -1 remains
the only dead state, and the byte classes are untouched. Minimization sits after subset construction,
in `flex_tables`, because equivalence is a property of the deterministic automaton (subset
construction turns distinct NFA paths into distinct state sets even when their futures coincide), and
every front end and scanner shape then reads the smaller tables.

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
function's module makes visible. Every dispatch shape gives the block a scope of its own (a nested
block after the rule's label under a computed `goto`, the branch under the `if` chain and the tree),
so two rules may declare the same local. `emit(lx, kind)` records the token kind and ends the scan;
a body that does not emit is a skip and the loop continues; `begin(lx, "NAME")` switches the start
condition, the macro replacing the name with its index at compile time. The rewrite takes only a
call whose first argument is the lexer parameter itself, so a function of the user's own named
`emit`, `begin` or `group` keeps its meaning in a rule body. The matched text is a byte span
(`tok.start`, `tok.len`) until `text()` is asked for a string.

## Capture groups by re-match {#groups}

`lx |> group(n)` in a rule body is the text of capture group `n` of the token and
`lx |> group_span(n)` its byte range in the input (`range(0, 0)` and "" for a group that takes no
part in the match, group 0 the token itself). The automaton and every token stay as they are: the
groups are the rule's own regex, run once over the token's span on request. The rewrite that turns
`emit` into field writes turns these calls into `flex_group(lx, re, n)` / `flex_group_span(lx, re,
n)`, where `re` is a private module global the macro adds only for a rule whose body calls `group`
or `group_span`, initialized from the rule's pattern wrapped as `(?:pattern)$` when the module's
globals initialize. The anchor makes the backtracking matcher of `daslib/regex` find a match that
covers the whole token - the one the automaton accepted - rather than the first shorter one an
alternation or an optional tail would give.

The first call on a token runs that regex over the token's text (the cached `text()` string) and
copies the spans, moved to input offsets, into `FlexLexer.groups`; `groups_re` (the regex's address)
and `groups_start` (the token's `tok.start`) mark whose groups they are, so the next calls on the
same token read the copy and a call on the next token, or through another rule's regex, matches
again. The cost is paid only by rules that ask, once per token: a rule without group calls gets no
regex, no global and no code, and the scanner loop does not touch the group fields.

A rule whose body calls `group` while its regex has no capture group, or that asks for a constant
index past its last group, fails the compile at the rule's line; the macro compiles the anchored
pattern once to count them. The groups inherit `daslib/regex`'s matching semantics, quirks
included: where it takes a greedy quantifier lazily, a group can come out shorter than a greedy
engine would make it while the token stays the one the automaton found (`tests/flex_tests.das`
holds the case).

A tagged DFA (re2c's TDFA) is the single-pass alternative: tags on the automaton's transitions
record group boundaries while the token is read. It would put tag bookkeeping into the scanner's
inner loop and the table builder for every rule set, against one extra match per token for the rules
that ask; it is the parked path.

## Two front ends, one back end {#reader}

`[flex]` reads its rules from `rule` and `condition` calls; `%flex~ name : Enum ... %%` reads them
from flex-like text. Both end in one `FlexSpec` - patterns, the conditions each rule is active in,
the rule bodies - and one `flex_generate`, so the tables, the scanner shapes and the tokens are the
same whichever form a lexer is written in.

The reader does not build AST. Its `suffix` hook returns daslang source the parser reads in place
of the `%flex~ ... %%` text: a function `def name(var lx : FlexLexer) : bool` annotated
`[flex_text(tokens, conditions, mode, dispatch, matcher)]` whose body holds one
`rule("regex", "conditions") { action }` per rule line. The actions are therefore ordinary daslang,
parsed and type-checked like any other code, and `[flex_text]` rewrites `emit(NAME)` into
`emit(lx, Enum.NAME)`, `emit(expr)` into `emit(lx, expr)`, `begin(NAME)` into the condition's
index and `group(n)` / `group_span(n)` into the calls `#groups` describes. A definition `{NAME}`
expands as a non-capturing group `(?:...)`, so `group(n)` counts the parentheses the rule writes. The source keeps one output line per input line, a multi-line action included, and the
parser is told it starts at the reader's line in the user's file, so a regex, condition or token
error lands on the line the rule was written on.

The result is a declaration, not a value: `%flex~` stands at module level and the generated
function is called by name (`while (name(lx))`), with no function pointer between the caller and
the scanner. The text ends at the first `%%`, as every reader's does, so the formatter and the
other tools that skip reader text skip all of it; the definitions end at the line `%rules`
rather than at flex's inner `%%`.

## The symbol table {#symbols}

`FlexLexer.symbols : table<string; int>` is the one channel from a parser back into the lexer: a
C parser puts `typedef` names there and the identifier rule reads it to decide between
`IDENTIFIER` and `TYPEDEF_NAME`. It is a field of the lexer, not a global, so two lexers never share
it by accident.

## Not carried by this version {#not-carried}

- Capture groups in one pass: `group` re-matches the token (`#groups`); a tagged DFA is not built.
- Trailing context (`r/s`) and anchors. The `%flex~` reader refuses a bare `/` - one outside
  quotes and a set, not escaped - at the rule's line; `"/"` and `\/` stay literal slashes.
- flex's `|` action (the next rule's action), `REJECT`, `yymore` and `%array`/`%pointer` in the
  `%flex~` form; a brace-less action is one line with no comment.
- Unicode classes such as `[а-я]`: the set syntax of `daslib/regex` is byte-wise, so a class over
  code points above 127 is written as an alternation of literals.
