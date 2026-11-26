options gen2
options indenting = 4
options strict_smart_pointers = true

module flex shared public

require daslib/strings_boost
require daslib/regex
require flex/flex_symbols public
require flex/flex_tier

// The scanner the generated code drives: input as raw bytes, a cursor, the token the last rule
// emitted, and line/column kept by counting newlines in each consumed span. Matching and taking a
// token allocate nothing; `text()`, the group calls and the error text build strings, each only
// when a rule body or a failed match asks.

//! A token as the parser sees it: the kind the rule emitted, its byte span and where it starts.
struct FlexToken {
    kind : int
    start : int
    len : int
    line : int
    col : int
    text : string       //!< the matched text once `text()` built it; "" until then
    sym : int           //!< the symbol `intern(lx)` found; -1 if none, from `flex_open` on
    has_space : bool    //!< a skipping rule ran since the previous token
    at_bol : bool       //!< the first token of the input, or one a newline separates from the previous token
}

//! The scanner state.
struct FlexLexer {
    bytes : array<uint8>        //!< the input, one copy made at `flex_open`
    data : uint8?               //!< `bytes` as a raw pointer for the inner loop; a zero past the input
    len : int
    pos : int
    line : int
    col : int
    cond : int                  //!< the active start condition
    tok : FlexToken
    emitted : bool              //!< the last rule called `emit`
    failed : bool               //!< a byte no rule accepts was met
    file : string
    syms : FlexSymbols          //!< names by their bytes, a kind each
    err : string
    groups : array<range>       //!< the capture groups of one token, input offsets; -1 where absent
    groups_start : int          //!< the `tok.start` `groups` belong to
    groups_re : uint64          //!< the regex that filled `groups`, 0 when none did
    space_pending : bool        //!< the next token's `has_space`
    bol_pending : bool          //!< the next token's `at_bol`
    bol_saved : bool            //!< `bol_pending` as a rule body keeps it across skipped text; the scanner never touches it
}

//! Open `src` for scanning: the bytes are copied once, the string may go.
[arch(at="../ARCHITECTURE_TOKENS.md#pp-flags")]
def flex_open(var lx : FlexLexer; src : string; file : string = "") {
    flex_symbols_detach(lx.syms)
    lx.tok.sym = -1
    lx.bytes <- to_bytes(src)
    lx.len = length(lx.bytes)
    lx.bytes |> push(0u8)
    lx.data = unsafe(addr(lx.bytes[0]))
    lx.pos = 0
    lx.line = 1
    lx.col = 1
    lx.cond = 0
    lx.emitted = false
    lx.failed = false
    lx.file = file
    lx.err = ""
    lx.groups_re = 0ul
    lx.space_pending = false
    lx.bol_pending = true
}

def flex_at_end(lx : FlexLexer) : bool => lx.pos >= lx.len

//! A rule's action: the matched span is the token of kind `k`.
def emit(var lx : FlexLexer; k : auto) {
    lx.tok.kind = int(k)
    lx.emitted = true
}

//! A rule's action: switch the start condition.
def begin(var lx : FlexLexer; cond : int) {
    lx.cond = cond
}

//! The matched text as a string, built on the first call for a token and reused by the next ones.
def text(var lx : FlexLexer) : string {
    if (empty(lx.tok.text)) {
        lx.tok.text = slice(lx.bytes, lx.tok.start, lx.tok.start + lx.tok.len)
    }
    return lx.tok.text
}

//! The regex a rule's `group` calls re-run on the token: the rule's pattern anchored at the token's
//! end, so the match it finds covers the whole token.
def flex_group_pattern(pattern : string) : string => "(?:{pattern})$"

//! The initializer of the module global holding a rule's group regex.
def flex_group_regex(pattern : string) : Regex => <- regex_compile(flex_group_pattern(pattern))

//! the groups of the current token through `re`, run on the first call for the token and kept
//! for the next ones; group 0 is the token itself
def private flex_groups_of(var lx : FlexLexer; var re : Regex) {
    let key = intptr(unsafe(addr(re)))
    return if (lx.groups_re == key && lx.groups_start == lx.tok.start)
    lx.groups_re = key
    lx.groups_start = lx.tok.start
    for (g in re.groups) {
        g._0 = range(-1, -1)
    }
    let matched = regex_match(re, text(lx), 0) == lx.tok.len
    lx.groups |> resize(length(re.groups))
    let at = lx.tok.start
    for (i, g in count(), re.groups) {
        let span = g._0
        lx.groups[i] = matched && span.x >= 0 ? range(span.x + at, span.y + at) : range(-1, -1)
    }
    lx.groups[0] = range(lx.tok.start, lx.tok.start + lx.tok.len)
}

//! `group(lx, index)` in a rule body: the text of capture group `index` of the token, "" when the
//! group took no part in the match
def flex_group(var lx : FlexLexer; var re : Regex; index : int) : string {
    let span = flex_group_span(lx, re, index)
    return span.y > span.x ? slice(lx.bytes, span.x, span.y) : ""
}

//! `group_span(lx, index)` in a rule body: the input bytes capture group `index` of the token
//! covers, `range(0, 0)` when the group took no part in the match
def flex_group_span(var lx : FlexLexer; var re : Regex; index : int) : range {
    flex_groups_of(lx, re)
    if (index < 0 || index >= length(lx.groups)) {
        panic("group({index}): the rule's regex has {length(lx.groups) - 1} groups")
    }
    let span = lx.groups[index]
    return span.x < 0 ? range(0, 0) : span
}

