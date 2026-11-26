options gen2
options indenting = 4

// The C11 token stream of a preprocessed file, four ways: the dasFlex lexer (tables), the same
// rules as straight-line code (goto), the hand-written byte lexer of the dasLR1 C11 probe, and
// `daslib/regex` tried rule by rule. `--dump` prints `NAME<TAB>text<TAB>line` per token after
// the shared filter (GNU extension skipping, adjacent string literals joined, typedef tracking)
// so the four streams can be diffed; `--time N` lexes each file N times and prints the median.
// `--count` (with `--time N` and `--mode flex` or `flex-inline`) times the scanner alone: the lexer is opened outside the timer and
// the loop counts tokens, with no token array and no `text()` per token.
//
// `flex` (also `flex-inline`) is the default shape, the inline matcher with goto dispatch; the
// other `flex-*` and `goto*` modes are the shapes `c_lexer_variants` and `c_lexer_goto` spell out;
// `reader` is the same rules in the `%flex~` text form (`c_lexer_reader`). Every mode but `flex`
// reaches its scanner through the function `c_scanner` returns, one indirect call per token more.
// The `regex` mode is ASCII + `$` + UCN escapes: `daslib/regex` has no code-point escape, so an
// identifier holding a UTF-8 character past ASCII, or a byte order mark later than offset 0, stops it.
//
//   daslang -load_module <dasFlex> examples/c_lexer/c_lex_compare.das -- --mode flex|table|flex-call|flex-dgoto|flex-dtree|goto|goto-dgoto|reader|probe|regex (--dump | --time N [--count]) files...
//   (`-- --help` lists the flags)

require c_lexer
require c_lexer_variants
require daslib/regex
require daslib/fio
require daslib/clargs
require daslib/strings_boost
require daslib/utf8_utils
require strings

struct Tok {
    kind : int
    text : string
    line : int
}

//! a lexer's tokens over a text, then the error text of the byte it stopped at: "" when it took the
//! whole text
struct Lexed {
    toks : array<Tok>
    err : string
}

def is_ident_start(c : int) : bool => is_alpha(c) || c == '_' || c == '$'
def is_ident_char(c : int) : bool => is_alpha(c) || is_number(c) || c == '_' || c == '$'

//! the byte length of the UTF-8 character past ASCII at `i`, 0 when there is none or it is an
//! overlong form; a surrogate or a value past U+10FFFF is left to `c_ident_prefix`, which refuses both
def utf8_len(d : array<uint8>#; i : int) : int {
    let b = int(d[i])
    let n = b >= 0xC2 && b <= 0xDF ? 2 : b >= 0xE0 && b <= 0xEF ? 3 : b >= 0xF0 && b <= 0xF4 ? 4 : 0
    return 0 if (n == 0 || i + n > length(d))
    let lo = int(b == 0xE0 ? 0xA0 : b == 0xF0 ? 0x90 : 0x80)
    let second = int(d[i + 1])
    return 0 if (second < lo || second > 0xBF)
    for (k in range(2, n)) {
        return 0 if ((int(d[i + k]) & 0xC0) != 0x80)
    }
    return n
}

//! the byte length of the universal character name at `i` (`\uHHHH`, `\UHHHHHHHH`), 0 when there is none
def ucn_len(d : array<uint8>#; i : int) : int {
    return 0 if (int(d[i]) != '\\' || i + 1 >= length(d))
    let digits = int(d[i + 1]) == 'u' ? 4 : int(d[i + 1]) == 'U' ? 8 : 0
    return 0 if (digits == 0 || i + 2 + digits > length(d))
    for (k in range(digits)) {
        return 0 if (!is_hex(int(d[i + 2 + k])))
    }
    return digits + 2
}

//! the bytes of the identifier character at `i` - ASCII, a UCN or UTF-8 past ASCII - 0 when none
//! starts there; a digit only when `!first`
def ident_unit(d : array<uint8>#; i : int; first : bool) : int {
    let c = int(d[i])
    if (c < 0x80 && c != '\\') {
        return (first ? is_ident_start(c) : is_ident_char(c)) ? 1 : 0
    }
    return c == '\\' ? ucn_len(d, i) : utf8_len(d, i)
}

