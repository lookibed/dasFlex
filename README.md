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
- `[flex(mode = "goto")]` emits the automaton as straight-line code instead of tables.
- `lx.symbols` is a `table<string; int>` a parser fills and a rule may consult.

Install: `daspkg install github.com/lookibed/dasFlex`, then `require flex/flex_macro`.
Run the tests from a daslang checkout: `daslang -load_module <dasFlex> dastest/dastest.das -- --test <dasFlex>/tests`.
Design and the rules a change must keep: `ARCHITECTURE.md`, `REVIEW.md`. A JSON lexer walk-through:
`tutorials/01_json_tokens.das`.
