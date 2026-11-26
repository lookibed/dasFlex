options gen2
options indenting = 4

require dastest/testing_boost public
require daslib/fio
require daslib/rtti
require daslib/strings_boost
require strings
require math
require _flex_test_helpers
require ../examples/c_lexer/c_lexer.das
require ../examples/c_lexer/c_lexer_variants.das
require ../examples/c_lexer/c_lexer_goto.das
require ../examples/c_lexer/c_lexer_reader.das
require ../examples/c_lexer/gen_variants.das
require ../examples/c_lexer/c_lex_compare.das

// The C lexer example against the Unicode case table in examples/c_lexer/unicode_cases/cases.txt:
// every in-scope case's input lexed by every scanner shape gives clang's token stream, and the
// other lexers of c_lex_compare.das give the stream of the rules. Its identifiers: keywords and
// typedef names as kinds of symbols, and a scan that builds no string for them.

//! one token of clang's stream: its kind name and byte range
struct CaseTok {
    kind : string
    start : int
    len : int
}

//! one case of the table
struct UnicodeCase {
    name : string
    lexer : string      //!< "clang", "error N" or "none - why"
    tokens : array<CaseTok>
}

//! the path of `name` under examples/c_lexer/
def example_path(name : string) : string => path_join(dir_name(string(get_line_info().fileInfo.name)), "../examples/c_lexer/{name}")

def cases_dir() : string => example_path("unicode_cases")

def read_cases() : array<UnicodeCase> {
    var cases : array<UnicodeCase>
    for (line in split(fread(path_join(cases_dir(), "cases.txt")), "\n")) {
        var inscope cols <- split(line, "\t")
        continue if (length(cols) < 2)
        if (cols[0] == "case") {
            cases |> emplace(UnicodeCase(name = cols[1]))
        } elif (cols[0] == "lexer") {
            cases[length(cases) - 1].lexer = cols[1]
        } elif (cols[0] == "tok") {
            cases[length(cases) - 1].tokens |> push(CaseTok(kind = cols[1], start = to_int(cols[2]), len = to_int(cols[3])))
        }
    }
    return <- cases
}

let private PUNCT_NAMES <- {
    ';' => "semi", '=' => "equal", ',' => "comma", '*' => "star", '(' => "l_paren", ')' => "r_paren",
    '{' => "l_brace", '}' => "r_brace", '[' => "l_square", ']' => "r_square"
}

//! the literal's encoding prefix: what stands before its first quote
def private literal_prefix(text : string; quote : int) : string => slice(text, 0, find(text, quote))

let private CHAR_KINDS <- {
    "" => "char_constant", "L" => "wide_char_constant", "u" => "utf16_char_constant",
    "U" => "utf32_char_constant", "u8" => "utf8_char_constant"
}

let private STRING_KINDS <- {
    "" => "string_literal", "L" => "wide_string_literal", "u" => "utf16_string_literal",
    "U" => "utf32_string_literal", "u8" => "utf8_string_literal"
}

//! clang's kind name for the lexer's token of kind `kind` and text `text`
def clang_kind(kind : int; text : string) : string {
    if (kind == int(CTok.IDENTIFIER) || kind == int(CTok.TYPEDEF_NAME)) {
        return "identifier"
    } elif (kind == int(CTok.STRING_LITERAL)) {
        return STRING_KINDS?[literal_prefix(text, '"')] ?? "?"
    } elif (kind == int(CTok.I_CONSTANT) && find(text, '\'') >= 0) {
        return CHAR_KINDS?[literal_prefix(text, '\'')] ?? "?"
    } elif (kind == int(CTok.I_CONSTANT) || kind == int(CTok.F_CONSTANT)) {
        return "numeric_constant"
    } elif (KEYWORDS |> key_exists(text)) {
        return text
    }
    return PUNCT_NAMES?[kind] ?? c_token_name(kind)
}

//! the stream the table expects from the lexer: `kind start len` per token, then `error N` when
//! the lexer is to fail at byte N
def expected_stream(c : UnicodeCase) : array<string> {
    let cut = starts_with(c.lexer, "error ") ? to_int(slice(c.lexer, 6)) : -1
    var out : array<string>
    for (tok in c.tokens) {
        continue if (cut >= 0 && tok.start >= cut)
        let len = cut >= 0 ? min(tok.len, cut - tok.start) : tok.len
        let literal = ends_with(tok.kind, "string_literal") || ends_with(tok.kind, "char_constant")
        out |> push("{len < tok.len && literal ? "identifier" : tok.kind} {tok.start} {len}")
    }
    if (cut >= 0) {
        out |> push("error {cut}")
    }
    return <- out
}