//! the byte length of the escape at `j` the literal rules take (`ES`): `\\` and one of `'"?\\abfnrtv`
//! or an octal digit, `\\x` and a hex digit, or a UCN - the rest of an octal or hex run is plain text
//! to the rule; 0 when none starts there
def escape_len(d : array<uint8>#; j : int) : int {
    return 0 if (j + 1 >= length(d))
    let e = int(d[j + 1])
    return 2 if (find("'\"?\\abfnrtv01234567", e) >= 0)
    return 3 if (e == 'x' && j + 2 < length(d) && is_hex(int(d[j + 2])))
    return ucn_len(d, j)
}

//! the byte length of the literal whose opening quote is at `i`, both quotes included, when the
//! rules take it - closed on its line, every escape one `escape_len` takes, a character literal not
//! empty - and 0 when they do not
def literal_len(d : array<uint8>#; i : int) : int {
    let quote = int(d[i])
    var j = i + 1
    while (j < length(d) && int(d[j]) != quote) {
        return 0 if (int(d[j]) == '\n')
        let step = int(d[j]) == '\\' ? escape_len(d, j) : 1
        return 0 if (step == 0)
        j += step
    }
    return 0 if (j >= length(d) || (quote == '\'' && j == i + 1))
    return j + 1 - i
}

//! the runtime's error text for the byte at `at` no rule takes
def probe_error(text : string; at, line, col : int) : string {
    var lx : FlexLexer
    flex_open(lx, text)
    lx.pos = at
    lx.line = line
    lx.col = col
    return flex_error_text(lx)
}

let PUNCT1 = ";\{\},:=()[].&!~-+*/%<>^|?"