//! The symbol of the matched text, by its bytes and without a string;
//! also kept as `tok.sym`. A native interner reads the text in place:
//! the byte after the token is a zero for the table lookup alone.
[arch(at="../ARCHITECTURE_SYMBOLS.md#symbols"), inline]
def intern(var lx : FlexLexer) : int {
    static_if (flex_jit_tier()) {
        if (lx.syms.shape != FlexSymbolsShape.native) {
            lx.tok.sym = intern(lx.syms, lx.data, lx.tok.start, lx.tok.len)
            return lx.tok.sym
        }
    } else {
        if (lx.syms.shape == FlexSymbolsShape.probing) {
            lx.tok.sym = intern(lx.syms, lx.data, lx.tok.start, lx.tok.len)
            return lx.tok.sym
        }
    }
    unsafe {
        let p = lx.data + lx.tok.start
        var after = lx.data + (lx.tok.start + lx.tok.len)
        let saved = *after
        *after = 0u8
        var id = lx.syms.ids?[reinterpret<string>(p)] ?? -1
        *after = saved
        if (id < 0) {
            id = intern_new(lx.syms, p, lx.tok.len)
        } elif (lx.syms.entries[id].plain_len != lx.tok.len) {
            id = intern_unsettled(lx.syms, p, lx.tok.len, id)
        }
        lx.tok.sym = id
        return id
    }
}

//! A length-bounded comparison of the matched text with `s`, no allocation.
def text_is(lx : FlexLexer; s : string) : bool {
    return false if (length(s) != lx.tok.len)
    unsafe {
        return memcmp(reinterpret<void?>(lx.data + lx.tok.start), reinterpret<void?>(s),
                      lx.tok.len) == 0
    }
}

//! a lead byte in `lo..hi` starts a UTF-8 character of `len` bytes, each byte after the first a
//! continuation byte `0x80..0xBF`
struct Utf8Lead {
    lo : int
    hi : int
    len : int
}

//! the lead bytes of UTF-8 by character length, the overlong `0xC0`, `0xC1` and everything past
//! U+10FFFF (`0xF5..0xFF`) left out; `.` and the error text both read it
let UTF8_LEADS = fixed_array(Utf8Lead(lo = 0, hi = 127, len = 1),
                             Utf8Lead(lo = 194, hi = 223, len = 2),
                             Utf8Lead(lo = 224, hi = 239, len = 3),
                             Utf8Lead(lo = 240, hi = 244, len = 4))

//! the byte length of the UTF-8 character at `pos`: its lead byte and that many continuation bytes
//! (`0x80..0xBF`) in the input, 0 when the bytes there are not one
def private utf8_char_len(lx : FlexLexer; pos : int) : int {
    let b = int(unsafe(lx.data[pos]))
    let lead = find_index_if(UTF8_LEADS) $(l) => b >= l.lo && b <= l.hi
    return 0 if (lead < 0)
    let n = UTF8_LEADS[lead].len
    return 0 if (pos + n > lx.len)
    for (k in range(1, n)) {
        return 0 if ((int(unsafe(lx.data[pos + k])) & 0xC0) != 0x80)
    }
    return n
}

//! The error text for the byte at the cursor that no rule accepts: the UTF-8 character there, or
//! the byte when it is not one.
def flex_error_text(lx : FlexLexer) : string {
    var shown = "end of input"
    if (lx.pos < lx.len) {
        let b = int(unsafe(lx.data[lx.pos]))
        let seq_len = utf8_char_len(lx, lx.pos)
        if (seq_len == 0) {
            shown = "byte {b}"
        } elif (b < 32 || b == 127) {
            shown = "control byte {b}"
        } else {
            shown = "'{slice(lx.bytes, lx.pos, lx.pos + seq_len)}'"
        }
    }
    let place = empty(lx.file) ? "" : "{lx.file}:"
    return "{place}{lx.line}:{lx.col}: unexpected {shown}"
}

//! Advance the position by the matched span; line and column follow the newlines in it.
def flex_consume(var lx : FlexLexer; start, len : int) {
    lx.tok.start = start
    lx.tok.len = len
    lx.tok.text = ""
    lx.tok.sym = -1
    lx.tok.line = lx.line
    lx.tok.col = lx.col
    let stop = start + len
    for (i in range(start, stop)) {
        if (unsafe(lx.data[i]) == uint8(10)) {
            lx.line++
            lx.col = 1
        } else {
            lx.col++
        }
    }
    lx.pos = stop
}

//! The table-driven matcher: the longest match from `pos` in condition `cond`, the rule it accepts
//! (the first-written rule on a tie - the tables already carry that choice) or -1. `next` is
//! `nstates x nclasses`, `-1` for no move; `class_of` maps the 256 bytes.
def flex_match_table(lx : FlexLexer; next, accept, class_of : array<int>; nclasses : int;
                     start_state : int; var out_len : int&) : int {
    var state = start_state
    var best_rule = -1
    var best_len = 0
    var i = lx.pos
    let n = lx.len
    while (i < n) {
        let cls = class_of[int(unsafe(lx.data[i]))]
        state = next[state * nclasses + cls]
        if (state < 0) {
            break
        }
        i++
        let acc = accept[state]
        if (acc >= 0) {
            best_rule = acc
            best_len = i - lx.pos
        }
    }
    if (best_rule < 0 && accept[start_state] >= 0) {
        best_rule = accept[start_state]
    }
    out_len = best_len
    return best_rule
}
