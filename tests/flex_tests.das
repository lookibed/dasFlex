options gen2
options indenting = 4

require dastest/testing_boost public
require flex/flex_macro

enum TTok {
    IF = 1
    IDENT = 2
    NUM = 3
    STR = 4
    PUNCT = 5
    WORD_RU = 6
    ARROW = 7
}

[flex]
def mini(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        lx |> emit(TTok.IDENT)
    }
    rule("[0-9]+") {
        lx |> emit(TTok.NUM)
    }
    rule("\"[^\"]*\"") {
        lx |> emit(TTok.STR)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("→") {
        lx |> emit(TTok.ARROW)
    }
    rule("(а|б|в|г|д|е|ж|з|и|й|к|л|м|н|о|п|р|с|т|у|ф|х|ц|ч|ш|щ|ъ|ы|ь|э|ю|я)+") {
        lx |> emit(TTok.WORD_RU)
    }
    rule("[+*/=;()\{\}\\-]") {
        lx |> emit(TTok.PUNCT)
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

[flex(mode = "goto")]
def mini_goto(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        lx |> emit(TTok.IDENT)
    }
    rule("[0-9]+") {
        lx |> emit(TTok.NUM)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        lx |> emit(TTok.PUNCT)
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

[flex(dispatch = "goto", matcher = "inline")]
def mini_inline(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        lx |> emit(TTok.IDENT)
    }
    rule("[0-9]+") {
        lx |> emit(TTok.NUM)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        lx |> emit(TTok.PUNCT)
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

[flex]
def with_inclusive(var lx : FlexLexer) : bool {
    rule("[a-z]+") {
        lx |> emit(TTok.IDENT)
    }
    rule("<") {
        lx |> begin("ANGLE")
    }
    rule("[ ]+") {
    }
    condition("ANGLE", inclusive) {
        rule(">") {
            lx |> begin("INITIAL")
        }
        rule("[0-9]+") {
            lx |> emit(TTok.NUM)
        }
    }
}

def kinds_of(src : string; use_goto : bool = false) : array<int> {
    var lx : FlexLexer
    flex_open(lx, src, "t.txt")
    var out : array<int>
    if (use_goto) {
        while (mini_goto(lx)) {
            out |> push(lx.tok.kind)
        }
    } else {
        while (mini(lx)) {
            out |> push(lx.tok.kind)
        }
    }
    return <- out
}

def texts_of(src : string) : array<string> {
    var lx : FlexLexer
    flex_open(lx, src, "t.txt")
    var out : array<string>
    while (mini(lx)) {
        out |> push(text(lx))
    }
    return <- out
}

[test(description = "every rule of the small lexer emits its kind on its own input")]
def test_each_rule(t : T?) {
    t |> run("keyword") @(t : T?) {
        t |> equal(kinds_of("if"), [int(TTok.IF)])
    }
    t |> run("identifier") @(t : T?) {
        t |> equal(kinds_of("abc_1"), [int(TTok.IDENT)])
    }
    t |> run("number") @(t : T?) {
        t |> equal(kinds_of("42"), [int(TTok.NUM)])
    }
    t |> run("string") @(t : T?) {
        t |> equal(texts_of("\"a b\""), ["\"a b\""])
    }
    t |> run("punct") @(t : T?) {
        t |> equal(kinds_of("(x)"), [int(TTok.PUNCT), int(TTok.IDENT), int(TTok.PUNCT)])
    }
    t |> run("whitespace is skipped") @(t : T?) {
        t |> equal(kinds_of("  \t\n 7 "), [int(TTok.NUM)])
    }
}

[test(description = "the longest match wins, and on a tie the rule written first")]
def test_longest_and_priority(t : T?) {
    t |> run("iff is one identifier, not if + f") @(t : T?) {
        t |> equal(texts_of("iff"), ["iff"])
        t |> equal(kinds_of("iff"), [int(TTok.IDENT)])
    }
    t |> run("if alone is the keyword, written above the identifier rule") @(t : T?) {
        t |> equal(kinds_of("if x"), [int(TTok.IF), int(TTok.IDENT)])
    }
    t |> run("adjacent tokens split at the longest boundary") @(t : T?) {
        t |> equal(texts_of("x1=42;"), ["x1", "=", "42", ";"])
    }
}

[test(description = "an exclusive start condition hides the default rules until begin(INITIAL)")]
def test_start_conditions(t : T?) {
    t |> run("comment body produces no tokens, lexing resumes after */") @(t : T?) {
        t |> equal(kinds_of("a /* if 42 * x */ b"), [int(TTok.IDENT), int(TTok.IDENT)])
    }
    t |> run("an inclusive condition keeps the default rules and adds its own") @(t : T?) {
        var lx : FlexLexer
        flex_open(lx, "ab <cd 12> 34", "t.txt")
        var kinds : array<int>
        while (with_inclusive(lx)) {
            kinds |> push(lx.tok.kind)
        }
        // 34 outside the angle brackets matches no rule: the error is reported, not swallowed
        t |> equal(kinds, [int(TTok.IDENT), int(TTok.IDENT), int(TTok.NUM)])
        t |> success(lx.failed)
    }
}

[test(description = "UTF-8 input: multi-byte literals match, `.` and errors count one code point")]
def test_unicode(t : T?) {
    t |> run("a multi-byte literal rule") @(t : T?) {
        t |> equal(kinds_of("a → b"), [int(TTok.IDENT), int(TTok.ARROW), int(TTok.IDENT)])
    }
    t |> run("a cyrillic word as one token") @(t : T?) {
        t |> equal(texts_of("привет 1"), ["привет", "1"])
    }
    t |> run("the column counts bytes consumed; the line counts newlines") @(t : T?) {
        var lx : FlexLexer
        flex_open(lx, "→\nx", "t.txt")
        mini(lx)
        mini(lx)
        t |> equal(lx.tok.line, 2)
        t |> equal(lx.tok.col, 1)
    }
}

[test(description = "a byte no rule accepts stops the lexer with file:line:col and the character")]
def test_error_position(t : T?) {
    var lx : FlexLexer
    flex_open(lx, "x = 1\n  y § 2", "t.txt")
    var n = 0
    while (mini(lx)) {
        n++
    }
    t |> equal(n, 4)
    t |> success(lx.failed)
    t |> equal(lx.err, "t.txt:2:5: unexpected '§'")
    t |> equal(lx.tok.line, 2)
}

[test(description = "the goto-mode scanner yields the same tokens as the table-mode one")]
def test_goto_mode_equivalence(t : T?) {
    let src = "if (x1 == 42) /* c * / */ y = iff; z-1"
    t |> equal(kinds_of(src, true), kinds_of(src, false))
    var lx : FlexLexer
    flex_open(lx, "a §", "t.txt")
    while (mini_goto(lx)) {
    }
    t |> equal(lx.err, "t.txt:1:3: unexpected '§'")
}

[test(description = "the inline matcher with goto dispatch gives the same tokens, lines and columns as the table one")]
def test_inline_matcher_equivalence(t : T?) {
    let src = "if (x1 == 42) /* c\n * / */ y =\tiff;\n\n  z-1 /* a\nb\nc */ w"
    var a, b : FlexLexer
    flex_open(a, src, "t.txt")
    flex_open(b, src, "t.txt")
    var ka, kb : array<string>
    while (mini(a)) {
        ka |> push("{a.tok.kind}@{a.tok.line}:{a.tok.col}:{text(a)}")
    }
    while (mini_inline(b)) {
        kb |> push("{b.tok.kind}@{b.tok.line}:{b.tok.col}:{text(b)}")
    }
    t |> equal(kb, ka)
    t |> equal(ka[length(ka) - 1], "2@6:6:w")
    flex_open(b, "a\n §", "t.txt")
    while (mini_inline(b)) {
    }
    t |> equal(b.err, "t.txt:2:2: unexpected '§'")
}

[test(description = "text() returns the matched bytes and text_is compares without allocating")]
def test_text_access(t : T?) {
    var lx : FlexLexer
    flex_open(lx, "hello 12", "t.txt")
    mini(lx)
    t |> equal(text(lx), "hello")
    t |> success(text_is(lx, "hello"))
    t |> success(!text_is(lx, "hell"))
    t |> success(!text_is(lx, "hello!"))
    t |> equal(lx.tok.start, 0)
    t |> equal(lx.tok.len, 5)
}

[test(description = "a rule may consult lx.symbols before deciding the kind")]
def test_symbols_table(t : T?) {
    var lx : FlexLexer
    lx.symbols["size_t"] = 1
    flex_open(lx, "size_t n", "t.txt")
    var words : array<string>
    while (mini(lx)) {
        words |> push(lx.symbols |> key_exists(text(lx)) ? "type" : "name")
    }
    t |> equal(words, ["type", "name"])
}