//! the probe's hand-written lexer: raw tokens, no filter (keywords by table, typedef names by `typedefs`)
def lex_probe(text : string; typedefs : table<string; int>) : Lexed {  // nolint:STYLE038 - the probe's lexer kept whole, as the reference
    var res : Lexed
    var line = 1
    var line_start = 0
    peek_data(text) $(d) {  // nolint:STYLE037 - see the function
        let n = length(d)
        var i = 0
        if (contains_utf8_bom(text)) {
            i = 3
        }
        while (i < n) {
            let c = int(d[i])
            if (c == '\n') {
                line++
                i++
                line_start = i
                continue
            }
            if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v') {
                i++
                continue
            }
            if (c == '#') {
                while (i < n && int(d[i]) != '\n') {
                    i++
                }
                continue
            }
            if (c == '/' && i + 1 < n && int(d[i + 1]) == '*') {
                i += 2
                while (i + 1 < n && !(int(d[i]) == '*' && int(d[i + 1]) == '/')) {
                    if (int(d[i]) == '\n') {
                        line++
                        line_start = i + 1
                    }
                    i++
                }
                i += 2
                continue
            }
            if (c == '/' && i + 1 < n && int(d[i + 1]) == '/') {
                while (i < n && int(d[i]) != '\n') {
                    i++
                }
                continue
            }
            let start = i
            let u8_string = c == 'u' && i + 2 < n && int(d[i + 1]) == '8' && int(d[i + 2]) == '"'
            let one_prefix = ((c == 'L' || c == 'u' || c == 'U') && i + 1 < n
                              && (int(d[i + 1]) == '"' || int(d[i + 1]) == '\''))
            let prefix = u8_string ? 2 : one_prefix ? 1 : 0
            if (c == '"' || c == '\'' || prefix > 0) {
                // a literal the rules refuse fails at its quote; a prefix before it is an identifier
                let len = literal_len(d, start + prefix)
                if (len > 0) {
                    let quote = int(d[start + prefix])
                    i = start + prefix + len
                    res.toks |> emplace(
                                   Tok(kind = int(quote == '"' ? CTok.STRING_LITERAL : CTok.I_CONSTANT),
                                       text = slice(d, start, i), line = line))
                    continue
                }
                if (prefix == 0) {
                    res.err = probe_error(text, i, line, i - line_start + 1)
                    break
                }
            }
            if (ident_unit(d, i, true) > 0) {
                var ascii = true
                while (i < n) {
                    if (is_ident_char(int(d[i]))) {
                        i++
                        continue
                    }
                    let unit = ident_unit(d, i, i == start)
                    break if (unit == 0)
                    ascii = false
                    i += unit
                }
                i = ascii ? i : start + c_ident_prefix(d, start, i)
                if (i == start) {
                    res.err = probe_error(text, start, line, start - line_start + 1)
                    break
                }
                let word = slice(d, start, i)
                var kind = int(CTok.IDENTIFIER)
                KEYWORDS |> get(word) $(k) {
                    kind = int(k)
                }
                if (kind == int(CTok.IDENTIFIER) && typedefs |> key_exists(word)) {
                    kind = int(CTok.TYPEDEF_NAME)
                }
                res.toks |> emplace(Tok(kind = kind, text = word, line = line))
                continue
            }
            if (is_number(c) || (c == '.' && i + 1 < n && is_number(int(d[i + 1])))) {
                var is_float = c == '.'
                let is_hex = c == '0' && start + 1 < n && (int(d[start + 1]) == 'x'
                                                           || int(d[start + 1]) == 'X')
                while (i < n) {
                    let ch = int(d[i])
                    if (is_ident_char(ch) || ch == '.') {
                        is_float ||= ch == '.' || ((ch == 'e' || ch == 'E') && !is_hex) || ((ch == 'p' || ch == 'P') && is_hex)
                        i++
                    } elif ((ch == '+' || ch == '-') && i > start) {
                        let prev = int(d[i - 1])
                        let exp_sign = (!is_hex && (prev == 'e' || prev == 'E')) || (is_hex
                            && (prev == 'p' || prev == 'P'))
                        break if (!exp_sign)
                        i++
                    } else {
                        break
                    }
                }
                let word = slice(d, start, i)
                res.toks |> emplace(
                               Tok(kind = int(is_float ? CTok.F_CONSTANT : CTok.I_CONSTANT),
                                   text = word, line = line))
                continue
            }
            if (i + 2 < n) {
                let s3 = slice(d, i, i + 3)
                var p3 = -1
                PUNCT3 |> get(s3) $(v) {
                    p3 = int(v)
                }
                if (p3 >= 0) {
                    res.toks |> emplace(Tok(kind = p3, text = s3, line = line))
                    i += 3
                    continue
                }
            }
            if (i + 1 < n) {
                let s2 = slice(d, i, i + 2)
                var p2 = -1
                PUNCT2 |> get(s2) $(v) {
                    p2 = int(v)
                }
                if (p2 >= 0) {
                    res.toks |> emplace(Tok(kind = p2, text = s2, line = line))
                    i += 2
                    continue
                }
            }
            if (find(PUNCT1, c) < 0) {
                res.err = probe_error(text, i, line, i - line_start + 1)
                break
            }
            res.toks |> emplace(Tok(kind = c, text = slice(d, i, i + 1), line = line))
            i++
        }
    }
    return <- res
}

let PUNCT3 <- { "..." => CTok.ELLIPSIS, ">>=" => CTok.RIGHT_ASSIGN, "<<=" => CTok.LEFT_ASSIGN }
let PUNCT2 <- {
    "+=" => CTok.ADD_ASSIGN, "-=" => CTok.SUB_ASSIGN, "*=" => CTok.MUL_ASSIGN, "/=" => CTok.DIV_ASSIGN,
    "%=" => CTok.MOD_ASSIGN, "&=" => CTok.AND_ASSIGN, "^=" => CTok.XOR_ASSIGN, "|=" => CTok.OR_ASSIGN,
    ">>" => CTok.RIGHT_OP, "<<" => CTok.LEFT_OP, "++" => CTok.INC_OP, "--" => CTok.DEC_OP, "->" => CTok.PTR_OP,
    "&&" => CTok.AND_OP, "||" => CTok.OR_OP, "<=" => CTok.LE_OP, ">=" => CTok.GE_OP, "==" => CTok.EQ_OP,
    "!=" => CTok.NE_OP
}

