// Tutorial dasFlex-02: the %flex~ text form
//
// This tutorial covers:
//   - the JSON lexer of tutorial 01 written as flex-like text instead of rule() calls
//   - the header that names the scanner and the token enum
//   - start conditions, quoted literals, definitions and the action vocabulary
//
// Run: daslang -load_module <dasFlex> tutorials/02_flex_reader.das

options gen2
options indenting = 4

require flex/flex_macro

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

// `%flex~ name : Enum` at module level declares the scanner `def name(var lx : FlexLexer) : bool`,
// the same function `[flex]` would generate. Before `%rules`: `%x` / `%s` declare exclusive and
// inclusive start conditions, `NAME regex` a definition that `{NAME}` expands. After it, one rule
// per line: an optional `<CONDITION>`, the pattern - `"..."` is literal text, the rest is
// daslib/regex - and the action, daslang code in braces. In an action `emit(NAME)` emits a member
// of the header's enum, `emit(expr)` any int kind, `begin(NAME)` switches the condition, and `lx`
// is the lexer. A rule with no action skips what it matched. The text ends at `%%`.
%flex~ json_lexer : JTok
%x COMMENT
DIGITS  [0-9]+
%rules
[ \t\r\n]+
\{                                              { emit(LBRACE) }
\}                                              { emit(RBRACE) }
\[                                              { emit(LBRACKET) }
\]                                              { emit(RBRACKET) }
":"                                             { emit(COLON) }
","                                             { emit(COMMA) }
"true"                                          { emit(TRUE) }
"false"                                         { emit(FALSE) }
"null"                                          { emit(NULL) }
-?(0|[1-9][0-9]*)(\.{DIGITS})?([eE][+-]?{DIGITS})?  { emit(NUMBER) }
\"([^"\\]|\\.)*\"                               { emit(STRING) }
"/*"                                            { begin(COMMENT) }
<COMMENT>"*/"                                   { begin(INITIAL) }
<COMMENT>[^*]+
<COMMENT>\*
%%

def kind_name(kind : int) : string {
    let names <- ["", "LBRACE", "RBRACE", "LBRACKET", "RBRACKET", "COLON", "COMMA", "STRING",
                  "NUMBER", "TRUE", "FALSE", "NULL"]
    return names[kind]
}

[export]
def main() {
    let src = "\{ \"name\": \"dasFlex\", /* a comment */ \"stars\": [1, 2.5e3, -0], \"on\": true, \"off\": null \}"
    var lx : FlexLexer
    flex_open(lx, src, "demo.json")
    // The generated function is called exactly like the [flex] one.
    while (json_lexer(lx)) {
        print("{kind_name(lx.tok.kind)} {text(lx)} at {lx.tok.line}:{lx.tok.col}\n")
    }
    print("end: failed={lx.failed}\n")

    flex_open(lx, "[1, 2, \n  3 § 4]", "bad.json")
    while (json_lexer(lx)) {
    }
    print("{lx.err}\n")     // bad.json:2:5: unexpected '§'
}
