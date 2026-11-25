# dasFlex

A lexer generator for [daslang](https://daslang.io/): rules are regular expressions in a `[flex]`
function, the automaton is built when the module compiles, and the function becomes the scanner.

```das
require flex/flex_macro

enum Tok {
    NUMBER = 1
    WORD = 2
}

[flex]
def my_lexer(var lx : FlexLexer) : bool {
    rule("[0-9]+") {
        lx |> emit(Tok.NUMBER)
    }
    rule("[A-Za-z]+") {
        lx |> emit(Tok.WORD)
    }
    rule("[ \\t\\r\\n]+") {
    }
}

def main() {
    var lx : FlexLexer
    flex_open(lx, "answer 42", "input.txt")
    while (my_lexer(lx)) {
        print("{lx.tok.kind} '{text(lx)}' at {lx.tok.line}:{lx.tok.col}\n")
    }
    if (lx.failed) {
        print("{lx.err}\n")        // input.txt:1:7: unexpected '§'
    }
}
```

- Longest match wins; on a tie the rule written first.
- `condition("NAME", exclusive|inclusive) { rules }` declares a start condition; `begin(lx, "NAME")`
  switches to it, `begin(lx, "INITIAL")` back.
- `[flex(mode = "goto")]` emits the automaton as straight-line code instead of tables;
  `matcher = "call"` and `dispatch = "if"|"goto"|"tree"` pick the other shapes; the defaults follow
  the tier: table mode with `matcher = "inline"` and `dispatch = "goto"` under the interpreter, goto
  mode with `dispatch = "if"` under the JIT and the exe; `mode =` alone takes the dispatch that goes
  with it (`ARCHITECTURE.md#two-shapes`).
- `lx.symbols` is a `table<string; int>` a parser fills and a rule may consult.
- `lx |> group(n)` in a rule body is the text of capture group `n` of the token, `lx |> group_span(n)`
  its byte range in the input; the rule's regex runs once over the token on the first call, and only
  rules that call them pay for it (`ARCHITECTURE.md#groups`).

The same lexer in flex-like text, at module level - it declares `def my_lexer(var lx : FlexLexer) :
bool` through the same generator:

```das
%flex~ my_lexer : Tok
%x COMMENT
DIGIT   [0-9]
%rules
{DIGIT}+            { emit(NUMBER) }
[A-Za-z]+           { emit(WORD) }
[ \t\r\n]+
"/*"                { begin(COMMENT) }
<COMMENT>"*/"       { begin(INITIAL) }
<COMMENT>[^*]+
<COMMENT>\*
%%
```

- The header names the function and, after `:`, the token enum; `%x` / `%s` declare exclusive and
  inclusive start conditions, `NAME regex` a definition `{NAME}` expands, `%option mode=goto` (and
  `dispatch=`, `matcher=`) the shape; `%rules` starts the rules and the first `%%` ends the text.
- A rule is `<COND,...>` or `<*>` (optional), the pattern - `"..."` literal, the rest
  `daslib/regex` - and the action: daslang code in braces, or one line without them, or nothing (a
  skip). In an action `emit(NAME)` emits a member of the header's enum, `emit(expr)` any int kind,
  `begin(NAME)` switches the condition, `group(n)` / `group_span(n)` read a capture group (a
  definition `{NAME}` is not one), and `lx` is the lexer (`text(lx)`, `lx.symbols`).
- Errors - a bad regex, an unknown condition or token - are reported at the rule's line.

## Speed

One `heavy --exclusive` run on a quiet machine, three preprocessed C files, ms per pass: the median
of 3 rounds, each round the median of 9 passes in one process (one process per driver and file).
The daslang rows are `examples/c_lexer/c_lex_compare.das`; every driver yields the same 17 207 /
13 474 / 16 484 raw tokens.

| driver | what the timed loop does | doom_am_map.i | doom_p_mobj.i | wasm3_m3_parse.i |
|---|---|---|---|---|
| dasFlex, count only, interp | `--mode flex --count`: the scanner counts tokens; the identifier rule builds the word's string and looks it up as keyword and typedef name | 9.261 | 8.133 | 9.640 |
| dasFlex, count only, JIT | same, `-jit` | 0.714 | 0.642 | 0.736 |
| dasFlex, token array, interp | `--mode flex`: the above plus `text()` per token and a `{kind, text, line}` array; opens the lexer (typedef table copied) inside the timer | 10.934 | 9.259 | 11.055 |
| dasFlex, token array, JIT | same, `-jit` | 1.086 | 0.937 | 1.092 |
| hand-written lexer, interp | `--mode probe`: a byte loop, keyword and typedef lookup, a string per token, the same array | 6.514 | 5.524 | 6.377 |
| hand-written lexer, JIT | same, `-jit` | 1.041 | 0.811 | 1.305 |
| hand-written lexer, C `-O2` | a C port of `--mode probe`: `malloc` per token text, the same array, freed inside the timer | 1.542 | 1.046 | 0.794 |
| chibicc `tok`, C `-O2` | chibicc's `tokenize()`, punctuators and prefixes picked by the first byte (local edits) | 2.237 | 1.814 | 2.174 |
| chibicc `fast`, C `-O2` | the same plus an arena allocator, ASCII character classes and the identifier hash taken while lexing | 1.953 | 1.600 | 1.927 |

chibicc's `tokenize()` does work the dasFlex rows do not: it allocates a token per token (`calloc` in
`tok`, the arena in `fast`), decodes every string literal into a fresh buffer, and numbers lines in a
second pass over the token list; it does not tell keywords from identifiers and has no typedef
lookup. Against `fast` the count-only JIT row takes 2.49-2.74x less time, the token-array JIT row
1.71-1.80x less. The C lexer in `examples/c_lexer` does not carry `$` or Unicode in identifiers,
`#` and `##` tokens, or chibicc's `has_space` / `at_bol` flags. Method and the step-by-step history:
`PERF_LEDGER.md`.

Install: `daspkg install github.com/lookibed/dasFlex`, then `require flex/flex_macro`.
Run the tests from a daslang checkout: `daslang -load_module <dasFlex> dastest/dastest.das -- --test <dasFlex>/tests`.
Design and the rules a change must keep: `ARCHITECTURE.md`, `REVIEW.md`. A JSON lexer walk-through:
`tutorials/01_json_tokens.das`, the same lexer in `%flex~` form: `tutorials/02_flex_reader.das`,
capture groups: `tutorials/03_groups.das`.