//! every token `scan` takes from `lx`
def flex_tokens(var lx : FlexLexer; scan : block<(var lx : FlexLexer) : bool>) : array<Tok> {
    var out : array<Tok>
    while (invoke(scan, lx)) {
        out |> emplace(Tok(kind = lx.tok.kind, text = text(lx), line = lx.tok.line))
    }
    return <- out
}

//! the dasFlex lexer in one of its generated shapes: raw tokens
def lex_flex(text : string; typedefs : table<string; int>; shape : string) : Lexed {
    var lx : FlexLexer
    lx.symbols := typedefs
    c_open(lx, text)
    var res : Lexed
    if (shape == "flex" || shape == "flex-inline") {
        res.toks <- flex_tokens(lx) $(var l : FlexLexer) => c_next(l)
    } else {
        let scan = c_scanner(shape)
        res.toks <- flex_tokens(lx) $(var l : FlexLexer) => invoke(scan, l)
    }
    res.err = lx.failed ? lx.err : ""
    return <- res
}

//! `daslib/regex` rule by rule at the cursor: longest match, the first rule on a tie
struct ReRule {
    re : Regex
    kind : int          //!< -1 skip, -2 identifier (table lookup), -3 single byte, -4 comment start, -5 comment end
}

def regex_rules() : array<ReRule> {
    var rs : array<ReRule>
    rs |> reserve(64)
    // no `X+Y?` shapes: daslib/regex returns the shortest X there (see the package report), so each
    // optional suffix is a rule of its own; alternatives are ordered longest first, since `|` takes the
    // first alternative that matches, not the longest
    let names <- [["[ \t\v\f\r\n]+", "-1"],
                  ["#[^\n]*", "-1"],
                  ["//[^\n]*", "-1"],
                  ["/\\*", "-4"],
                  ["(?:[a-zA-Z_$]|\\\\u[0-9a-fA-F]\{4\}|\\\\U[0-9a-fA-F]\{8\})(?:[a-zA-Z_$0-9]|\\\\u[0-9a-fA-F]\{4\}|\\\\U[0-9a-fA-F]\{8\})*", "-2"],
                  ["0[xX][a-fA-F0-9]+", "{int(CTok.I_CONSTANT)}"],
                  ["0[xX][a-fA-F0-9]+(ull|uLL|Ull|ULL|llu|llU|LLu|LLU|ul|uL|Ul|UL|lu|lU|Lu|LU|ll|LL|u|U|l|L)", "{int(CTok.I_CONSTANT)}"],
                  ["[1-9][0-9]*", "{int(CTok.I_CONSTANT)}"],
                  ["[1-9][0-9]*(ull|uLL|Ull|ULL|llu|llU|LLu|LLU|ul|uL|Ul|UL|lu|lU|Lu|LU|ll|LL|u|U|l|L)", "{int(CTok.I_CONSTANT)}"],
                  ["0[0-7]*", "{int(CTok.I_CONSTANT)}"],
                  ["0[0-7]*(ull|uLL|Ull|ULL|llu|llU|LLu|LLU|ul|uL|Ul|UL|lu|lU|Lu|LU|ll|LL|u|U|l|L)",
                   "{int(CTok.I_CONSTANT)}"],
                  ["(u|U|L)?'([^'\\\\\n]|(\\\\([\'\"?\\\\abfnrtv]|[0-7]+|x[a-fA-F0-9]+|u[a-fA-F0-9]\{4\}|U[a-fA-F0-9]\{8\})))+'",
                   "{int(CTok.I_CONSTANT)}"],
                  ["[0-9]+([Ee][+-]?[0-9]+)", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]+([Ee][+-]?[0-9]+)(f|F|l|L)", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]*\\.[0-9]+", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]*\\.[0-9]+(f|F|l|L)", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]*\\.[0-9]+([Ee][+-]?[0-9]+)", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]*\\.[0-9]+([Ee][+-]?[0-9]+)(f|F|l|L)", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]+\\.", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]+\\.(f|F|l|L)", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]+\\.([Ee][+-]?[0-9]+)", "{int(CTok.F_CONSTANT)}"],
                  ["[0-9]+\\.([Ee][+-]?[0-9]+)(f|F|l|L)", "{int(CTok.F_CONSTANT)}"],
                  ["0[xX][a-fA-F0-9]+([Pp][+-]?[0-9]+)", "{int(CTok.F_CONSTANT)}"],
                  ["0[xX][a-fA-F0-9]+([Pp][+-]?[0-9]+)(f|F|l|L)", "{int(CTok.F_CONSTANT)}"],
                  ["0[xX][a-fA-F0-9]*\\.[a-fA-F0-9]+([Pp][+-]?[0-9]+)", "{int(CTok.F_CONSTANT)}"],
                  ["0[xX][a-fA-F0-9]*\\.[a-fA-F0-9]+([Pp][+-]?[0-9]+)(f|F|l|L)",
                   "{int(CTok.F_CONSTANT)}"],
                  ["0[xX][a-fA-F0-9]+\\.([Pp][+-]?[0-9]+)", "{int(CTok.F_CONSTANT)}"],
                  ["0[xX][a-fA-F0-9]+\\.([Pp][+-]?[0-9]+)(f|F|l|L)", "{int(CTok.F_CONSTANT)}"],
                  ["(u8|u|U|L)?\"([^\"\\\\\n]|(\\\\([\'\"?\\\\abfnrtv]|[0-7]+|x[a-fA-F0-9]+|u[a-fA-F0-9]\{4\}|U[a-fA-F0-9]\{8\})))*\"",
                   "{int(CTok.STRING_LITERAL)}"],
                  ["\\.\\.\\.", "{int(CTok.ELLIPSIS)}"],
                  [">>=", "{int(CTok.RIGHT_ASSIGN)}"],
                  ["<<=", "{int(CTok.LEFT_ASSIGN)}"],
                  ["\\+=", "{int(CTok.ADD_ASSIGN)}"],
                  ["-=", "{int(CTok.SUB_ASSIGN)}"],
                  ["\\*=", "{int(CTok.MUL_ASSIGN)}"],
                  ["/=", "{int(CTok.DIV_ASSIGN)}"],
                  ["%=", "{int(CTok.MOD_ASSIGN)}"],
                  ["&=", "{int(CTok.AND_ASSIGN)}"],
                  ["\\^=", "{int(CTok.XOR_ASSIGN)}"],
                  ["\\|=", "{int(CTok.OR_ASSIGN)}"],
                  [">>", "{int(CTok.RIGHT_OP)}"],
                  ["<<", "{int(CTok.LEFT_OP)}"],
                  ["\\+\\+", "{int(CTok.INC_OP)}"],
                  ["--", "{int(CTok.DEC_OP)}"],
                  ["->", "{int(CTok.PTR_OP)}"],
                  ["&&", "{int(CTok.AND_OP)}"],
                  ["\\|\\|", "{int(CTok.OR_OP)}"],
                  ["<=", "{int(CTok.LE_OP)}"],
                  [">=", "{int(CTok.GE_OP)}"],
                  ["==", "{int(CTok.EQ_OP)}"],
                  ["!=", "{int(CTok.NE_OP)}"],
                  [";|\\\{|\\\}|,|:|=|\\(|\\)|\\[|\\]|\\.|&|!|~|-|\\+|\\*|/|%|<|>|\\^|\\||\\?",
                   "-3"]]
    for (nk in names) {
        var r : ReRule
        if (!regex_compile(r.re, nk[0])) {
            panic("regex rule does not compile: {nk[0]}")
        }
        r.kind = to_int(nk[1])
        rs |> emplace(r)
    }
    return <- rs
}

