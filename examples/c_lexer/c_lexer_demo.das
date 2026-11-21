options gen2
options indenting = 4

// Lex a C snippet with the dasFlex C11 lexer and print every token with its position.

require c_lexer

[export]
def main() {
    var lx : FlexLexer
    lx.symbols["size_t"] = 1
    let src = "typedef unsigned long size_t; /* c */ static inline int f(size_t n) \{ return n >= 0x1fUL ? 1.5e3f : 'a'; \} // x\nchar *s = u8\"hi\\n\" L\"x\";"
    flex_open(lx, src, "demo.c")
    var n = 0
    while (c_next(lx)) {
        print("{c_token_name(lx.tok.kind)} '{text(lx)}' {lx.tok.line}:{lx.tok.col}\n")
        n++
    }
    print("tokens={n} failed={lx.failed} err='{lx.err}'\n")
}
