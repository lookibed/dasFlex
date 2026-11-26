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

One run, alone on a quiet machine (cpu busy 2%), three preprocessed C files, ms per pass: the median
of 3 rounds, each round the median of 9 passes in one process (one process per driver and file).
The daslang rows are `examples/c_lexer/c_lex_compare.das`; every driver yields the same 17 207 /
13 474 / 16 484 raw tokens.

| driver | what the timed loop does | doom_am_map.i | doom_p_mobj.i | wasm3_m3_parse.i |
|---|---|---|---|---|
| dasFlex, count only, interp | `--mode flex --count`: the scanner counts tokens; the identifier rule builds the word's string and looks it up as keyword and typedef name | 9.261 | 8.133 | 9.640 |
| dasFlex, count only, JIT | same, `-jit` | 0.714 | 0.642 | 0.736 |
| dasFlex, token array, interp | `--mode flex`: the above plus one indirect block call per token (`invoke(scan, lx)`; `--count` calls `c_next` directly), `text()` per token and a `{kind, text, line}` array; opens the lexer (typedef table copied) inside the timer | 10.934 | 9.259 | 11.055 |
| dasFlex, token array, JIT | same, `-jit` | 1.086 | 0.937 | 1.092 |
| hand-written lexer, interp | `--mode probe`: a byte loop, keyword and typedef lookup by hash, a string slice per token, the same array; a one-byte punctuator allocates three slices (3-char, 2-char, emitted) and does two hash lookups | 6.514 | 5.524 | 6.377 |
| hand-written lexer, JIT | same, `-jit` | 1.041 | 0.811 | 1.305 |
| hand-written lexer, C `-O2` | a C port of `--mode probe`: the same token stream, not the same work - byte compares for punctuators, one `malloc` per token text, the array freed inside the timer | 1.542 | 1.046 | 0.794 |
| chibicc `tok`, C `-O2` | chibicc's `tokenize()`, punctuators and prefixes picked by the first byte (local edits) | 2.237 | 1.814 | 2.174 |
| chibicc `fast`, C `-O2` | the same plus an arena allocator, ASCII character classes and the identifier hash taken while lexing | 1.953 | 1.600 | 1.927 |

chibicc's `tokenize()` does work the dasFlex rows do not: it allocates a token per token (`calloc` in
`tok`, the arena in `fast`), decodes every string literal into a fresh buffer and gives it a
`calloc`'d array type, and numbers lines in a second pass over the token list; it does not tell keywords from identifiers and has no typedef
lookup. Against `fast` the count-only JIT row takes 2.49-2.74x less time, the token-array JIT row
1.71-1.80x less. The table was taken with the C lexer's ASCII rules; what its Unicode rules cost
is the ledger's "Unicode in the C lexer". The C lexer in `examples/c_lexer` does not carry `#` and
`##` tokens, or chibicc's `has_space` / `at_bol` flags. Method and the step-by-step history:
`PERF_LEDGER.md`.

Install: `daspkg install github.com/lookibed/dasFlex`, then `require flex/flex_macro`.
Run the tests from a daslang checkout: `daslang -load_module <dasFlex> dastest/dastest.das -- --test <dasFlex>/tests`.
Design and the rules a change must keep: `ARCHITECTURE.md`, `REVIEW.md`. A JSON lexer walk-through:
`tutorials/01_json_tokens.das`, the same lexer in `%flex~` form: `tutorials/02_flex_reader.das`,
capture groups: `tutorials/03_groups.das`.

## Unicode

The automaton reads UTF-8 bytes. A literal past ASCII is its bytes, `.` is one code point, and
`\uHHHH` / `\UHHHHHHHH` name a code point - outside a set, its bytes; inside one, the set becomes
a set of code points: `[a-z\u00E0-\u00FF]+`, `[^\u0000-\u007F]`. Such a set matches well-formed
UTF-8 only, and of the letter escapes it takes only `\n \r \t \f \v` (`\w` or `\x41` there is an
error). A set without an escape stays a set of bytes, so `[а-я]` is written `[\u0430-\u044F]`.
`\u` is a code-point escape anywhere in a rule (`\u12` is an error, a literal backslash and `u` is
`\\u`), and in a `%flex~` quoted pattern too: `"caf\u00e9"` is the word.

The C lexer in `examples/c_lexer/` lexes Unicode as clang 18 does by default, checked against the
table in `examples/c_lexer/unicode_cases/` (inputs, clang's token streams, gcc's verdicts):

- identifiers take `$` and the characters of C11 Annex D (D.2 not first), as UTF-8 or as UCNs
  (`caf\u00e9`, `\U0001F600`); a character Annex D excludes, a UCN naming one or a basic character,
  and a byte that is not UTF-8 - a stray continuation, a cut sequence, an overlong form, an encoded
  surrogate - end the identifier and stop the lexer with that byte's line and column;
- string and character literals take `\u` / `\U` escapes and the `u8`, `u`, `U`, `L` prefixes; their
  bytes are kept as they are, invalid UTF-8 included, as clang keeps them; an escape C11 does not
  list (`"\u00"`, `"\q"`) stops the lexer at the literal's quote, where clang lexes the literal and
  reports the escape;
- a byte order mark at offset 0 is skipped (`c_open`); U+FEFF later is an identifier character.

`examples/c_lexer/c_lex_compare.das` prints the stream of every scanner shape, of the hand-written
lexer (`--mode probe`, which takes the same identifiers, escapes and byte order mark) and of
`daslib/regex` tried rule by rule (`--mode regex`); the `regex` mode is ASCII + `$` + UCN escapes,
since `daslib/regex` has no code-point escape, so it stops at an identifier holding UTF-8.

Where clang differs: it reads U+00A0 and the other Unicode spaces as whitespace (with a warning) and
keeps an identifier whole while reporting a character Annex D excludes; the lexer stops there, as gcc
does. Under `-std=c23` clang takes `XID_Start`/`XID_Continue` instead of Annex D (no emoji). A UCN
formed by `##` or `#` is the preprocessor's and never reaches a lexer of preprocessed text. gcc takes
`\u0024` as `$` in an identifier, clang does not; the lexer follows clang.