def lex_regex(text : string; typedefs : table<string; int>;
              var rules : array<ReRule>) : Lexed {
    var res : Lexed
    var pos = contains_utf8_bom(text) ? 3 : 0
    var line = 1
    var line_start = 0
    peek_data(text) $(d) {
        let n = length(d)
        while (pos < n) {
            var best = -1
            var best_end = -1
            for (ri, r in count(), rules) {
                let e = regex_match(r.re, text, pos)
                if (e > best_end) {
                    best_end = e
                    best = ri
                }
            }
            let kind = best < 0 ? 0 : rules[best].kind
            if (kind == -2 && best_end > pos) {
                // an identifier holding a UCN ends before the first character Annex D does not allow there
                best_end = pos + c_ident_prefix(d, pos, best_end)
            }
            if (best < 0 || best_end <= pos) {
                res.err = probe_error(text, pos, line, pos - line_start + 1)
                break
            }
            for (p in range(pos, best_end)) {
                if (int(d[p]) == '\n') {
                    line++
                    line_start = p + 1
                }
            }
            if (kind == -4) {
                // a comment: skip to the closing */
                var p = best_end
                while (p + 1 < n && !(int(d[p]) == '*' && int(d[p + 1]) == '/')) {
                    if (int(d[p]) == '\n') {
                        line++
                        line_start = p + 1
                    }
                    p++
                }
                pos = p + 2
                continue
            }
            let start = pos
            pos = best_end
            continue if (kind == -1)
            var k = kind
            if (kind == -2) {
                k = c_word_kind_of(slice(d, start, best_end), typedefs)
            } elif (kind == -3) {
                k = int(d[start])
            }
            res.toks |> emplace(Tok(kind = k, text = slice(d, start, best_end), line = line))
        }
    }
    return <- res
}