//! the lexer's stream over `src` in `shape`, in the form of `expected_stream`
def lexed_stream(src, shape : string) : array<string> {
    var lx : FlexLexer
    c_open(lx, src)
    var out : array<string>
    let scan = c_scanner(shape)
    while (invoke(scan, lx)) {
        let spelling = text(lx)
        out |> push("{clang_kind(lx.tok.kind, spelling)} {lx.tok.start} {lx.tok.len}")
    }
    if (lx.failed) {
        out |> push("error {lx.pos}")
    }
    return <- out
}

[test(description = "every in-scope case of the Unicode table lexes, in every scanner shape, to clang's stream: kinds, byte ranges, and the byte where the lexer fails")]
def test_unicode_case_table(t : T?) {
    let cases <- read_cases()
    t |> success(length(cases) >= 30, "{length(cases)} cases read")
    var checked = 0
    for (c in cases) {
        continue if (starts_with(c.lexer, "none"))
        checked++
        let src = fread(path_join(cases_dir(), "{c.name}.c"))
        var inscope want <- expected_stream(c)
        for (shape in C_SHAPES) {
            t |> equal(lexed_stream(src, shape), want, "{c.name} ({shape})")
        }
    }
    t |> success(checked >= 25, "{checked} cases in scope")
}

//! whether `src` lexes as one identifier spanning it, in the default shape
def private one_identifier(src : string) : bool {
    var lx : FlexLexer
    c_open(lx, src)
    return c_next(lx) && lx.tok.kind == int(CTok.IDENTIFIER) && lx.tok.len == length(src) && !c_next(lx) && !lx.failed
}

