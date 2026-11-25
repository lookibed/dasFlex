// Tutorial dasFlex-01: JSON tokens
//
// This tutorial covers:
//   - writing a lexer as a [flex] function of rules
//   - emitting a token kind, skipping whitespace, the longest match
//   - a start condition for a multi-line comment
//   - reading the token's text and position, and the error a bad byte produces
//
// Run: daslang -load_module <dasFlex> tutorials/01_json_tokens.das

options gen2
options indenting = 4

require flex/flex_macro
require daslib/enum_trait

// The token kinds the parser will see. Any enum works: emit() stores int(kind).
enum JTok {
    LBRACE = 1
    RBRACE = 2
    LBRACKET = 3
    RBRACKET = 4
    COLON = 5
    COMMA = 6
    STRING = 7
    NUMBER = 8
    TRUE = 9
    FALSE = 10
    NULL = 11
}

// One rule per token. The regex is a string in daslib/regex syntax; the block is the action and
// runs with `lx` - the function's own parameter - in scope. A block that does not emit is a skip.
// When two rules match the same longest text, the one written first wins: `true` sits above a
// catch-all identifier rule here so it never lexes as a word.
[flex]
def json_lexer(var lx : FlexLexer) : bool {
    rule("[ \\t\\r\\n]+") {
    }
    rule("\\\{") {
        lx |> emit(JTok.LBRACE)
    }
    rule("\\\}") {
        lx |> emit(JTok.RBRACE)
    }
    rule("\\[") {
        lx |> emit(JTok.LBRACKET)
    }
    rule("\\]") {
        lx |> emit(JTok.RBRACKET)
    }
    rule(":") {
        lx |> emit(JTok.COLON)
    }
    rule(",") {
        lx |> emit(JTok.COMMA)
    }
    rule("true") {
        lx |> emit(JTok.TRUE)
    }
    rule("false") {
        lx |> emit(JTok.FALSE)
    }
    rule("null") {
        lx |> emit(JTok.NULL)
    }
    rule("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?") {
        lx |> emit(JTok.NUMBER)
    }
    rule("\"([^\"\\\\]|\\\\.)*\"") {
        lx |> emit(JTok.STRING)
    }
    // JSON has no comments, but a config dialect often does: `/*` switches to an exclusive start
    // condition whose rules alone are active until `*/` switches back.
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    condition("COMMENT", exclusive) {
        rule("\\*/") {
            lx |> begin("INITIAL")
        }
        rule("[^*]+") {
        }
        rule("\\*") {
        }
    }
}

// enum_trait's each() walks an enum's members and string() names one: the kind's name to print
let KIND_NAMES <- { for (k in each(type<JTok>)); int(k) => string(k) }

def kind_name(kind : int) : string => KIND_NAMES?[kind] ?? "{kind}"

[export]
def main() {
    let src = "\{ \"name\": \"dasFlex\", /* a comment */ \"stars\": [1, 2.5e3, -0], \"on\": true, \"off\": null \}"
    var lx : FlexLexer
    flex_open(lx, src, "demo.json")
    // Each call to the lexer function scans up to the next emitted token and returns true; `lx.tok`
    // holds its kind, byte span and position. text() builds the token's string only when asked.
    while (json_lexer(lx)) {
        print("{kind_name(lx.tok.kind)} {text(lx)} at {lx.tok.line}:{lx.tok.col}\n")
    }
    // It returns false at the end of input - or on a byte no rule accepts, with the position.
    print("end: failed={lx.failed}\n")

    flex_open(lx, "[1, 2, \n  3 § 4]", "bad.json")
    while (json_lexer(lx)) {
    }
    print("{lx.err}\n")     // bad.json:2:5: unexpected '§'
}