//! the shared filter: GNU extensions skipped, adjacent string literals joined, typedef names learned.
//! The typedef table is read during lexing, so a lexer runs per declaration chunk... here per file,
//! with the table seeded by a first pass: the filter reports the names, the caller re-lexes if asked.
def filter_tokens(raw : array<Tok>; var typedefs : table<string; int>) : array<Tok> {
    var out : array<Tok>
    var i = 0
    let n = length(raw)
    var in_typedef = false
    var depth = 0
    var candidates : array<string>
    while (i < n) {
        let t = raw[i]
        if (t.kind == int(CTok.IDENTIFIER)
            && (t.text == "__attribute__" || t.text == "__asm__" || t.text == "__asm"
                || t.text == "__typeof__")) {
            i++
            while (i < n && raw[i].kind != '(') {
                i++
            }
            var pd = 0
            while (i < n) {
                if (raw[i].kind == '(') {
                    pd++
                } elif (raw[i].kind == ')') {
                    pd--
                    if (pd == 0) {
                        i++
                        break
                    }
                }
                i++
            }
            continue
        }
        if (t.kind == int(CTok.IDENTIFIER)
            && (t.text == "__extension__" || t.text == "__inline" || t.text == "__inline__"
                || t.text == "__restrict" || t.text == "__restrict__")) {
            i++
            continue
        }
        if (t.kind == int(CTok.STRING_LITERAL) && !empty(out)
            && out[length(out) - 1].kind == int(CTok.STRING_LITERAL)) {
            out[length(out) - 1].text += " " + t.text
            i++
            continue
        }
        if (t.kind == int(CTok.TYPEDEF)) {
            in_typedef = true
            depth = 0
            candidates |> clear()
        } elif (t.kind == int(CTok.IDENTIFIER) && in_typedef) {
            if (depth == 0) {
                candidates |> push(t.text)
            } elif (depth == 1 && i + 1 < n && raw[i + 1].kind != '(' && empty(candidates)) {
                candidates |> push(t.text)
            }
        }
        if (t.kind == '(' || t.kind == '{' || t.kind == '[') {
            depth++
        } elif (t.kind == ')' || t.kind == '}' || t.kind == ']') {
            depth--
        }
        if (in_typedef && depth == 0 && (t.kind == ';' || t.kind == ',')) {
            if (!empty(candidates)) {
                typedefs[candidates[length(candidates) - 1]] = 1
            }
            candidates |> clear()
            if (t.kind == ';') {
                in_typedef = false
            }
        }
        out |> emplace(Tok(kind = t.kind, text = t.text, line = t.line))
        i++
    }
    return <- out
}