[test(description = "at both ends of every Annex D.1 and D.2 range, and one past them, a code point inside an identifier and at its start lexes as one identifier exactly when C11 allows it there")]
def test_annex_d_boundaries(t : T?) {
    var probes : array<int>
    for (r in C11_IDENT_RANGES) {
        probes |> push_from([int(r.x) - 1, int(r.x), int(r.y), int(r.y) + 1])
    }
    for (r in C11_NOT_INITIAL) {
        probes |> push_from([int(r.x) - 1, int(r.x), int(r.y), int(r.y) + 1])
    }
    for (cp in probes) {
        continue if (cp < 0x80 || (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF)
        let ch = utf8_of(cp)
        t |> equal(one_identifier("a{ch}"), c11_ident_char(cp, false), "a U+{fmt(":X", cp)}")
        t |> equal(one_identifier("{ch}a"), c11_ident_char(cp, true), "U+{fmt(":X", cp)} a")
        let ucn = cp > 0xFFFF ? "\\U{fmt(":08X", cp)}" : "\\u{fmt(":04X", cp)}"
        t |> equal(one_identifier("a{ucn}"), c11_ident_char(cp, false), "a {ucn}")
    }
}

//! the default shape's tokens over `src` as `text` each, then `error N` when the lexer fails at byte N
def private default_stream(src : string) : array<string> {
    var lx : FlexLexer
    c_open(lx, src)
    var out : array<string>
    while (c_next(lx)) {
        out |> push(text(lx))
    }
    if (lx.failed) {
        out |> push("error {lx.pos}")
    }
    return <- out
}

[test(description = "a UCN whose value is past U+10FFFF, eight hex digits F included, ends the identifier before it, and stops the lexer when it opens one")]
def test_ucn_past_unicode(t : T?) {
    t |> equal(default_stream("a\\UFFFFFFFF"), ["a", "error 1"])
    t |> equal(default_stream("a\\U00110000 b"), ["a", "error 1"])
    t |> equal(default_stream("\\UFFFFFFFF"), ["error 0"])
    t |> equal(default_stream("a\\U000EFFFD"), ["a\\U000EFFFD"])
}

//! the code points of Annex D.1 that D.2 leaves, as ranges: the start set of an identifier
def private start_ranges() : array<uint2> {
    var out : array<uint2>
    for (r in C11_IDENT_RANGES) {
        var lo = r.x
        for (x in C11_NOT_INITIAL) {
            continue if (x.y < lo || x.x > r.y)
            out |> push(uint2(lo, x.x - 1u)) if (x.x > lo)
            lo = max(lo, x.y + 1u)
        }
        out |> push(uint2(lo, r.y)) if (lo <= r.y)
    }
    return <- out
}

//! a code point as a regex escape: `\uHHHH`, or `\UHHHHHHHH` past the BMP
def private cp_escape(cp : uint) : string => cp > 0xFFFFu ? "\\U{fmt(":08X", cp)}" : "\\u{fmt(":04X", cp)}"

//! the regex set of the ASCII characters `ascii` and the code-point ranges `ranges`
def private set_text(ascii : string; ranges : array<uint2>) : string {
    let items = join([for (r in ranges); r.x == r.y ? cp_escape(r.x) : "{cp_escape(r.x)}-{cp_escape(r.y)}"], "")
    return "[{ascii}{items}]"
}

[test(description = "the identifier sets of c_lexer.das's rule and of the reader's L and A definitions are exactly the Annex D tables c_ident_cut reads: D.1 minus D.2 to start, D.1 to continue")]
def test_annex_d_sets_match_tables(t : T?) {
    var inscope ident <- [for (r in C11_IDENT_RANGES); r]
    let start = set_text("a-zA-Z_$", start_ranges())
    let cont = set_text("a-zA-Z_$0-9", ident)
    let rule_line = "    rule(\"{replace(start, "\\", "\\\\")}{replace(cont, "\\", "\\\\")}*\") \{"
    var inscope rules <- split(fread(example_path("c_lexer.das")), "\n")
    let at = find_index_if(rules) $(line) => starts_with(line, "    rule(\"[a-zA-Z_$")
    t |> success(at >= 0, "c_lexer.das holds the Annex D identifier rule")
    t |> equal(at >= 0 ? rules[at] : "", rule_line, "c_lexer.das identifier rule")
    var defs : table<string; string>
    for (line in split(fread(example_path("c_lexer_reader.das")), "\n")) {
        let blank = find(line, ' ')
        if (blank > 0) {
            defs[slice(line, 0, blank)] = strip(slice(line, blank))
        }
    }
    t |> equal(defs?["L"] ?? "", start, "c_lexer_reader.das L")
    t |> equal(defs?["A"] ?? "", cont, "c_lexer_reader.das A")
}

//! `kind text line` per token of a lexer, an identifier's text taken
//! from its symbol
def private lexed_lines(var lexed : Lexed) : array<string> {
    resolve_text(lexed)
    return <- [for (tk in lexed.toks); "{tk.kind} {tk.text} {tk.line}"]
}

//! whether a token of `toks` is an identifier holding a byte past 127
def private has_utf8_identifier(toks : array<Tok>) : bool {
    for (tk in toks) {
        continue if (tk.kind != int(CTok.IDENTIFIER) && tk.kind != int(CTok.TYPEDEF_NAME))
        for (ch in tk.text) {
            return true if (ch >= 0x80)
        }
    }
    return false
}

[test(description = "on every case input the hand-written lexer (--mode probe) gives the token stream of c_next and, where the rules stop, c_next's error text; daslib/regex rule by rule (--mode regex) too, except on an input whose identifiers hold UTF-8, which its rules do not take")]
def test_probe_and_regex_follow_the_rules(t : T?) {
    let cases <- read_cases()
    var rules <- regex_rules()
    var inscope typedefs : table<string; int>
    var regex_checked = 0
    var errors = 0
    var errors_past_line_1 = 0
    for (c in cases) {
        let src = fread(path_join(cases_dir(), "{c.name}.c"))
        var inscope by_rules <- lex_flex(src, typedefs, "flex")
        var inscope want <- lexed_lines(by_rules)
        errors += empty(by_rules.err) ? 0 : 1
        errors_past_line_1 += empty(by_rules.err) || starts_with(by_rules.err, "1:") ? 0 : 1
        var inscope probe <- lex_probe(src, typedefs)
        t |> equal(lexed_lines(probe), want, "{c.name} (probe)")
        t |> equal(probe.err, by_rules.err, "{c.name} (probe error)")
        continue if (has_utf8_identifier(by_rules.toks))
        regex_checked++
        var inscope by_regex <- lex_regex(src, typedefs, rules)
        t |> equal(lexed_lines(by_regex), want, "{c.name} (regex)")
        t |> equal(by_regex.err, by_rules.err, "{c.name} (regex error)")
    }
    t |> success(regex_checked >= 20, "{regex_checked} cases checked in regex mode")
    t |> success(errors >= 20 && errors_past_line_1 >= 1, "{errors} cases stop the rules, {errors_past_line_1} past line 1")
}

[test(description = "the probe's UTF-8 reader refuses the overlong three- and four-byte forms of U+00A8, a character Annex D allows, and takes its shortest forms")]
def test_probe_refuses_overlong(t : T?) {
    for (bytes, want in ["\xE0\x82\xA8", "\xF0\x80\x82\xA8", "\xC2\xA8", "\xE0\xA0\x80", "\xF0\x90\x80\x80"], [0, 0, 2, 3, 4]) {
        peek_data(bytes) $(d) {
            t |> equal(utf8_len(d, 0), want, bytes)
        }
    }
}

[test(description = "c_scanner hands back the scanner of each --mode name, and c_next for flex and for a name it does not know")]
def test_c_scanner_dispatch(t : T?) {
    t |> success(c_scanner("reader") == @@c_next_reader, "reader")
    t |> success(c_scanner("goto") == @@c_next_goto, "goto")
    t |> success(c_scanner("flex-dgoto") == @@c_next_dgoto, "flex-dgoto")
    t |> success(c_scanner("flex-dtree") == @@c_next_dtree, "flex-dtree")
    t |> success(c_scanner("goto-dgoto") == @@c_next_goto_dgoto, "goto-dgoto")
    t |> success(c_scanner("flex-call") == @@c_next_call, "flex-call")
    t |> success(c_scanner("table") == @@c_next_table, "table")
    t |> success(c_scanner("flex") == @@c_next, "flex")
    t |> success(c_scanner("no-such-shape") == @@c_next, "an unknown name")
}

[test(description = "a four-byte character starts an identifier a UCN goes on with, and goes on with one a UCN starts")]
def test_ident_past_bmp_with_ucn(t : T?) {
    t |> equal(default_stream("\xF0\x9F\x98\x80\\u00e9"), ["\xF0\x9F\x98\x80\\u00e9"])
    t |> equal(default_stream("\\u00e9\xF0\x9F\x98\x80"), ["\\u00e9\xF0\x9F\x98\x80"])
}

//! what `cut_text_lexer` read through `text` before and after each `c_ident_cut`
var private cut_texts : array<string>

[flex]
def cut_text_lexer(var lx : FlexLexer) : bool {
    rule("[a-z\\u0080-\\U0010FFFF]+") {
        cut_texts |> push(text(lx))
        return false if (!c_ident_cut(lx))
        cut_texts |> push(text(lx))
        lx |> emit(1)
    }
}

[test(description = "after an identifier cut short the lexer goes on at the cut's column and the token's text is the cut prefix, even when a rule read the text before the cut; after a byte order mark the first token is at column 4")]
def test_columns_after_cut_and_bom(t : T?) {
    var lx : FlexLexer
    c_open(lx, "ab\xC3\x97")
    t |> success(c_next(lx) && text(lx) == "ab", "the identifier cut before U+00D7")
    t |> success(!c_next(lx) && lx.failed, "U+00D7 opens no token")
    t |> equal(lx.err, "1:3: unexpected '\xC3\x97'")
    var bom : FlexLexer
    c_open(bom, "\xEF\xBB\xBFint")
    t |> success(c_next(bom), "int after the byte order mark")
    t |> equal(bom.tok.col, 4)
    cut_texts |> clear()
    var custom : FlexLexer
    c_open(custom, "ab\xC3\x97")
    t |> success(cut_text_lexer(custom), "the custom rule's identifier cut before U+00D7")
    t |> equal(cut_texts, ["ab\xC3\x97", "ab"])
}

[test(description = "gen_variants.das over the rules of c_next writes exactly the checked-in c_lexer_goto.das and c_lexer_variants.das, line ends aside")]
def test_generated_variants_current(t : T?) {
    let files <- generated_files(dir_name(example_path("c_lexer.das")))
    t |> equal([for (f in files); base_name(f.path)], ["c_lexer_goto.das", "c_lexer_variants.das"])
    for (f in files) {
        t |> equal(replace(fread(f.path), "\r\n", "\n"), replace(f.text, "\r\n", "\n"), base_name(f.path))
    }
}

//! `kind symbol` of every token of `src`, `typedef_names` declared
//! before the scan
def private kinds_and_symbols(src : string; typedef_names : array<string>) : array<int2> {
    var lx : FlexLexer
    c_open(lx, src)
    for (name in typedef_names) {
        c_typedef(lx.syms, name)
    }
    var out : array<int2>
    while (c_next(lx)) {
        out |> push(int2(lx.tok.kind, lx.tok.sym))
    }
    return <- out
}

[test(description = "a keyword lexes as its kind, a name c_typedef declared as TYPEDEF_NAME, any other name as IDENTIFIER; one name is one symbol, and a token of no name has none")]
def test_identifier_kinds(t : T?) {
    let toks <- kinds_and_symbols("int size_t x; size_t x", ["size_t", "int"])
    t |> equal([for (k in toks); k.x], [int(CTok.INT), int(CTok.TYPEDEF_NAME), int(CTok.IDENTIFIER), ';',
                                       int(CTok.TYPEDEF_NAME), int(CTok.IDENTIFIER)])
    t |> equal(toks[1].y, toks[4].y)
    t |> equal(toks[2].y, toks[5].y)
    t |> equal(toks[3].y, -1)
    let plain <- kinds_and_symbols("while x", [])
    t |> equal([for (k in plain); k.x], [int(CTok.WHILE), int(CTok.IDENTIFIER)])
}

[test(description = "c_typedef before c_open declares the name too, and a second c_open keeps the declaration")]
def test_typedef_before_open(t : T?) {
    var lx : FlexLexer
    c_typedef(lx.syms, "T")
    c_open(lx, "T a")
    t |> success(c_next(lx))
    t |> equal(lx.tok.kind, int(CTok.TYPEDEF_NAME))
    c_open(lx, "a T while")
    var kinds : array<int>
    while (c_next(lx)) {
        kinds |> push(lx.tok.kind)
    }
    t |> equal(kinds, [int(CTok.IDENTIFIER), int(CTok.TYPEDEF_NAME), int(CTok.WHILE)])
}

//! the heap and string-heap allocations of one count-only scan of
//! `src`, the lexer opened before
def private scan_allocations(src : string) : tuple<heap : uint64; strings : uint64> {
    var lx : FlexLexer
    c_open(lx, src)
    let heap0 = heap_allocation_count()
    let strings0 = string_heap_allocation_count()
    var n = 0
    while (c_next(lx)) {
        n++
    }
    return (heap = heap_allocation_count() - heap0, strings = string_heap_allocation_count() - strings0)
}

[test(description = "a count-only scan builds no string, and its heap allocations follow the distinct names, not the tokens: twenty copies of a source allocate what one does")]
def test_scan_allocates_per_name(t : T?) {
    let once = "static int count_of(const char *s, unsigned n) \{ return s[n] + 0x1f + 2.5e3f; \}\n"
    let one = scan_allocations(once)
    t |> equal(one.strings, 0ul)
    let many = scan_allocations(repeat(once, 20))
    t |> equal(many.strings, 0ul)
    t |> equal(many.heap, one.heap)
}

[test(description = "the token arrays of c_lex_compare carry an identifier as its symbol with no text until resolve_text, any other token as its text")]
def test_compare_tokens_by_symbol(t : T?) {
    var inscope typedefs : table<string; int>
    typedefs["T"] = 1
    let src = "T x = 1;"
    var rules : array<ReRule>
    for (mode in ["flex", "probe"]) {
        var inscope lexed <- lex_mode(mode, src, typedefs, rules)
        t |> equal([for (tk in lexed.toks); tk.text], ["", "", "=", "1", ";"], mode)
        t |> success(lexed.toks[0].sym >= 0 && lexed.toks[2].sym == -1, mode)
        resolve_text(lexed)
        t |> equal([for (tk in lexed.toks); tk.text], ["T", "x", "=", "1", ";"], mode)
        t |> equal(lexed.toks[0].kind, int(CTok.TYPEDEF_NAME), mode)
    }
}
