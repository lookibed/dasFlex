options gen2
options indenting = 4

// The C11 token stream of a preprocessed file, four ways: the dasFlex lexer (tables), the same
// rules as straight-line code (goto), the hand-written byte lexer of the dasLR1 C11 probe, and
// `daslib/regex` tried rule by rule. `--dump` prints `NAME<TAB>text<TAB>line` per token after
// the shared filter (GNU extension skipping, adjacent string literals joined, typedef tracking)
// so the four streams can be diffed; `--time N` lexes each file N times and prints the median.
//
//   daslang -load_module <dasFlex> bench/c_lex_compare.das -- --mode flex|goto|flex-dgoto|flex-dtree|flex-inline|goto-dgoto|probe|regex (--dump | --time N) files...

require c_lexer
require c_lexer_goto
require c_lexer_variants
require daslib/regex
require daslib/fio
require daslib/strings_boost
require strings

struct Tok {
    kind : int
    text : string
    line : int
}

def is_ident_start(c : int) : bool => is_alpha(c) || c == '_'
def is_ident_char(c : int) : bool => is_alpha(c) || is_number(c) || c == '_'

//! the probe's hand-written lexer: raw tokens, no filter (keywords by table, typedef names by `typedefs`)
def lex_probe(text : string; typedefs : table<string; int>) : array<Tok> {  // nolint:STYLE038 - the probe's lexer kept whole, as the reference
    var out : array<Tok>
    var line = 1
    peek_data(text) $(d) {  // nolint:STYLE037 - see the function
        let n = length(d)
        var i = 0
        while (i < n) {
            let c = int(d[i])
            if (c == '\n') {
                line++
                i++
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
            if (is_ident_start(c)) {
                while (i < n && is_ident_char(int(d[i]))) {
                    i++
                }
                let word = slice(d, start, i)
                var kind = int(CTok.IDENTIFIER)
                KEYWORDS |> get(word) $(k) {
                    kind = int(k)
                }
                if (kind == int(CTok.IDENTIFIER) && typedefs |> key_exists(word)) {
                    kind = int(CTok.TYPEDEF_NAME)
                }
                out |> emplace(Tok(kind = kind, text = word, line = line))
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
                out |> emplace(
                               Tok(kind = int(is_float ? CTok.F_CONSTANT : CTok.I_CONSTANT),
                                   text = word, line = line))
                continue
            }
            if (c == '"' || c == '\''
                || ((c == 'L' || c == 'u' || c == 'U') && i + 1 < n
                    && (int(d[i + 1]) == '"' || int(d[i + 1]) == '\''))) {
                if (c != '"' && c != '\'') {
                    i++
                }
                let quote = int(d[i])
                i++
                while (i < n && int(d[i]) != quote) {
                    if (int(d[i]) == '\\') {
                        i++
                    }
                    i++
                }
                i++
                out |> emplace(
                               Tok(kind = int(quote == '"' ? CTok.STRING_LITERAL : CTok.I_CONSTANT),
                                   text = slice(d, start, i), line = line))
                continue
            }
            if (i + 2 < n) {
                let s3 = slice(d, i, i + 3)
                var p3 = -1
                PUNCT3 |> get(s3) $(v) {
                    p3 = int(v)
                }
                if (p3 >= 0) {
                    out |> emplace(Tok(kind = p3, text = s3, line = line))
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
                    out |> emplace(Tok(kind = p2, text = s2, line = line))
                    i += 2
                    continue
                }
            }
            out |> emplace(Tok(kind = c, text = slice(d, i, i + 1), line = line))
            i++
        }
    }
    return <- out
}

let PUNCT3 <- { "..." => CTok.ELLIPSIS, ">>=" => CTok.RIGHT_ASSIGN, "<<=" => CTok.LEFT_ASSIGN }
let PUNCT2 <- {
    "+=" => CTok.ADD_ASSIGN, "-=" => CTok.SUB_ASSIGN, "*=" => CTok.MUL_ASSIGN, "/=" => CTok.DIV_ASSIGN,
    "%=" => CTok.MOD_ASSIGN, "&=" => CTok.AND_ASSIGN, "^=" => CTok.XOR_ASSIGN, "|=" => CTok.OR_ASSIGN,
    ">>" => CTok.RIGHT_OP, "<<" => CTok.LEFT_OP, "++" => CTok.INC_OP, "--" => CTok.DEC_OP, "->" => CTok.PTR_OP,
    "&&" => CTok.AND_OP, "||" => CTok.OR_OP, "<=" => CTok.LE_OP, ">=" => CTok.GE_OP, "==" => CTok.EQ_OP,
    "!=" => CTok.NE_OP
}

//! the dasFlex lexer in one of its generated shapes: raw tokens
def lex_flex(text : string; typedefs : table<string; int>; shape : string) : array<Tok> {
    var out : array<Tok>
    var lx : FlexLexer
    lx.symbols := typedefs
    flex_open(lx, text)
    if (shape == "goto") {
        while (c_next_goto(lx)) {
            out |> emplace(Tok(kind = lx.tok.kind, text = text(lx), line = lx.tok.line))
        }
    } elif (shape == "flex-dgoto") {
        while (c_next_dgoto(lx)) {
            out |> emplace(Tok(kind = lx.tok.kind, text = text(lx), line = lx.tok.line))
        }
    } elif (shape == "flex-dtree") {
        while (c_next_dtree(lx)) {
            out |> emplace(Tok(kind = lx.tok.kind, text = text(lx), line = lx.tok.line))
        }
    } elif (shape == "flex-inline") {
        while (c_next_inline(lx)) {
            out |> emplace(Tok(kind = lx.tok.kind, text = text(lx), line = lx.tok.line))
        }
    } elif (shape == "goto-dgoto") {
        while (c_next_goto_dgoto(lx)) {
            out |> emplace(Tok(kind = lx.tok.kind, text = text(lx), line = lx.tok.line))
        }
    } else {
        while (c_next(lx)) {
            out |> emplace(Tok(kind = lx.tok.kind, text = text(lx), line = lx.tok.line))
        }
    }
    if (lx.failed) {
        print("{lx.err}\n")
    }
    return <- out
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
                  ["[a-zA-Z_][a-zA-Z_0-9]*", "-2"],
                  ["0[xX][a-fA-F0-9]+", "{int(CTok.I_CONSTANT)}"],
                  ["0[xX][a-fA-F0-9]+(ull|uLL|Ull|ULL|llu|llU|LLu|LLU|ul|uL|Ul|UL|lu|lU|Lu|LU|ll|LL|u|U|l|L)", "{int(CTok.I_CONSTANT)}"],
                  ["[1-9][0-9]*", "{int(CTok.I_CONSTANT)}"],
                  ["[1-9][0-9]*(ull|uLL|Ull|ULL|llu|llU|LLu|LLU|ul|uL|Ul|UL|lu|lU|Lu|LU|ll|LL|u|U|l|L)", "{int(CTok.I_CONSTANT)}"],
                  ["0[0-7]*", "{int(CTok.I_CONSTANT)}"],
                  ["0[0-7]*(ull|uLL|Ull|ULL|llu|llU|LLu|LLU|ul|uL|Ul|UL|lu|lU|Lu|LU|ll|LL|u|U|l|L)",
                   "{int(CTok.I_CONSTANT)}"],
                  ["(u|U|L)?'([^'\\\\\n]|(\\\\([\'\"?\\\\abfnrtv]|[0-7]+|x[a-fA-F0-9]+)))+'",
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
                  ["(u8|u|U|L)?\"([^\"\\\\\n]|(\\\\([\'\"?\\\\abfnrtv]|[0-7]+|x[a-fA-F0-9]+)))*\"",
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
              var rules : array<ReRule>) : array<Tok> {
    var out : array<Tok>
    var pos = 0
    var line = 1
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
            if (best < 0 || best_end <= pos) {
                print("regex lexer: no rule at {pos} line {line}\n")
                break
            }
            for (p in range(pos, best_end)) {
                if (int(d[p]) == '\n') {
                    line++
                }
            }
            let kind = rules[best].kind
            if (kind == -4) {
                // a comment: skip to the closing */
                var p = best_end
                while (p + 1 < n && !(int(d[p]) == '*' && int(d[p + 1]) == '/')) {
                    if (int(d[p]) == '\n') {
                        line++
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
                let word = slice(d, start, best_end)
                k = int(CTok.IDENTIFIER)
                KEYWORDS |> get(word) $(kk) {
                    k = int(kk)
                }
                if (k == int(CTok.IDENTIFIER) && typedefs |> key_exists(word)) {
                    k = int(CTok.TYPEDEF_NAME)
                }
            } elif (kind == -3) {
                k = int(d[start])
            }
            out |> emplace(Tok(kind = k, text = slice(d, start, best_end), line = line))
        }
    }
    return <- out
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

def read_file(path : string) : string {
    var text = ""
    fopen(path, "rb") $(f) {
        if (f != null) {
            text = fread(f)
        }
    }
    return text
}

def lex_mode(mode : string; text : string; typedefs : table<string; int>;
             var rules : array<ReRule>) : array<Tok> {
    if (mode == "probe") {
        return <- lex_probe(text, typedefs)
    } elif (mode == "regex") {
        return <- lex_regex(text, typedefs, rules)
    } else {
        return <- lex_flex(text, typedefs, mode)
    }
}

[export]
def main() {
    let args <- get_command_line_arguments()
    var mode = "flex"
    var dump = false
    var passes = 0
    var files : array<string>
    var after_sep = false
    var i = 0
    while (i < length(args)) {
        let a = args[i]
        if (a == "--") {
            after_sep = true
        } elif (after_sep && a == "--mode") {
            i++
            mode = args[i]
        } elif (after_sep && a == "--dump") {
            dump = true
        } elif (after_sep && a == "--time") {
            i++
            passes = to_int(args[i])
        } elif (after_sep) {
            files |> push(a)
        }
        i++
    }
    var rules <- regex_rules()
    for (path in files) {
        let text = read_file(path)
        if (empty(text)) {
            print("{path}: empty or unreadable\n")
            continue
        }
        // two lexing passes: the first learns the typedef names the second needs (the C grammar's
        // lexer hack), so every mode sees the same table
        var inscope typedefs : table<string; int>
        typedefs["__builtin_va_list"] = 1
        var inscope first_raw <- lex_mode(mode, text, typedefs, rules)
        var inscope first_toks <- filter_tokens(first_raw, typedefs)
        var inscope raw <- lex_mode(mode, text, typedefs, rules)
        var inscope seed := typedefs
        var inscope toks <- filter_tokens(raw, seed)
        if (dump) {
            for (t in toks) {
                print("{c_token_name(t.kind)}\t{t.text}\t{t.line}\n")
            }
        } else {
            print("{path}: {mode}: {length(toks)} tokens, {length(seed)} typedefs\n")
        }
        if (passes > 0) {
            var inscope times : array<double>
            times |> reserve(passes)
            for (_k in range(passes)) {
                let t0 = ref_time_ticks()
                var inscope r <- lex_mode(mode, text, typedefs, rules)
                times |> push(double(get_time_usec(t0)) / 1000.0lf)
            }
            sort(times)
            print("TIME {mode} {path} median_ms={times[length(times) / 2]} min={times[0]} max={times[length(times) - 1]} bytes={length(text)}\n")
        }
    }
}