//! the tokens of the lexer `mode` names; its error text, when it stopped, printed
def lex_mode(mode : string; text : string; typedefs : table<string; int>;
             var rules : array<ReRule>) : array<Tok> {
    var res <- (mode == "probe" ? lex_probe(text, typedefs)
        : mode == "regex" ? lex_regex(text, typedefs, rules) : lex_flex(text, typedefs, mode))
    if (!empty(res.err)) {
        print("{res.err}\n")
    }
    return <- res.toks
}

//! the default shape's scanner alone, `passes` times: the lexer is opened outside the timer, the loop counts tokens
def time_count(path : string; text : string; typedefs : table<string; int>; passes : int) {
    var inscope times : array<double>
    times |> reserve(passes)
    var ntok = 0
    for (_k in range(passes)) {
        var lx : FlexLexer
        lx.symbols := typedefs
        flex_open(lx, text)
        ntok = 0
        let t0 = ref_time_ticks()
        while (c_next(lx)) {
            ntok++
        }
        times |> push(double(get_time_usec(t0)) / 1000.0lf)
    }
    sort(times)
    print("TIME flex+count {path} median_ms={times[length(times) / 2]} min={times[0]} max={times[length(times) - 1]} bytes={length(text)} tokens={ntok}\n")
}

[CommandLineArgs]
struct CompareArgs {
    @clarg_doc = "the lexer: flex, table, flex-call, flex-dgoto, flex-dtree, goto, goto-dgoto, reader, probe or regex"
    mode : string = "flex"
    @clarg_doc = "print NAME, text and line per token, tab-separated"
    dump : bool
    @clarg_doc = "lex each file N times and print the median, min and max milliseconds"
    time : int
    @clarg_doc = "with --time and --mode flex or flex-inline: time the scanner alone, counting tokens (no token array, no text per token)"
    count : bool
    @clarg_positional
    @clarg_doc = "the preprocessed C files"
    files : array<string>
}

[export]
def main() : int {
    var args = CompareArgs()
    let rc = parse_args_with_help(args, "c_lex_compare")
    return rc if (rc >= 0)
    if (args.count && (args.time <= 0 || (args.mode != "flex" && args.mode != "flex-inline"))) {
        print("usage: c_lex_compare -- --mode flex|flex-inline --time N --count files...\n")
        return 1
    }
    var rules <- regex_rules()
    for (path in args.files) {
        let text = fread(path)
        if (empty(text)) {
            print("{path}: empty or unreadable\n")
            continue
        }
        // two lexing passes: the first learns the typedef names the second needs (the C grammar's
        // lexer hack), so every mode sees the same table
        var inscope typedefs : table<string; int>
        typedefs["__builtin_va_list"] = 1
        var inscope first_raw <- lex_mode(args.mode, text, typedefs, rules)
        var inscope first_toks <- filter_tokens(first_raw, typedefs)
        var inscope raw <- lex_mode(args.mode, text, typedefs, rules)
        var inscope seed := typedefs
        var inscope toks <- filter_tokens(raw, seed)
        if (args.dump) {
            for (t in toks) {
                print("{c_token_name(t.kind)}\t{t.text}\t{t.line}\n")
            }
        } else {
            print("{path}: {args.mode}: {length(toks)} tokens, {length(seed)} typedefs\n")
        }
        if (args.count) {
            time_count(path, text, typedefs, args.time)
        } elif (args.time > 0) {
            var inscope times : array<double>
            times |> reserve(args.time)
            for (_k in range(args.time)) {
                let t0 = ref_time_ticks()
                var inscope r <- lex_mode(args.mode, text, typedefs, rules)
                times |> push(double(get_time_usec(t0)) / 1000.0lf)
            }
            sort(times)
            print("TIME {args.mode} {path} median_ms={times[length(times) / 2]} min={times[0]} max={times[length(times) - 1]} bytes={length(text)}\n")
        }
    }
    return 0
}
