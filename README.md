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
  `begin(NAME)` switches the condition, and `lx` is the lexer (`text(lx)`, `lx.symbols`).
- Errors - a bad regex, an unknown condition or token - are reported at the rule's line.

Install: `daspkg install github.com/lookibed/dasFlex`, then `require flex/flex_macro`.
Run the tests from a daslang checkout: `daslang -load_module <dasFlex> dastest/dastest.das -- --test <dasFlex>/tests`.
Design and the rules a change must keep: `ARCHITECTURE.md`, `REVIEW.md`. A JSON lexer walk-through:
`tutorials/01_json_tokens.das`, and the same lexer in `%flex~` form: `tutorials/02_flex_reader.das`.
