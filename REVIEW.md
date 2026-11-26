# dasFlex Code Review Checklist

**Read `REVIEW_COMMON.md` (package root) first - its contract binds this checklist.** Architecture doc:
`ARCHITECTURE.md`.

**A diff under `flex/` that adds a `require` of a module other than one under `flex/`, one under
`daslib/`, or a builtin module the daslang executable registers itself (such as `strings` or `math`)
is a defect** - the package is installed by `daspkg` into projects that load nothing else under
`modules/`.

**A diff that makes `build_tables` resolve a state holding two accepting rules other than by the
lowest rule index is a defect** - the rule written first wins a tie (`ARCHITECTURE.md#one-automaton`).

**A diff that makes `flex_match_table`, the inline matcher, or the goto-mode code
`make_goto_matcher` emits, return a match shorter than the longest accepting span from the cursor is
a defect**
(`ARCHITECTURE.md#longest-match`).

**A diff that lets a rule matching the empty string advance the cursor by zero bytes without
reporting an error is a defect** - the scanner would loop forever.

**A diff that makes the generated scanner decode UTF-8 in its inner loop is a defect** - encode the
shape into the automaton at build time instead (`ARCHITECTURE.md#bytes`).

**A diff that builds, or rebuilds, the tables of a `[flex]` function at run time is a defect** - the
tables are module globals the annotation fills at compile time (`ARCHITECTURE.md#compile-time`).

**A diff that makes two shapes - any `mode`, `matcher` or `dispatch` - produce different tokens,
lines or columns for the same rules and input is a defect** - `tests/flex_tests.das` holds the
equivalence check; weakening it is a defect too.

**A diff that lets `flex_tables` return tables with an empty `err` for a rule whose regex did not
parse, or holds an anchor, a word boundary, a lookahead or a lazy quantifier, is a defect** - the
compile must fail with the rule's text.

**A diff that makes `flex_error_text` drop the file, the line or the column, or that reports a byte
where a whole UTF-8 character is available, is a defect.**

**A diff that makes the inline matcher or goto mode read a token's bytes a second time after the
match - a pass for line and column - is a defect** - they count newlines on the way
(`ARCHITECTURE.md#two-shapes`).

**A diff that allocates a string in the generated scanner loop before a rule body asks for one
(`text`) is a defect** - the match is a span; the string is on request.

**A diff that makes `intern` build a string or allocate on a hit, that lets `flex_open` replace the
input while the lexer's symbols still point into it, or that leaves in `tok.sym` a symbol no rule
interned for the token, is a defect** - a symbol is found by its bytes and its string is built on
request (`ARCHITECTURE.md#symbols`).

**A diff that changes `examples/c_lexer/c_lexer.das` so that its token stream over a preprocessed C
file differs from the hand-written lexer in `c_lex_compare.das` (`--mode probe`) is a defect** - run
both with `--dump` and diff.

**A diff that edits `examples/c_lexer/c_lexer_goto.das` or `examples/c_lexer/c_lexer_variants.das`
by hand, or changes the rules of `c_next` in `c_lexer.das` without running
`examples/c_lexer/gen_variants.das`, is a defect** - the two files are the generator's output, one
copy of the rules per scanner shape.

**A diff that gives a front end - the `%flex~` reader or a new one - its own table builder, its own
scanner emission, or a path to the tables that does not pass a `FlexSpec` to `flex_generate`, is a
defect** - the two forms of a lexer must give the same tables and tokens (`ARCHITECTURE.md#reader`).

**A diff that makes `flex_reader_source` write a different number of lines than its input holds, or
makes the reader's text end anywhere but at the first `%%`, is a defect** - diagnostics would land
on the wrong line, and the formatter would reformat rule text as code.

**A diff that makes a dispatch shape splice a rule body into the scanner without a scope of its own
is a defect** - two rules declaring the same local would collide (`ARCHITECTURE.md#rule-bodies`).

**A diff that makes a rule whose body has no `group` or `group_span` call pay for groups - a regex
compiled, a global added, or a regex run for it, or a group field written in the scanner loop - is a
defect** - the re-match is paid only by the rules that ask (`ARCHITECTURE.md#groups`).
