options gen2
options indenting = 4

// The C11 token stream of a preprocessed file, four ways: the dasFlex lexer (tables), the same
// rules as straight-line code (goto), the hand-written byte lexer of the dasLR1 C11 probe, and
// `daslib/regex` tried rule by rule. `--dump` prints `NAME<TAB>text<TAB>line` per token after
// the shared filter (GNU extension skipping, adjacent string literals joined, typedef tracking)
// so the four streams can be diffed; `--time N` lexes each file N times and prints the median.
// `--count` (with `--time N` and `--mode flex`, `flex-inline` or `pp`) times the scanner alone: the lexer is opened outside the
// timer and the loop counts tokens, with no token array and no `text()` per token.
// A HEAP line follows with the heap and string-heap allocations of that
// loop. The token arrays of the dasFlex and probe modes keep an
// identifier as its symbol, with no string; the regex mode builds the
// word and looks it up by string, a check independent of the interner.
//
// `flex` (also `flex-inline`) is the default shape, the inline matcher with goto dispatch; the
// other `flex-*` and `goto*` modes are the shapes `c_lexer_variants` and `c_lexer_goto` spell out;
// `reader` is the same rules in the `%flex~` text form (`c_lexer_reader`). Every mode but `flex`
// reaches its scanner through the function `c_scanner` returns, one indirect call per token more.
// `pp` is the preprocessing-token lexer (`c_lexer_pp`): its stream is not filtered, and `--dump`
// adds the `has_space` and `at_bol` flags of each token as two more columns.
// The `regex` mode is ASCII + `$` + UCN escapes: `daslib/regex` has no code-point escape, so an
// identifier holding a UTF-8 character past ASCII, or a byte order mark later than offset 0, stops it.
//
//   daslang -load_module <dasFlex> examples/c_lexer/c_lex_compare.das -- --mode flex|table|flex-call|flex-dgoto|flex-dtree|goto|goto-dgoto|reader|pp|probe|regex (--dump | --time N [--count]) files...
//   (`-- --help` lists the flags)

require c_lexer
require c_lexer_pp
require c_lexer_variants
require daslib/regex
require daslib/fio
require daslib/clargs
require daslib/strings_boost
require daslib/utf8_utils
require strings

//! one token: an identifier, keyword or typedef name is its symbol
//! `sym` and its `text` stays "" until `resolve_text`; any other
//! token is its text and `sym` -1; the flags are the dasFlex lexer's
struct Tok {
    kind : int
    text : string
    line : int
    sym : int
    has_space : bool
    at_bol : bool
}

//! the tokens of one file, and the symbols their `sym` fields name;
//! `src` holds the bytes the symbols' spans point into when the lexer
//! made a copy of the text; `err` is the error text of the byte the
//! lexer stopped at, "" when it took the whole text
struct Lexed {
    toks : array<Tok>
    syms : FlexSymbols
    src : array<uint8>
    err : string
}

//! the text of every identifier token from its symbol - one string
//! per name - for the filter and the dump
def resolve_text(var lexed : Lexed) {
    for (t in lexed.toks) {
        if (t.sym >= 0) {
            t.text = symbol_text(lexed.syms, t.sym)
        }
    }
}

//! a symbol table holding the keywords and `typedefs`
def c_symbols_with(typedefs : table<string; int>) : FlexSymbols {
    var syms : FlexSymbols
    c_symbols(syms)
    for (name in keys(typedefs)) {
        c_typedef(syms, name)
    }
    return <- syms
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

//! the probe's hand-written lexer: raw tokens, no filter; keywords
//! and the names in `typedefs` by their symbols, the spans pointing
//! into `text`
def lex_probe(text : string; typedefs : table<string; int>) : Lexed {  // nolint:STYLE038 - the probe's lexer kept whole, as the reference
    var res = Lexed(syms <- c_symbols_with(typedefs))
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
                                       text = slice(d, start, i), line = line, sym = -1))
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
                let sym = intern(res.syms, unsafe(addr<uint8 const?>(d[0])), start, i - start)
                res.toks |> emplace(Tok(kind = symbol_kind(res.syms, sym), line = line, sym = sym))
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
                                   text = word, line = line, sym = -1))
                continue
            }
            if (i + 2 < n) {
                let s3 = slice(d, i, i + 3)
                var p3 = -1
                PUNCT3 |> get(s3) $(v) {
                    p3 = int(v)
                }
                if (p3 >= 0) {
                    res.toks |> emplace(Tok(kind = p3, text = s3, line = line, sym = -1))
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
                    res.toks |> emplace(Tok(kind = p2, text = s2, line = line, sym = -1))
                    i += 2
                    continue
                }
            }
            if (find(PUNCT1, c) < 0) {
                res.err = probe_error(text, i, line, i - line_start + 1)
                break
            }
            res.toks |> emplace(Tok(kind = c, text = slice(d, i, i + 1), line = line, sym = -1))
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

