options gen2
options indenting = 4
options strict_smart_pointers = true

module flex_reader shared public

require daslib/ast_boost
require daslib/strings_boost
require strings

// `%flex~ name : Enum` ... `%%` at module level: a flex-like text form of a lexer. The reader turns
// the text into the source of a `[flex_text]` function - one output line per input line, so every
// diagnostic points at the line the user wrote - and the parser reads that source in place of the
// reader. `[flex_text]` (flex_macro) builds the scanner through the same core as `[flex]`.

//! The source the reader writes for a `%flex~` text, or the first error and its line in the text.
struct FlexReaderOutput {
    source : string
    err : string
    line : int          //!< 0-based line of the error within the text
}

struct private RScan {
    d : array<uint8>
    pos : int
    line : int
    err : string
    err_line : int
}

def private fail(var s : RScan; msg : string) {
    if (empty(s.err)) {
        s.err = msg
        s.err_line = s.line
    }
}

def private peek(s : RScan; k : int = 0) : int => s.pos + k < length(s.d) ? int(s.d[s.pos + k]) : -1

def private is_blank(c : int) : bool => c == ' ' || c == '\t'

def private is_ident(c : int; first : bool) : bool =>
    c == '_' || (first ? is_alpha(c) : is_alnum(c))

def private skip_blanks(var s : RScan) {
    while (is_blank(peek(s))) {
        s.pos++
    }
}

//! the rest of the line, the newline not consumed
def private rest_of_line(var s : RScan) : string {
    let start = s.pos
    while (peek(s) >= 0 && peek(s) != '\n') {
        s.pos++
    }
    return slice(s.d, start, s.pos)
}

//! past the newline that ends the current line; false at the end of the text
def private next_line(var s : RScan) : bool {
    return false if (peek(s) != '\n')
    s.pos++
    s.line++
    return true
}

//! a string literal of daslang source holding `text`
def private das_string_literal(text : string) : string =>
    "\"" + replace(replace(escape(text), "\{", "\\\{"), "\}", "\\\}") + "\""

//! a regex that matches `ch` literally
def private write_literal(var w : StringBuilderWriter; ch : int) {
    if (find("\\+*.()[]|^\{\}?$", ch) >= 0) {
        w |> write_char('\\')
    }
    w |> write_char(ch)
}

//! the inside of a flex `"..."`, the opening quote consumed: every character literal, `\"`, `\\`
//! and the control escapes (`\n`, `\t`, ...) as in a string
def private quoted(var s : RScan; var w : StringBuilderWriter) {
    while (true) {
        let c = peek(s)
        if (c < 0 || c == '\n') {
            fail(s, "a quoted literal ends at the end of the line")
            return
        }
        s.pos++
        return if (c == '"')
        if (c != '\\') {
            write_literal(w, c)
            continue
        }
        let e = peek(s)
        s.pos++
        if (e == 'n' || e == 't' || e == 'r' || e == 'f' || e == 'v') {
            w |> write_char('\\')
            w |> write_char(e)
        } elif (e < 0 || e == '\n') {
            fail(s, "a quoted literal ends at the end of the line")
            return
        } else {
            write_literal(w, e)
        }
    }
}

//! `{name}` at the cursor, when it names a definition: its regex in non-capturing parentheses, so
//! `group(n)` in an action counts only the groups the rule itself writes
def private definition_ref(var s : RScan; defs : table<string; string>) : string {
    var k = 1
    while (is_ident(peek(s, k), k == 1)) {
        k++
    }
    return "" if (k == 1 || peek(s, k) != '}')
    let name = slice(s.d, s.pos + 1, s.pos + k)
    if (!key_exists(defs, name)) {
        fail(s, "\{{name}\}: no such definition")
        return ""
    }
    s.pos += k + 1
    return "(?:{defs?[name] ?? ""})"
}

//! a flex pattern up to the first blank outside quotes and brackets, as `daslib/regex` text; a bare
//! `/` is flex's trailing context and is refused
[arch(at="../ARCHITECTURE.md#not-carried")]
def private pattern(var s : RScan; defs : table<string; string>) : string {
    return build_string() $(var w) {
        var in_set = false
        while (empty(s.err)) {
            let c = peek(s)
            break if (c < 0 || c == '\n' || (!in_set && is_blank(c)))
            if (c == '\\') {
                w |> write_char(c)
                s.pos++
                if (peek(s) < 0 || peek(s) == '\n') {
                    fail(s, "the pattern ends with a backslash")
                    break
                }
                w |> write_char(peek(s))
                s.pos++
            } elif (in_set) {
                in_set = c != ']'
                w |> write_char(c)
                s.pos++
            } elif (c == '"') {
                s.pos++
                quoted(s, w)
            } elif (c == '/') {
                fail(s, "trailing context (r/s) is not carried by dasFlex; a literal slash is "
                    + "\"/\" or \\/")
            } elif (c == '[') {
                in_set = true
                w |> write_char(c)
                s.pos++
            } else {
                let expanded = c == '{' ? definition_ref(s, defs) : ""
                if (empty(expanded)) {
                    w |> write_char(c)
                    s.pos++
                } else {
                    w |> write(expanded)
                }
            }
        }
        if (in_set && empty(s.err)) {
            fail(s, "a [set] ends at the end of the line")
        }
    }
}

