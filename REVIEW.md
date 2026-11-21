# dasFlex Code Review Checklist

**Read `REVIEW_COMMON.md` (package root) first - its contract binds this checklist.** Architecture doc:
`ARCHITECTURE.md`.

**A diff under `flex/` that adds a `require` of a module other than one under `flex/`, one under
`daslib/`, or a builtin module the daslang executable registers itself (such as `strings` or `math`)
is a defect** - the package is installed by `daspkg` into projects that load nothing else under
`modules/`.

**A diff that makes `build_tables` resolve a state holding two accepting rules other than by the
lowest rule index is a defect** - the rule written first wins a tie (`ARCHITECTURE.md#one-automaton`).

**A diff that makes `flex_match_table`, or the goto-mode code `make_goto_matcher` emits, return a
match shorter than the longest accepting span from the cursor is a defect**
(`ARCHITECTURE.md#longest-match`).

**A diff that lets a rule matching the empty string advance the cursor by zero bytes without
reporting an error is a defect** - the scanner would loop forever.

**A diff that makes the generated scanner decode UTF-8 in its inner loop is a defect** - encode the
shape into the automaton at build time instead (`ARCHITECTURE.md#bytes`).

**A diff that builds, or rebuilds, the tables of a `[flex]` function at run time is a defect** - the
tables are module globals the annotation fills at compile time (`ARCHITECTURE.md#compile-time`).

**A diff that makes table mode and goto mode produce different tokens for the same rules and input is
a defect** - `tests/flex_tests.das` holds the equivalence check; weakening it is a defect too.

**A diff that lets `flex_tables` return tables with an empty `err` for a rule whose regex did not
parse, or holds an anchor, a word boundary, a lookahead or a lazy quantifier, is a defect** - the
compile must fail with the rule's text.

**A diff that makes `flex_error_text` drop the file, the line or the column, or that reports a byte
where a whole UTF-8 character is available, is a defect.**

**A diff that allocates a string in the generated scanner loop before a rule body asks for one
(`text`) is a defect** - the match is a span; the string is on request.

**A diff that changes `examples/c_lexer/c_lexer.das` so that its token stream over a preprocessed C
file differs from the hand-written lexer in `c_lex_compare.das` (`--mode probe`) is a defect** - run
both with `--dump` and diff.
