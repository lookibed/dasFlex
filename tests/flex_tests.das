options gen2
options indenting = 4

require dastest/testing_boost public
require daslib/rtti
require daslib/ast
require daslib/debugger
require daslib/stringify
require strings
require daslib/strings_boost
require flex/flex_macro
require _flex_test_helpers

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
    return <- lex_tokens(lx, src, $(var l : FlexLexer) => mini(l),
                         $(var l : FlexLexer) => l.tok.kind)
}

def texts_of(src : string) : array<string> {
    var lx : FlexLexer
    return <- lex_tokens(lx, src, $(var l : FlexLexer) => mini(l), $(var l : FlexLexer) => text(l))
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
        let kinds <- lex_tokens(lx, "ab <cd 12> 34", $(var l : FlexLexer) => with_inclusive(l),
                                $(var l : FlexLexer) => l.tok.kind)
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
    let texts <- lex_tokens(lx, "x = 1\n  y § 2", $(var l : FlexLexer) => mini(l),
                            $(var l : FlexLexer) => text(l))
    t |> equal(texts, ["x", "=", "1", "y"])
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

[test(description = "the error text names a control byte, a byte that leads no UTF-8 character, the end of input, and leaves out the file when there is none")]
def test_error_text_forms(t : T?) {
    for (src, want in ["a\x01", "a\x7F", "a\xC0\x80", "a\xC1\xBF", "a\xF5\x80\x80\x80", "a\xFF"],
            ["control byte 1", "control byte 127", "byte 192", "byte 193", "byte 245",
             "byte 255"]) {
        var lx : FlexLexer
        flex_open(lx, src, "t.txt")
        while (mini(lx)) {
        }
        t |> equal(lx.err, "t.txt:1:2: unexpected {want}")
    }
    var lx : FlexLexer
    flex_open(lx, "x §")
    while (mini(lx)) {
    }
    t |> equal(lx.err, "1:3: unexpected '§'")
    flex_open(lx, "")
    t |> equal(flex_error_text(lx), "1:1: unexpected end of input")
}

//! the table-mode call matcher with the if chain: the shape every other one is compared with
let private REF_SHAPE = "mode = \"table\", matcher = \"call\", dispatch = \"if\""

//! the small lexer's rules for the shape comparison, two of them declaring the same local
let private SHAPE_RULES = %stringify~
    rule("if") {
        lx |> emit(1)
    }
    rule("[A-Za-z_][A-Za-z0-9_]*") {
        let k = 2
        lx |> emit(k)
    }
    rule("[0-9]+") {
        let k = 3
        lx |> emit(k)
    }
    rule("[ \\t\\r\\n]+") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[+*/=;()\{\}\\-]") {
        let k = 5
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
%%

//! the reference shape, then table mode with the if, goto and tree dispatch, goto mode with the same
//! three
let private EXPLICIT_SHAPES <- [REF_SHAPE, "mode = \"table\", dispatch = \"if\"",
                                "mode = \"table\", dispatch = \"goto\"",
                                "mode = \"table\", dispatch = \"tree\"",
                                "mode = \"goto\", dispatch = \"if\"",
                                "mode = \"goto\", dispatch = \"goto\"",
                                "mode = \"goto\", dispatch = \"tree\""]

[test(description = "every explicit shape - table mode with the if, goto and tree dispatch, goto mode with the same three - gives the tokens, lines, columns and errors of the table-mode call matcher")]
def test_shape_equivalence(t : T?) {
    let src = "if (x1 == 42) /* c\n * / */ y =\tiff;\n\n  z-1 /* a\nb\nc */ w"
    let res <- shape_streams("shapes.das", SHAPE_RULES, EXPLICIT_SHAPES, src, tier_is_jit())
    t |> equal(res.issues, "")
    let want := res.streams[0]
    t |> equal(want[length(want) - 2], "2@6:6:w")
    for (stream in res.streams) {
        t |> equal(stream, want)
    }
    let bad <- shape_streams("shapes_bad.das", SHAPE_RULES, EXPLICIT_SHAPES, "a\n §",
                             tier_is_jit())
    t |> equal(bad.issues, "")
    t |> equal(bad.streams[0], ["2@1:1:a", "t.txt:2:2: unexpected '§'"])
    for (stream in bad.streams) {
        t |> equal(stream, bad.streams[0])
    }
}

[test(description = "two rule bodies that declare the same local compile and lex in every mode and dispatch shape")]
def test_rule_body_scopes(t : T?) {
    let res <- shape_streams("scopes.das", SHAPE_RULES, EXPLICIT_SHAPES,
                             "if (x1 == 42) /* c * / */ y",
                             tier_is_jit())
    t |> equal(res.issues, "")
    for (stream in res.streams) {
        t |> equal(stream, res.streams[0])
    }
}

[test(description = "a call named emit whose first argument is not the lexer is the user's own function, left as written")]
def test_user_emit_untouched(t : T?) {
    user_emits |> clear()
    var lx : FlexLexer
    let kinds <- lex_tokens(lx, "1 22 333", $(var l : FlexLexer) => user_emit_lexer(l),
                            $(var l : FlexLexer) => l.tok.kind)
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

[test(description = "flex_at_end is true once the cursor has passed the last byte, not while bytes a rule may skip remain")]
def test_at_end(t : T?) {
    var lx : FlexLexer
    flex_open(lx, "ab ", "t.txt")
    t |> success(!flex_at_end(lx))
    mini(lx)
    t |> success(!flex_at_end(lx))
    t |> success(!mini(lx))
    t |> success(flex_at_end(lx))
}

[test(description = "a rule may consult lx.symbols before deciding the kind")]
def test_symbols_table(t : T?) {
    var lx : FlexLexer
    lx.symbols["size_t"] = 1
    let words <- lex_tokens(lx, "size_t n", $(var l : FlexLexer) => mini(l)) $(var l : FlexLexer) {
        return l.symbols |> key_exists(text(l)) ? "type" : "name"
    }
    t |> equal(words, ["type", "name"])
}

require flex/flex_regex
require flex/flex_dfa

def state_counts(rules : array<FlexRule>; ncond : int) : tuple<before : int; after : int> {
    let n <- build_nfa(rules, ncond)
    let raw <- build_tables(n)
    let t <- flex_tables(rules, ncond)
    return (before = raw.nstates, after = t.nstates)
}

//! rules whose subset construction yields equivalent states
let private MERGE_RULES = %stringify~
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
%%

[test(description = "a rule set whose subset construction yields equivalent states lexes the same tokens after minimization, in table and goto mode")]
def test_minimized_token_stream(t : T?) {
    let res <- shape_streams("merge.das", MERGE_RULES, ["mode = \"table\"", "mode = \"goto\""],
                             "ab cb 12 7x 0cb a", tier_is_jit())
    t |> equal(res.issues, "")
    for (stream in res.streams) {
        t |> equal(stream,
                   ["1@1:1:ab", "1@1:4:cb", "2@1:7:12", "3@1:10:7x", "2@1:13:0", "1@1:14:cb",
                            "t.txt:1:17: unexpected 'a'"])
    }
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

//! the 32 keywords of C89, each a rule of its own, then an identifier rule that also matches every one
def private keyword_rules() : array<FlexRule> {
    let words <- ["auto", "break", "case", "char", "const", "continue", "default", "do", "double",
                  "else", "enum", "extern", "float", "for", "goto", "if", "int", "long", "register",
                  "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
                  "union", "unsigned", "void", "volatile", "while"]
    var rules <- [for (w in words); FlexRule(pattern = w)]
    rules |> emplace(FlexRule(pattern = "[a-zA-Z_][a-zA-Z_0-9]*"))
    return <- rules
}

//! the rule the whole of `word` matches through `flex_match_table` over `tb`, -1 when the longest
//! match is shorter than the word
def private whole_word_rule(tb : FlexTables; word : string) : int {
    var lx : FlexLexer
    flex_open(lx, word)
    var len = 0
    let rule = flex_match_table(lx, tb.next, tb.accept, tb.class_of, tb.nclasses, tb.start[0], len)
    return len == length(word) ? rule : -1
}

[test(description = "Hopcroft's refinement keeps apart the states of 32 keyword rules and an identifier rule: 143 states, every keyword its own rule, every keyword prefix or extension an identifier")]
def test_minimized_keywords(t : T?) {
    let rules <- keyword_rules()
    let tb <- flex_tables(rules)
    t |> equal(tb.nstates, 143)
    let ident = length(rules) - 1
    for (i, r in count(), rules) {
        continue if (i == ident)
        t |> equal(whole_word_rule(tb, r.pattern), i, r.pattern)
        let short_word = slice(r.pattern, 0, length(r.pattern) - 1)
        t |> equal(whole_word_rule(tb, short_word), ident, short_word)
        t |> equal(whole_word_rule(tb, r.pattern + "x"), ident, "{r.pattern}x")
        t |> equal(whole_word_rule(tb, r.pattern + "_1"), ident, "{r.pattern}_1")
    }
}

[test(description = "`.` is one UTF-8 code point of one to four bytes, never a newline, never two code points or a malformed sequence")]
def test_dot_is_one_code_point(t : T?) {
    let tb <- flex_tables([FlexRule(pattern = ".")])
    for (word in ["a", "~", "\t", "é", "→", "😀", "\xF4\x8F\xBF\xBF"]) {
        t |> equal(whole_word_rule(tb, word), 0, word)
    }
    for (word in ["\n", "ab", "é→", "\xC0\x80", "\xE2\x86", "\xF5\x80\x80\x80", "\x80"]) {
        t |> equal(whole_word_rule(tb, word), -1, word)
    }
}

[test(description = "a regex form a DFA cannot carry is refused as not carried by dasFlex, with no pointer to an unsupported form; the tables name the refused rule's index")]
def test_refused_forms(t : T?) {
    for (pattern in ["^a", "a$", "\\ba", "a+?"]) {
        let tb <- flex_tables([FlexRule(pattern = "b"), FlexRule(pattern = pattern)])
        t |> success(find(tb.err, "does not fit a DFA and is not carried by dasFlex") >= 0, tb.err)
        t |> success(find(tb.err, "trailing context") < 0, tb.err)
        t |> equal(tb.err_rule, 1)
    }
    let unparsed <- flex_tables([FlexRule(pattern = "b"), FlexRule(pattern = "(a")])
    t |> equal(unparsed.err, "rule 1: regex '(a' does not parse")
    t |> equal(unparsed.err_rule, 1)
    let clean <- flex_tables([FlexRule(pattern = "b")])
    t |> equal(clean.err_rule, -1)
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

//! two rules with capture groups that log what their group calls return
let private GROUP_RULES = %stringify~
    rule("([a-z]+)=([0-9]+)") {
        rule_log |> push("{lx |> group(1)}|{group(lx, 2)}|{lx |> group_span(1)}|{lx |> group_span(2)}|{lx |> group(0)}")
        lx |> emit(1)
    }
    rule("(0x)?([0-9a-fA-F]+)") {
        rule_log |> push("'{lx |> group(1)}'|{lx |> group(2)}|{lx |> group_span(1)}")
        lx |> emit(2)
    }
    rule("[ ]+") {
    }
%%

//! the streams of `GROUP_RULES` over `src` in table and goto mode, each the tokens, the error text
//! and then what the group calls returned
def private group_streams(t : T?; name, src : string) : array<array<string>> {
    var res <- shape_streams(name, GROUP_RULES, ["mode = \"table\"", "mode = \"goto\""], src,
                             tier_is_jit())
    t |> equal(res.issues, "")
    return <- res.streams
}

[test(description = "group(n) is the text of capture group n of the token, group_span(n) its input bytes, group(0) the token")]
def test_group_text_and_span(t : T?) {
    for (stream in group_streams(t, "group_text.das", "ab=12  c=3")) {
        t |> equal(stream,
                   ["1@1:1:ab=12", "1@1:8:c=3", "", "ab|12|0,2|3,5|ab=12", "c|3|7,8|9,10|c=3"])
    }
}

[test(description = "a group that took no part in the match is the empty string, its span range(0, 0)")]
def test_group_not_participating(t : T?) {
    for (stream in group_streams(t, "group_absent.das", "ff 0x1a")) {
        t |> equal(stream, ["2@1:1:ff", "2@1:4:0x1a", "", "''|ff|0,0", "'0x'|1a|3,5"])
    }
}

[test(description = "two rules with groups in one lexer each re-run their own regex, in table and goto mode alike")]
def test_two_rules_with_groups(t : T?) {
    for (stream in group_streams(t, "group_two.das", "ab=1 0x2 c=3 7")) {
        t |> equal(stream, ["1@1:1:ab=1", "2@1:6:0x2", "1@1:10:c=3", "2@1:14:7", "",
                            "ab|1|0,2|3,4|ab=1", "'0x'|2|5,7", "c|3|9,10|11,12|c=3", "''|7|0,0"])
    }
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

[test(description = "group and group_span with an index below 0 or past the regex's last group panic naming the index and the group count")]
def test_group_index_out_of_range(t : T?) {
    var re <- flex_group_regex("([a-z]+)=([0-9]+)")
    var lx : FlexLexer
    flex_open(lx, "ab=12")
    flex_consume(lx, 0, 5)
    t |> equal(flex_group(lx, re, 2), "12")
    for (index in [3, -1]) {
        let why = panic_text() $ {
            let span = flex_group_span(lx, re, index)
            feint("{span}")
        }
        t |> success(find(why, "group({index}): the rule's regex has 2 groups") >= 0, why)
    }
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
    let toks <- lex_tokens(lx, "ab<12> cd<3>", $(var l : FlexLexer) => groups_with_actions(l),
                           $(var l : FlexLexer) => "{l.tok.kind}:{text(l)}@{l.tok.col}")
    t |> equal(toks, ["1:ab<@1", "2:12>@4", "1:cd<@8", "2:3>@11"])
    t |> equal(group_log, ["ab<|ab|ab<", "12|12>", "cd<|cd|cd<", "3|3>"])
    t |> success(!lx.failed)
}

//! 260 keyword rules `k0` .. `k259` emitting their index, then a blank rule
def private many_rules() : string {
    return build_string() $(var w) {
        for (i in range(260)) {
            w |> write("    rule(\"k{i}\") \{ lx |> emit({i}) \}\n")
        }
        w |> write("    rule(\" +\") \{ \}\n")
    }
}

[test(description = "the 254-rule cap binds the inline table matcher only: goto mode lexes 261 rules, table mode refuses them")]
def test_many_rules(t : T?) {
    let rules = many_rules()
    let in_goto <- shape_streams("many_goto.das", rules, ["mode = \"goto\""], "k7 k259 k130")
    t |> equal(in_goto.issues, "")
    t |> equal(in_goto.streams, [["7@1:1:k7", "259@1:4:k259", "130@1:9:k130", ""]])
    let in_table <- shape_streams("many_table.das", rules, ["mode = \"table\""], "k7")
    t |> success(find(in_table.issues, "at most 254 rules") >= 0, in_table.issues)
}

[test(description = "goto mode and the inline matcher carry the newlines inside a token to the token that follows: a string spanning lines, then a word, at the lines and columns of the call shape")]
def test_newline_inside_token(t : T?) {
    let rules = %stringify~
    rule("\"[^\"]*\"") {
        lx |> emit(1)
    }
    rule("[a-z]+") {
        lx |> emit(2)
    }
    rule("[ \\n]+") {
    }
%%
    let src = "\"a\nb\" c\n\"\n\n\" d"
    let res <- shape_streams("newline_inside.das", rules,
                             [REF_SHAPE, "mode = \"goto\", dispatch = \"if\"",
                              "mode = \"table\", matcher = \"inline\""], src, tier_is_jit())
    t |> equal(res.issues, "")
    let want <- ["1@1:1:\"a\nb\"", "2@2:4:c", "1@3:1:\"\n\n\"", "2@5:3:d", ""]
    for (stream in res.streams) {
        t |> equal(stream, want)
    }
}

[test(description = "a set holding every byte from 0 to 58 keeps the newline in a class of its own: the inline matcher and goto mode take `a b`, a newline and `c` as one token and count its line")]
def test_newline_class_inside_a_set(t : T?) {
    let rules = %stringify~
    rule("[^;]+") {
        lx |> emit(1)
    }
    rule(";") {
        lx |> emit(2)
    }
%%
    let res <- shape_streams("newline_class.das", rules,
                             [REF_SHAPE, "mode = \"table\", matcher = \"inline\"",
                              "mode = \"goto\""], "a b\nc;", tier_is_jit())
    t |> equal(res.issues, "")
    for (stream in res.streams) {
        t |> equal(stream, ["1@1:1:a b\nc", "2@2:2:;", ""])
    }
}

[test(description = "with no mode the shape follows the tier: the interpreter's table default refuses 261 rules at the inline matcher's cap, the JIT's goto default compiles them")]
def test_tier_default_mode(t : T?) {
    let text = stamped_module(many_rules(), [""])
    let interp = compile_issues("tier_interp.das", text)
    t |> success(find(interp, "at most 254 rules") >= 0, interp)
    t |> equal(compile_issues("tier_jit.das", text, true), "")
}

[test(description = "a mode, dispatch or matcher value the annotation does not know fails the compile naming the value and the ones it takes")]
def test_bad_shape_values(t : T?) {
    let rules = "    rule(\"a\") \{ lx |> emit(1) \}\n"
    for (shape, want in ["mode = \"tabel\"", "dispatch = \"switch\"", "matcher = \"loop\""],
            ["[flex] mode is table or goto, not tabel",
             "[flex] dispatch is if, goto or tree, not switch",
             "[flex] matcher is call or inline, not loop"]) {
        let res <- shape_streams("bad_shape.das", rules, [shape], "a")
        t |> success(find(res.issues, want) >= 0, res.issues)
    }
}