//! every token `scan` takes from `lx`: a token a rule interned as its
//! symbol, any other as its text
def flex_tokens(var lx : FlexLexer; scan : block<(var lx : FlexLexer) : bool>) : array<Tok> {
    var out : array<Tok>
    while (invoke(scan, lx)) {
        out |> emplace(Tok(kind = lx.tok.kind, text = lx.tok.sym >= 0 ? "" : text(lx), line = lx.tok.line,
                           sym = lx.tok.sym, has_space = lx.tok.has_space, at_bol = lx.tok.at_bol))
    }
    return <- out
}

//! the dasFlex lexer in one of its generated shapes: raw tokens, and
//! the lexer's symbols and bytes
def lex_flex(text : string; typedefs : table<string; int>; shape : string) : Lexed {
    var lx : FlexLexer
    lx.syms <- c_symbols_with(typedefs)
    c_open(lx, text)
    var res : Lexed
    if (shape == "flex" || shape == "flex-inline") {
        res.toks <- flex_tokens(lx) $(var l : FlexLexer) => c_next(l)
    } elif (shape == "pp") {
        res.toks <- flex_tokens(lx) $(var l : FlexLexer) => c_next_pp(l)
    } else {
        let scan = c_scanner(shape)
        res.toks <- flex_tokens(lx) $(var l : FlexLexer) => invoke(scan, l)
    }
    res.err = lx.failed ? lx.err : ""
    res.syms <- lx.syms
    res.src <- lx.bytes
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
            res.toks |> emplace(Tok(kind = k, text = slice(d, start, best_end), line = line, sym = -1))
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
        out |> emplace(Tok(kind = t.kind, text = t.text, line = t.line, sym = -1))
        i++
    }
    return <- out
}

//! the tokens of the lexer `mode` names; its error text, when it stopped, printed
def lex_mode(mode : string; text : string; typedefs : table<string; int>;
             var rules : array<ReRule>) : Lexed {
    var res <- (mode == "probe" ? lex_probe(text, typedefs)
        : mode == "regex" ? lex_regex(text, typedefs, rules) : lex_flex(text, typedefs, mode))
    if (!empty(res.err)) {
        print("{res.err}\n")
    }
    return <- res
}

//! the tokens of one file after the shared filter, and how many
//! typedef names the filter knew at its end
struct Filtered {
    toks : array<Tok>
    typedef_count : int
}

//! the tokens of the lexer `mode` names, the identifier texts resolved
def lex_resolved(mode : string; text : string; typedefs : table<string; int>;
                 var rules : array<ReRule>) : Lexed {
    var res <- lex_mode(mode, text, typedefs, rules)
    resolve_text(res)
    return <- res
}

//! `text` lexed by `mode` twice and filtered: the first pass learns
//! the typedef names the second needs (the C grammar's lexer hack), so
//! every mode sees the same table; `typedefs` gains the first pass's
//! names. `--mode pp` is lexed once with no filter: the preprocessing
//! tokens as the lexer gives them
def lex_filtered(mode : string; text : string; var typedefs : table<string; int>;
                 var rules : array<ReRule>) : Filtered {
    var inscope first_raw <- lex_resolved(mode, text, typedefs, rules)
    return <- Filtered(toks <- first_raw.toks, typedef_count = length(typedefs)) if (mode == "pp")
    var inscope first_toks <- filter_tokens(first_raw.toks, typedefs)
    var inscope raw <- lex_resolved(mode, text, typedefs, rules)
    var inscope seed := typedefs
    var res = Filtered(toks <- filter_tokens(raw.toks, seed))
    res.typedef_count = length(seed)
    return <- res
}