//! skips a daslang string or character literal, the opening quote at the cursor
def private skip_quoted_code(var s : RScan) {
    let q = peek(s)
    s.pos++
    while (peek(s) >= 0 && peek(s) != q && peek(s) != '\n') {
        s.pos += peek(s) == '\\' ? 2 : 1
    }
    s.pos++
}

//! a `{ ... }` action, the open brace at the cursor: braces balanced outside strings and comments,
//! lines counted, the text returned as written
def private braced_action(var s : RScan) : string {
    let start = s.pos
    var depth = 0
    while (true) {
        let c = peek(s)
        if (c < 0) {
            fail(s, "the action ends at the end of the rules")
            return ""
        }
        if (c == '"' || c == '\'') {
            skip_quoted_code(s)
            continue
        }
        if (c == '/' && peek(s, 1) == '/') {
            rest_of_line(s)
            continue
        }
        if (c == '\n') {
            s.line++
        } elif (c == '{') {
            depth++
        } elif (c == '}') {
            depth--
        }
        s.pos++
        break if (depth == 0)
    }
    return slice(s.d, start, s.pos)
}

//! `<A,B>` at the cursor as `A,B`; `<*>` as `*`; "" without a prefix
def private rule_conditions(var s : RScan) : string {
    return "" if (peek(s) != '<')
    s.pos++
    let names = rest_of_line(s)
    let close = find(names, ">")
    if (close < 0) {
        fail(s, "<CONDITION> expected")
        return ""
    }
    s.pos -= length(names) - close - 1
    return replace(replace(slice(names, 0, close), " ", ""), "\t", "")
}

//! one rule: `<C>pattern   { action }`, `pattern   action`, or a pattern alone (an empty action)
def private rule_line(var s : RScan; defs : table<string; string>) : string {
    let conds = rule_conditions(s)
    let re = pattern(s, defs)
    return "" if (!empty(s.err))
    if (empty(re)) {
        fail(s, "a rule starts with a pattern")
        return ""
    }
    skip_blanks(s)
    var action = "\{\}"
    if (peek(s) == '{') {
        action = braced_action(s)
        skip_blanks(s)
        if (peek(s) == '/' && peek(s, 1) == '/') {
            rest_of_line(s)
        } elif (peek(s) >= 0 && peek(s) != '\n') {
            fail(s, "nothing but a comment follows an action on its line")
        }
    } elif (peek(s) >= 0 && peek(s) != '\n') {
        let code = rest_of_line(s)
        if (find(code, "//") >= 0) {
            fail(s, "an action with a comment on its line is written in braces")
        }
        action = "\{ {code} \}"
    }
    return "rule({das_string_literal(re)}, {das_string_literal(conds)}) {action}"
}

//! the header `name : Enum` (the enum optional): the function name and the token enum
def private header(var s : RScan) : tuple<name : string; tokens : string> {
    let parts <- split(rest_of_line(s), ":")
    let name = trim(parts[0])
    let tokens = length(parts) > 1 ? trim(parts[1]) : ""
    var ok = length(parts) <= 2 && !empty(name)
    for (part in [name, tokens]) {
        for (i, c in count(), part) {
            ok &&= is_ident(c, i == 0)
        }
    }
    if (!ok) {
        fail(s, "the header is `%flex~ name : TokenEnum`")
    }
    return (name = name, tokens = tokens)
}

//! why a start condition named `name` cannot be declared again
def duplicate_condition(name : string) : string {
    return "INITIAL is every lexer's default start condition, declared already" if (name == "INITIAL")
    return "a start condition of that name is declared already"
}

struct private Definitions {
    defs : table<string; string>
    conditions : array<string>
    shape_args : array<string>
}

