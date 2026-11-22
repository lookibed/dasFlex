options gen2
options indenting = 4
options strict_smart_pointers = true

module flex shared public

require daslib/strings_boost

// The scanner the generated code drives: input as raw bytes, a cursor, the token the last rule
// emitted, and line/column kept by counting newlines in each consumed span. Nothing here allocates;
// `text()` is the one call that builds a string, on request.

//! A token as the parser sees it: the kind the rule emitted, its byte span and where it starts.
struct FlexToken {
    kind : int
    start : int
    len : int
    line : int
    col : int
    text : string       //!< the matched text once `text()` built it; "" until then
}

//! The scanner state. `symbols` is the table a parser fills and a rule consults (C `typedef` names).
struct FlexLexer {
    bytes : array<uint8>        //!< the input, one copy made at `flex_open`
    data : uint8 const?         //!< `bytes` as a raw pointer for the inner loop
    len : int
    pos : int
    line : int
    col : int
    cond : int                  //!< the active start condition
    tok : FlexToken
    emitted : bool              //!< the last rule called `emit`
    failed : bool               //!< a byte no rule accepts was met
    file : string
    symbols : table<string; int>
    err : string
}

//! Open `src` for scanning: the bytes are copied once, the string may go.
def flex_open(var lx : FlexLexer; src : string; file : string = "") {
    lx.bytes <- to_bytes(src)
    lx.len = length(lx.bytes)
    lx.data = lx.len > 0 ? unsafe(addr(lx.bytes[0])) : null
    lx.pos = 0
    lx.line = 1
    lx.col = 1
    lx.cond = 0
    lx.emitted = false
    lx.failed = false
    lx.file = file
    lx.err = ""
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

//! A length-bounded comparison of the matched text with `s`, no allocation.
def text_is(lx : FlexLexer; s : string) : bool {
    return false if (length(s) != lx.tok.len)
    unsafe {
        return memcmp(reinterpret<void?>(lx.data + lx.tok.start), reinterpret<void?>(s),
                      lx.tok.len) == 0
    }
}

//! The error text for the byte at the cursor that no rule accepts: the UTF-8 character there, or
//! the byte when it is not one.
def flex_error_text(lx : FlexLexer) : string {
    var shown = "end of input"
    if (lx.pos < lx.len) {
        let b = int(unsafe(lx.data[lx.pos]))
        let seq_len = b < 128 ? 1 : (b >= 194 && b <= 223 ? 2 : (b >= 224 && b <= 239 ? 3 : (b >= 240 && b <= 244 ? 4 : 0)))
        if (seq_len == 0 || lx.pos + seq_len > lx.len) {
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
