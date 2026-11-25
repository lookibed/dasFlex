options gen2
options indenting = 4

require dastest/testing_boost public
require daslib/rtti
require daslib/ast
require daslib/debugger
require strings
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

[flex(mode = "table", dispatch = "if", matcher = "call")]
def mini_call(var lx : FlexLexer) : bool {
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

[flex(mode = "table", dispatch = "if")]
def shape_table_if(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        let k = TTok.IDENT
        lx |> emit(k)
    }
    rule("[0-9]+") {
        let k = TTok.NUM
        lx |> emit(k)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        let k = TTok.PUNCT
        lx |> emit(k)
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

[flex(mode = "table", dispatch = "goto")]
def shape_table_goto(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        let k = TTok.IDENT
        lx |> emit(k)
    }
    rule("[0-9]+") {
        let k = TTok.NUM
        lx |> emit(k)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        let k = TTok.PUNCT
        lx |> emit(k)
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

[flex(mode = "table", dispatch = "tree")]
def shape_table_tree(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        let k = TTok.IDENT
        lx |> emit(k)
    }
    rule("[0-9]+") {
        let k = TTok.NUM
        lx |> emit(k)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        let k = TTok.PUNCT
        lx |> emit(k)
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

[flex(mode = "goto", dispatch = "if")]
def shape_goto_if(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        let k = TTok.IDENT
        lx |> emit(k)
    }
    rule("[0-9]+") {
        let k = TTok.NUM
        lx |> emit(k)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        let k = TTok.PUNCT
        lx |> emit(k)
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

[flex(mode = "goto", dispatch = "goto")]
def shape_goto_goto(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        let k = TTok.IDENT
        lx |> emit(k)
    }
    rule("[0-9]+") {
        let k = TTok.NUM
        lx |> emit(k)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        let k = TTok.PUNCT
        lx |> emit(k)
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

[flex(mode = "goto", dispatch = "tree")]
def shape_goto_tree(var lx : FlexLexer) : bool {
    rule("if") {
        lx |> emit(TTok.IF)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        let k = TTok.IDENT
        lx |> emit(k)
    }
    rule("[0-9]+") {
        let k = TTok.NUM
        lx |> emit(k)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        let k = TTok.PUNCT
        lx |> emit(k)
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

// what the user's own `emit` below received
var private user_emits : array<int>

def private emit(var a : array<int>; v : int) {
    a |> push(v)
}

[flex]
def user_emit_lexer(var lx : FlexLexer) : bool {
    rule("[0-9]+") {
        emit(user_emits, lx.tok.len)
        lx |> emit(TTok.NUM)
    }
    rule(" +") {
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

def kinds_of(src : string) : array<int> {
    var lx : FlexLexer
    flex_open(lx, src, "t.txt")
    var out : array<int>
    while (mini(lx)) {
        out |> push(lx.tok.kind)
    }
    return <- out
}

def next_of(var lx : FlexLexer; shape : string) : bool {
    if (shape == "call") {
        return mini_call(lx)
    } elif (shape == "table_if") {
        return shape_table_if(lx)
    } elif (shape == "table_goto") {
        return shape_table_goto(lx)
    } elif (shape == "table_tree") {
        return shape_table_tree(lx)
    } elif (shape == "goto_if") {
        return shape_goto_if(lx)
    } elif (shape == "goto_goto") {
        return shape_goto_goto(lx)
    } elif (shape == "goto_tree") {
        return shape_goto_tree(lx)
    }
    return mini(lx)
}

//! the tokens of `src` as `kind@line:col:text` from one shape of the small lexer, then the error text
def stream_of(src, shape : string) : array<string> {
    var lx : FlexLexer
    flex_open(lx, src, "t.txt")
    var out : array<string>
    while (next_of(lx, shape)) {
        out |> push("{lx.tok.kind}@{lx.tok.line}:{lx.tok.col}:{text(lx)}")
    }
    out |> push(lx.err)
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

[test(description = "a lead byte without its continuation bytes is reported as a byte, not as a character")]
def test_error_bad_utf8(t : T?) {
    for (src in ["a\xC3A", "a\xE2\x86", "a\xE2\x86A", "a\xF0\x9F\x98"]) {
        var lx : FlexLexer
        flex_open(lx, src, "t.txt")
        while (mini(lx)) {
        }
        t |> equal(lx.err, "t.txt:1:2: unexpected byte {int(unsafe(lx.data[1]))}")
    }
}

[test(description = "every explicit shape - table mode with the if, goto and tree dispatch, goto mode with the same three - gives the tokens, lines, columns and errors of the table-mode call matcher")]
def test_shape_equivalence(t : T?) {
    let src = "if (x1 == 42) /* c\n * / */ y =\tiff;\n\n  z-1 /* a\nb\nc */ w"
    let want <- stream_of(src, "call")
    t |> equal(want[length(want) - 2], "2@6:6:w")
    let want_bad <- stream_of("a\n §", "call")
    t |> equal(want_bad[length(want_bad) - 1], "t.txt:2:2: unexpected '§'")
    for (shape in ["table_if", "table_goto", "table_tree", "goto_if", "goto_goto", "goto_tree"]) {
        t |> equal(stream_of(src, shape), want)
        t |> equal(stream_of("a\n §", shape), want_bad)
    }
}

[test(description = "two rule bodies that declare the same local compile and lex in every mode and dispatch shape")]
def test_rule_body_scopes(t : T?) {
    let src = "if (x1 == 42) /* c * / */ y"
    let want <- stream_of(src, "call")
    for (shape in ["table_if", "table_goto", "table_tree", "goto_if", "goto_goto", "goto_tree"]) {
        t |> equal(stream_of(src, shape), want)
    }
}

[test(description = "a call named emit whose first argument is not the lexer is the user's own function, left as written")]
def test_user_emit_untouched(t : T?) {
    user_emits |> clear()
    var lx : FlexLexer
    flex_open(lx, "1 22 333", "t.txt")
    var kinds : array<int>
    while (user_emit_lexer(lx)) {
        kinds |> push(lx.tok.kind)
    }
    t |> equal(kinds, [int(TTok.NUM), int(TTok.NUM), int(TTok.NUM)])
    t |> equal(user_emits, [1, 2, 3])
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

[flex(mode = "table")]
def merge_table(var lx : FlexLexer) : bool {
    rule("ab|cb") {
        lx |> emit(1)
    }
    rule("[0-9]+") {
        lx |> emit(2)
    }
    rule("[0-9]+x") {
        lx |> emit(3)
    }
    rule(" +") {
    }
}

[flex(mode = "goto")]
def merge_goto(var lx : FlexLexer) : bool {
    rule("ab|cb") {
        lx |> emit(1)
    }
    rule("[0-9]+") {
        lx |> emit(2)
    }
    rule("[0-9]+x") {
        lx |> emit(3)
    }
    rule(" +") {
    }
}

def merge_stream(src : string; use_goto : bool) : array<string> {
    var lx : FlexLexer
    flex_open(lx, src, "t.txt")
    var out : array<string>
    while (use_goto ? merge_goto(lx) : merge_table(lx)) {
        out |> push("{lx.tok.kind}:{text(lx)}")
    }
    out |> push(lx.err)
    return <- out
}

require flex/flex_regex
require flex/flex_dfa

def state_counts(rules : array<FlexRule>; ncond : int) : tuple<before : int; after : int> {
    let n <- build_nfa(rules, ncond)
    let raw <- build_tables(n)
    let t <- flex_tables(rules, ncond)
    return (before = raw.nstates, after = t.nstates)
}

[test(description = "a rule set whose subset construction yields equivalent states lexes the same tokens after minimization")]
def test_minimized_token_stream(t : T?) {
    let want <- ["1:ab", "1:cb", "2:12", "3:7x", "2:0", "1:cb", "t.txt:1:17: unexpected 'a'"]
    let src = "ab cb 12 7x 0cb a"
    t |> equal(merge_stream(src, false), want)
    t |> equal(merge_stream(src, true), want)
}

[test(description = "minimization merges equivalent states down to the hand-computed minimum and keeps the tables dense")]
def test_minimized_state_counts(t : T?) {
    let alt = state_counts([FlexRule(pattern = "ab|cb")], 1)
    t |> equal(alt.after, 3)
    t |> success(alt.after < alt.before)
    let num = state_counts([FlexRule(pattern = "[0-9]+"), FlexRule(pattern = "[0-9]+x")], 1)
    t |> equal(num.after, 3)
    t |> success(num.after < num.before)
    let tb <- flex_tables([FlexRule(pattern = "[0-9]+"), FlexRule(pattern = "[0-9]+x")])
    t |> equal(tb.accept, [-1, 0, 1])
    t |> equal(length(tb.next), tb.nstates * tb.nclasses)
    t |> equal(length(tb.class_of), 256)
    for (nx in tb.next) {
        t |> success(nx >= -1 && nx < tb.nstates)
    }
}

[test(description = "start states of two conditions merge when their languages coincide and stay apart when they differ")]
def test_minimized_start_states(t : T?) {
    let same <- flex_tables([FlexRule(pattern = "ab|cb", conditions = [0, 1])], 2)
    t |> equal(same.nstates, 3)
    t |> equal(same.start, [0, 0])
    let diff <- flex_tables([FlexRule(pattern = "ab|cb", conditions = [0, 1]),
                             FlexRule(pattern = "d", conditions = [0])], 2)
    t |> equal(diff.nstates, 5)
    t |> equal(diff.start, [0, 1])
}

// what the rule bodies of the group lexers below saw, one line per token
var private group_log : array<string>

[flex]
def groups_kv(var lx : FlexLexer) : bool {
    rule("([a-z]+)=([0-9]+)") {
        group_log |> push("{lx |> group(1)}|{group(lx, 2)}|{lx |> group_span(1)}|{lx |> group_span(2)}|{lx |> group(0)}")
        lx |> emit(1)
    }
    rule("(0x)?([0-9a-fA-F]+)") {
        group_log |> push("'{lx |> group(1)}'|{lx |> group(2)}|{lx |> group_span(1)}")
        lx |> emit(2)
    }
    rule("[ ]+") {
    }
}

[flex(mode = "goto")]
def groups_kv_goto(var lx : FlexLexer) : bool {
    rule("([a-z]+)=([0-9]+)") {
        group_log |> push("{lx |> group(1)}|{group(lx, 2)}|{lx |> group_span(1)}|{lx |> group_span(2)}|{lx |> group(0)}")
        lx |> emit(1)
    }
    rule("(0x)?([0-9a-fA-F]+)") {
        group_log |> push("'{lx |> group(1)}'|{lx |> group(2)}|{lx |> group_span(1)}")
        lx |> emit(2)
    }
    rule("[ ]+") {
    }
}

//! `group_log` after lexing `src` with the table or the goto shape, then `kind:text` per token
def group_stream(src : string; use_goto : bool) : array<string> {
    group_log |> clear()
    var lx : FlexLexer
    flex_open(lx, src, "t.txt")
    var kinds : array<string>
    while (use_goto ? groups_kv_goto(lx) : groups_kv(lx)) {
        kinds |> push("{lx.tok.kind}:{text(lx)}")
    }
    var out <- group_log
    out |> push_from(kinds)
    out |> push(lx.err)
    return <- out
}

[test(description = "group(n) is the text of capture group n of the token, group_span(n) its input bytes, group(0) the token")]
def test_group_text_and_span(t : T?) {
    t |> equal(group_stream("ab=12  c=3", false),
               ["ab|12|0,2|3,5|ab=12", "c|3|7,8|9,10|c=3", "1:ab=12", "1:c=3", ""])
}

[test(description = "a group that took no part in the match is the empty string, its span range(0, 0)")]
def test_group_not_participating(t : T?) {
    t |> equal(group_stream("ff 0x1a", false),
               ["''|ff|0,0", "'0x'|1a|3,5", "2:ff", "2:0x1a", ""])
}

[test(description = "two rules with groups in one lexer each re-run their own regex, in table and goto mode alike")]
def test_two_rules_with_groups(t : T?) {
    let src = "ab=1 0x2 c=3 7"
    let want <- ["ab|1|0,2|3,4|ab=1", "'0x'|2|5,7", "c|3|9,10|11,12|c=3", "''|7|0,0",
                 "1:ab=1", "2:0x2", "1:c=3", "2:7", ""]
    t |> equal(group_stream(src, false), want)
    t |> equal(group_stream(src, true), want)
}

[flex]
def groups_cached(var lx : FlexLexer) : bool {
    rule("([a-z]+)=([0-9]+)") {
        let first = lx |> group_span(1)
        lx.groups[1] = range(100, 101)
        group_log |> push("{first}|{lx |> group_span(1)}")
        lx |> emit(1)
    }
    rule("[0-9]+") {
        lx |> emit(2)
    }
    rule("[ ]+") {
    }
}

[test(description = "a token's groups are matched on the first group call and reused by the next; a rule without group calls runs no regex")]
def test_group_match_once(t : T?) {
    group_log |> clear()
    var lx : FlexLexer
    flex_open(lx, "a=1 bc=2", "t.txt")
    while (groups_cached(lx)) {
    }
    // the second call reads the slot the first one filled, not a second match
    t |> equal(group_log, ["0,1|100,101", "4,6|100,101"])
    flex_open(lx, "12 34", "t.txt")
    while (groups_cached(lx)) {
    }
    t |> equal(lx.groups_re, 0ul)
}

[flex]
def groups_lazy(var lx : FlexLexer) : bool {
    rule("([a-z]+)([a-z]*)") {
        group_log |> push("{lx |> group(1)}|{lx |> group(2)}")
        lx |> emit(1)
    }
}

[test(description = "KNOWN LIMIT of the re-match path on daslang 0.6.6: daslib/regex runs a greedy + before a * lazily, so group 1 of ([a-z]+)([a-z]*) on abc is a, not abc; the token is right")]
def test_group_lazy_quirk(t : T?) {
    group_log |> clear()
    var lx : FlexLexer
    flex_open(lx, "abc", "t.txt")
    t |> success(groups_lazy(lx))
    t |> equal(text(lx), "abc")
    // a daslib/regex with greedy quantifiers gives "abc|"; this binary gives the short group
    t |> equal(group_log, ["a|bc"])
}

[flex]
def groups_with_actions(var lx : FlexLexer) : bool {
    rule("([a-z]+)<") {
        group_log |> push("{text(lx)}|{lx |> group(1)}|{text(lx)}")
        lx |> begin("ANGLE")
        lx |> emit(1)
    }
    rule("[ ]+") {
    }
    condition("ANGLE", exclusive) {
        rule("([0-9]+)>") {
            group_log |> push("{lx |> group(1)}|{text(lx)}")
            lx |> begin("INITIAL")
            lx |> emit(2)
        }
    }
}

[test(description = "text(), emit and begin behave as before in a rule that calls group")]
def test_group_with_text_emit_begin(t : T?) {
    group_log |> clear()
    var lx : FlexLexer
    flex_open(lx, "ab<12> cd<3>", "t.txt")
    var toks : array<string>
    while (groups_with_actions(lx)) {
        toks |> push("{lx.tok.kind}:{text(lx)}@{lx.tok.col}")
    }
    t |> equal(toks, ["1:ab<@1", "2:12>@4", "1:cd<@8", "2:3>@11"])
    t |> equal(group_log, ["ab<|ab|ab<", "12|12>", "cd<|cd|cd<", "3|3>"])
    t |> success(!lx.failed)
}

//! a module with a lexer of `nrules` keyword rules `k0`, `k1`, ... under `shape` and an exported
//! `run` that lexes `src` and packs the kinds three decimal digits each
def private many_rules_module(nrules : int; shape, src : string) : string {
    return build_string() $(var w) {
        w |> write("options gen2\nrequire flex/flex_macro\n[flex({shape})]\n")
        w |> write("def many(var lx : FlexLexer) : bool \{\n")
        for (i in range(nrules)) {
            w |> write("    rule(\"k{i}\") \{ lx |> emit({i}) \}\n")
        }
        w |> write("    rule(\" +\") \{ \}\n\}\n")
        w |> write("[export]\ndef run(var out : int?) \{\n    var lx : FlexLexer\n")
        w |> write("    flex_open(lx, \"{src}\")\n    *out = 0\n")
        w |> write("    while (many(lx)) \{\n        *out = *out * 1000 + lx.tok.kind\n    \}\n\}\n")
    }
}

//! compiles `text` as the virtual file `name` and calls its `run`: the issues, or "" and the result
def private compile_and_run(name, text : string) : tuple<issues : string; result : int> {
    var res = (issues = "", result = -1)
    var inscope access <- make_file_access("")
    set_file_source(access, name, text)
    using() $(var mg : ModuleGroup) {
        using() $(var cop : CodeOfPolicies) {
            cop.threadlock_context = true
            compile_file(name, access, unsafe(addr(mg)), cop) $(ok; program; issues) {
                res.issues = string(issues)
                return if (!ok)
                simulate(program) $(sok; context; serrors) {
                    res.issues = sok ? "" : string(serrors)
                    return if (!sok)
                    var out = 0
                    unsafe {
                        *context |> invoke_in_context("run", addr(out))
                    }
                    res.result = out
                }
            }
        }
    }
    return res
}

[test(description = "the 254-rule cap binds the inline table matcher only: goto mode lexes 261 rules, table mode refuses them")]
def test_many_rules(t : T?) {
    let src = "k7 k259 k130"
    let in_goto = compile_and_run("many_goto.das", many_rules_module(260, "mode = \"goto\"", src))
    t |> equal(in_goto.issues, "")
    t |> equal(in_goto.result, 7259130)
    let table_src = many_rules_module(260, "mode = \"table\"", src)
    let in_table = compile_and_run("many_table.das", table_src)
    t |> success(find(in_table.issues, "at most 254 rules") >= 0, in_table.issues)
}

