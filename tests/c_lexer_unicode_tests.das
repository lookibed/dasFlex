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
require ../examples/c_lexer/c_lex_compare.das

// The C lexer example against the Unicode case table in examples/c_lexer/unicode_cases/cases.txt:
// every in-scope case's input lexed by every scanner shape gives clang's token stream, and the
// other lexers of c_lex_compare.das give the stream of the rules.

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
        out |> push("{tok.kind} {tok.start} {len}")
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

//! `kind text line` per token
def private tok_lines(toks : array<Tok>) : array<string> => [for (tk in toks); "{tk.kind} {tk.text} {tk.line}"]

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

[test(description = "on every case input the hand-written lexer (--mode probe) gives the token stream of c_next, up to the byte the rules stop at; daslib/regex rule by rule (--mode regex) too, except on an input whose identifiers hold UTF-8, which its rules do not take")]
def test_probe_and_regex_follow_the_rules(t : T?) {
    let cases <- read_cases()
    var rules <- regex_rules()
    var inscope typedefs : table<string; int>
    var regex_checked = 0
    for (c in cases) {
        let src = fread(path_join(cases_dir(), "{c.name}.c"))
        var inscope rule_toks <- lex_flex(src, typedefs, "flex")
        var inscope want <- tok_lines(rule_toks)
        t |> equal(tok_lines(lex_probe(src, typedefs)), want, "{c.name} (probe)")
        continue if (has_utf8_identifier(rule_toks))
        regex_checked++
        t |> equal(tok_lines(lex_regex(src, typedefs, rules)), want, "{c.name} (regex)")
    }
    t |> success(regex_checked >= 20, "{regex_checked} cases checked in regex mode")
}