//! one line of the definitions section: `%x` / `%s` start conditions, `%option key=value`, or a
//! `NAME regex` definition
def private definition_line(var s : RScan; var out : Definitions; line : string) {
    var inscope items : array<string>
    for (word in split_by_chars(line, " \t")) {
        if (!empty(word)) {
            items |> push(word)
        }
    }
    let head = items[0]
    if (head == "%x" || head == "%s") {
        out.conditions |> reserve(length(out.conditions) + length(items))
        for (i in range(1, length(items))) {
            let name = items[i]
            if (name == "INITIAL" || out.conditions |> has_value("{name}:x")
                || out.conditions |> has_value("{name}:s")) {
                fail(s, "{head} {name}: {duplicate_condition(name)}")
                return
            }
            out.conditions |> push("{name}:{head == "%x" ? "x" : "s"}")
        }
    } elif (head == "%option") {
        out.shape_args |> reserve(length(out.shape_args) + length(items))
        for (i in range(1, length(items))) {
            var inscope kv <- split(items[i], "=")
            if (length(kv) != 2 || (kv[0] != "mode" && kv[0] != "dispatch" && kv[0] != "matcher")) {
                fail(s, "%option takes mode=, dispatch= and matcher=, not {items[i]}")
                return
            }
            out.shape_args |> push("{kv[0]} = {das_string_literal(kv[1])}")
        }
    } elif (is_ident(first_character(head), true) && length(items) > 1) {
        var def_scan = RScan(d <- to_bytes(trim(slice(line, length(head)))))
        let re = pattern(def_scan, out.defs)
        if (!empty(def_scan.err)) {
            fail(s, def_scan.err)
        } elif (def_scan.pos != length(def_scan.d)) {
            fail(s, "a definition is `NAME regex`, one pattern")
        } else {
            out.defs[head] = re
        }
    } else {
        fail(s, "a definition is `%x NAMES`, `%s NAMES`, `%option key=value` or `NAME regex`")
    }
}

//! the translation: the `[flex_text]` function, one output line per line of `text`
def flex_reader_source(text : string) : FlexReaderOutput {
    var s = RScan(d <- to_bytes(text))
    let head = header(s)
    var defs : Definitions
    var sep_found = false
    while (empty(s.err) && next_line(s)) {
        let line = trim(rest_of_line(s))
        if (line == "%rules") {
            sep_found = true
            break
        }
        if (!empty(line) && !starts_with(line, "//")) {
            definition_line(s, defs, line)
        }
    }
    if (!sep_found && empty(s.err)) {
        fail(s, "the rules section starts at a line `%rules`")
    }
    let rules = build_string() $(var w) {
        while (empty(s.err) && next_line(s)) {
            w |> write("\n")
            skip_blanks(s)
            if (peek(s) == '/' && peek(s, 1) == '/') {
                rest_of_line(s)
            } elif (peek(s) >= 0 && peek(s) != '\n') {
                w |> write(rule_line(s, defs.defs))
            }
        }
    }
    if (!empty(s.err)) {
        return FlexReaderOutput(err = s.err, line = s.err_line)
    }
    var inscope args <- ["tokens = {das_string_literal(head.tokens)}",
                         "conditions = {das_string_literal(join(defs.conditions, " "))}"]
    args |> push_from(defs.shape_args)
    let blank_lines = repeat("\n", s.line - count(rules, "\n"))
    let source = ("[flex_text({join(args, ", ")})] def {head.name}(var lx : FlexLexer) : bool \{"
        + blank_lines + rules + "\n\}\n")
    return FlexReaderOutput(source = source)
}

//! the reader ends at the first `%%`, as every reader does, so tools that skip reader text agree
def private flex_reader_accept(var expr : ExprReader?; ch : int) : bool {
    if (ch != '\r') {
        append(expr.sequence, ch)
    }
    return true if (ch != '%' || !ends_with(expr.sequence, "%%"))
    resize(expr.sequence, length(expr.sequence) - 2)
    return false
}

[reader_macro(name="flex")]
class FlexReader : AstReaderMacro {
    def override accept(prog : ProgramPtr; mod : Module?; var expr : ExprReader?; ch : int;
                        info : LineInfo) : bool => flex_reader_accept(expr, ch)
    def override suffix(prog : ProgramPtr; mod : Module?; var expr : ExprReader?; info : LineInfo;
                        var outLine : int&; var outFile : FileInfo?&) : string {
        let out = flex_reader_source(string(expr.sequence))
        if (!empty(out.err)) {
            var at = info
            at.line = uint(int(info.line) + out.line)
            prog |> macro_error(at, "%flex~: {out.err}")
            return ""
        }
        outLine = int(info.line)
        outFile = expr.at.fileInfo
        return out.source
    }
}