//! one `--dump` row: NAME, text and line, tab-separated, and in pp mode the `has_space` and
//! `at_bol` columns
def dump_line(t : Tok; pp : bool) : string {
    let row = "{c_token_name(t.kind)}\t{t.text}\t{t.line}"
    return pp ? "{row}\t{t.has_space ? "space" : "-"}\t{t.at_bol ? "bol" : "-"}" : row
}

//! a count-only scan of the default shape or the pp lexer: the tokens and the
//! symbols the lexer ended with, the heap and string-heap allocations
//! of the last pass's loop, and each pass's milliseconds, sorted
struct CountRun {
    tokens : int
    symbols : int
    heap_allocs : uint64
    string_allocs : uint64
    times : array<double>
}

//! the default shape's scanner alone, or the pp lexer's when `pp`,
//! `passes` times: the lexer is opened outside the timer, the loop
//! counts tokens; the allocations are counted outside the timer
def time_count(text : string; typedefs : table<string; int>; passes : int; pp : bool = false) : CountRun {
    var run : CountRun
    run.times |> reserve(passes)
    for (_k in range(passes)) {
        var lx : FlexLexer
        lx.syms <- c_symbols_with(typedefs)
        c_open(lx, text)
        var ntok = 0
        let heap0 = heap_allocation_count()
        let strings0 = string_heap_allocation_count()
        let t0 = ref_time_ticks()
        if (pp) {
            while (c_next_pp(lx)) {
                ntok++
            }
        } else {
            while (c_next(lx)) {
                ntok++
            }
        }
        run.times |> push(double(get_time_usec(t0)) / 1000.0lf)
        run.heap_allocs = heap_allocation_count() - heap0
        run.string_allocs = string_heap_allocation_count() - strings0
        run.tokens = ntok
        run.symbols = symbol_count(lx.syms)
    }
    sort(run.times)
    return <- run
}

[CommandLineArgs]
struct CompareArgs {
    @clarg_doc = "the lexer: flex, table, flex-call, flex-dgoto, flex-dtree, goto, goto-dgoto, reader, pp, probe or regex"
    mode : string = "flex"
    @clarg_doc = "print NAME, text and line per token, tab-separated"
    dump : bool
    @clarg_doc = "lex each file N times and print the median, min and max milliseconds"
    time : int
    @clarg_doc = "with --time and --mode flex, flex-inline or pp: time the scanner alone, counting tokens (no token array, no text per token)"
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
    if (args.count && (args.time <= 0 || (args.mode != "flex" && args.mode != "flex-inline" && args.mode != "pp"))) {
        print("usage: c_lex_compare -- --mode flex|flex-inline|pp --time N --count files...\n")
        return 1
    }
    var rules <- regex_rules()
    for (path in args.files) {
        let text = fread(path)
        if (empty(text)) {
            print("{path}: empty or unreadable\n")
            continue
        }
        var inscope typedefs : table<string; int>
        typedefs["__builtin_va_list"] = 1
        var inscope filtered <- lex_filtered(args.mode, text, typedefs, rules)
        if (args.dump) {
            for (t in filtered.toks) {
                print("{dump_line(t, args.mode == "pp")}\n")
            }
        } else {
            print("{path}: {args.mode}: {length(filtered.toks)} tokens, {filtered.typedef_count} typedefs\n")
        }
        if (args.count) {
            let pp = args.mode == "pp"
            var inscope run <- time_count(text, typedefs, args.time, pp)
            let tag = pp ? "pp+count" : "flex+count"
            print("TIME {tag} {path} median_ms={run.times[length(run.times) / 2]} min={run.times[0]} max={run.times[length(run.times) - 1]} bytes={length(text)} tokens={run.tokens}\n")
            print("HEAP {tag} {path} tokens={run.tokens} symbols={run.symbols} heap_allocs={int64(run.heap_allocs)} string_allocs={int64(run.string_allocs)}\n")
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
