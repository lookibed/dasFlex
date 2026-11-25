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

Install: `daspkg install github.com/lookibed/dasFlex`, then `require flex/flex_macro`.
Run the tests from a daslang checkout: `daslang -load_module <dasFlex> dastest/dastest.das -- --test <dasFlex>/tests`.
Design and the rules a change must keep: `ARCHITECTURE.md`, `REVIEW.md`. A JSON lexer walk-through:
`tutorials/01_json_tokens.das`, the same lexer in `%flex~` form: `tutorials/02_flex_reader.das`,
capture groups: `tutorials/03_groups.das`.

## Unicode

The automaton reads UTF-8 bytes. A literal past ASCII is its bytes, `.` is one code point, and
`\uHHHH` / `\UHHHHHHHH` name a code point - outside a set, its bytes; inside one, the set becomes
a set of code points: `[a-z\u00E0-\u00FF]+`, `[^\u0000-\u007F]`. Such a set matches well-formed
UTF-8 only. A set without an escape stays a set of bytes, so `[а-я]` is written
`[\u0430-\u044F]`.

The C lexer in `examples/c_lexer/` lexes Unicode as clang 18 does by default, checked against the
table in `examples/c_lexer/unicode_cases/` (inputs, clang's token streams, gcc's verdicts):

- identifiers take `$` and the characters of C11 Annex D (D.2 not first), as UTF-8 or as UCNs
  (`caf\u00e9`, `\U0001F600`); a character Annex D excludes, a UCN naming one or a basic character,
  and a byte that is not UTF-8 - a stray continuation, a cut sequence, an overlong form, an encoded
  surrogate - end the identifier and stop the lexer with that byte's line and column;
- string and character literals take `\u` / `\U` escapes and the `u8`, `u`, `U`, `L` prefixes; their
  bytes are kept as they are, invalid UTF-8 included, as clang keeps them;
- a byte order mark at offset 0 is skipped (`c_open`); U+FEFF later is an identifier character.

Where clang differs: it reads U+00A0 and the other Unicode spaces as whitespace (with a warning) and
keeps an identifier whole while reporting a character Annex D excludes; the lexer stops there, as gcc
does. Under `-std=c23` clang takes `XID_Start`/`XID_Continue` instead of Annex D (no emoji). A UCN
formed by `##` or `#` is the preprocessor's and never reaches a lexer of preprocessed text. gcc takes
`\u0024` as `$` in an identifier, clang does not; the lexer follows clang.
