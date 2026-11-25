options gen2
options indenting = 4
options strict_smart_pointers = true

module flex_regex shared public

require daslib/regex
require daslib/strings_boost
require daslib/utf8_utils
require daslib/cmp
require math
require flex/flex

// Regular expressions to a byte NFA: `daslib/regex` parses the text (its tree is the one input here,
// never re-parsed), Thompson's construction turns each node into a fragment over byte ranges with
// epsilon edges. `.` is one UTF-8 code point other than a newline, spelled as the byte sequences of
// UTF-8 (`UTF8_LEADS` in flex/flex.das). The forms a DFA cannot carry - anchors, word boundaries, lookahead, lazy quantifiers - are
// refused with the text that names them.

//! One byte-range edge: every byte in `lo..hi` moves to `to`.
struct NfaEdge {
    lo : int
    hi : int
    to : int
}

//! The NFA under construction: edges and epsilon lists per state, the rule a state accepts.
struct Nfa {
    edges : array<array<NfaEdge>>
    eps : array<array<int>>
    accept : array<int>         //!< per state: the rule id it accepts, or -1
    starts : array<int>         //!< per start condition: its start state
    err : string                //!< "" while every rule compiled, else the first refusal
    err_rule : int = -1         //!< the rule `err` names
}

//! A fragment: entry state and exit state (the exit has no outgoing edges yet).
struct Frag {
    first : int
    last : int
}

def new_state(var n : Nfa) : int {
    let id = length(n.accept)
    var e : array<NfaEdge>
    n.edges |> emplace(e)
    var p : array<int>
    n.eps |> emplace(p)
    n.accept |> push(-1)
    return id
}

def add_edge(var n : Nfa; from, lo, hi, to : int) {
    n.edges[from] |> push(NfaEdge(lo = lo, hi = hi, to = to))
}

def add_eps(var n : Nfa; from, to : int) {
    n.eps[from] |> push(to)
}

//! a fragment that accepts the bytes of `text` in order
def frag_text(var n : Nfa; text : string) : Frag {
    let a = new_state(n)
    var cur = a
    peek_data(text) $(d) {
        for (b in d) {
            let nx = new_state(n)
            add_edge(n, cur, int(b), int(b), nx)
            cur = nx
        }
    }
    return Frag(first = a, last = cur)
}

//! a fragment over a 256-bit byte set, one edge per run of set bytes
def frag_set(var n : Nfa; cset : CharSet) : Frag {
    let a = new_state(n)
    let b = new_state(n)
    var run_lo = -1
    for (c in range(257)) {
        let inside = c < 256 && is_char_in_set(c, cset)
        if (inside && run_lo < 0) {
            run_lo = c
        } elif (!inside && run_lo >= 0) {
            add_edge(n, a, run_lo, c - 1, b)
            run_lo = -1
        }
    }
    return Frag(first = a, last = b)
}

//! `.`: one UTF-8 code point that is not a newline - a path per lead-byte shape of `UTF8_LEADS`
def frag_any_codepoint(var n : Nfa) : Frag {
    let a = new_state(n)
    let b = new_state(n)
    for (lead in UTF8_LEADS) {
        if (lead.len == 1) {
            add_edge(n, a, lead.lo, '\n' - 1, b)
            add_edge(n, a, '\n' + 1, lead.hi, b)
            continue
        }
        var at = new_state(n)
        add_edge(n, a, lead.lo, lead.hi, at)
        for (_k in range(lead.len - 2)) {
            let next = new_state(n)
            add_edge(n, at, 128, 191, next)
            at = next
        }
        add_edge(n, at, 128, 191, b)
    }
    return Frag(first = a, last = b)
}

def frag_concat(var n : Nfa; x, y : Frag) : Frag {
    add_eps(n, x.last, y.first)
    return Frag(first = x.first, last = y.last)
}

def frag_union(var n : Nfa; parts : array<Frag>) : Frag {
    let a = new_state(n)
    let b = new_state(n)
    for (p in parts) {
        add_eps(n, a, p.first)
        add_eps(n, p.last, b)
    }
    return Frag(first = a, last = b)
}

def frag_optional(var n : Nfa; x : Frag) : Frag {
    let a = new_state(n)
    let b = new_state(n)
    add_eps(n, a, x.first)
    add_eps(n, a, b)
    add_eps(n, x.last, b)
    return Frag(first = a, last = b)
}

def frag_star(var n : Nfa; x : Frag) : Frag {
    let a = new_state(n)
    let b = new_state(n)
    add_eps(n, a, x.first)
    add_eps(n, a, b)
    add_eps(n, x.last, x.first)
    add_eps(n, x.last, b)
    return Frag(first = a, last = b)
}

[arch(at="../ARCHITECTURE.md#not-carried")]
def private refuse(var n : Nfa; what : string; node : ReNode?) {
    if (empty(n.err)) {
        n.err = "{what} at offset {node.at.x} does not fit a DFA and is not carried by dasFlex"
    }
}

//! Thompson's construction over the regex tree; a refused node leaves `n.err` set and an empty fragment.
def frag_of(var n : Nfa; node : ReNode?) : Frag {
    if (node == null) {
        let a = new_state(n)
        return Frag(first = a, last = a)
    }
    if (node.op == ReOp.Char) {
        return frag_text(n, node.text)
    } elif (node.op == ReOp.Set) {
        return frag_set(n, node.cset)
    } elif (node.op == ReOp.Any) {
        return frag_any_codepoint(n)
    } elif (node.op == ReOp.Group) {
        return frag_of(n, node.subexpr)
    } elif (node.op == ReOp.Concat) {
        let x = frag_of(n, node.left)
        let y = frag_of(n, node.right)
        return frag_concat(n, x, y)
    } elif (node.op == ReOp.Union) {
        let parts <- [for (sub in node.all); frag_of(n, sub)]
        return frag_union(n, parts)
    } elif (node.op == ReOp.Star || node.op == ReOp.Plus || node.op == ReOp.Question
            || node.op == ReOp.Repeat) {
        if (node.lazy) {
            refuse(n, "a lazy quantifier", node)
        }
        return frag_repeat(n, node.subexpr, node.min_rep, node.max_rep)
    } elif (node.op == ReOp.Bos || node.op == ReOp.Eos) {
        refuse(n, "an anchor (^ or $)", node)
    } elif (node.op == ReOp.WordBoundary || node.op == ReOp.NonWordBoundary) {
        refuse(n, "a word boundary", node)
    } elif (node.op == ReOp.Lookahead || node.op == ReOp.NegativeLookahead) {
        refuse(n, "a lookahead group", node)
    } else {
        refuse(n, "an unsupported regex node", node)
    }
    let a = new_state(n)
    return Frag(first = a, last = a)
}

//! `sub{min,max}`: `min` copies then `max - min` optional copies; `max < 0` is unbounded (a star tail)
def frag_repeat(var n : Nfa; sub : ReNode?; min_rep, max_rep : int) : Frag {
    let a = new_state(n)
    var cur = Frag(first = a, last = a)
    for (_i in range(min_rep)) {
        let x = frag_of(n, sub)
        cur = frag_concat(n, cur, x)
    }
    if (max_rep < 0) {
        let x = frag_of(n, sub)
        cur = frag_concat(n, cur, frag_star(n, x))
    } else {
        for (_i in range(max_rep - min_rep)) {
            let x = frag_of(n, sub)
            cur = frag_concat(n, cur, frag_optional(n, x))
        }
    }
    return cur
}

//! the result of `flex_codepoints`: the pattern `daslib/regex` reads, or why the rewrite refused it
struct CodepointText {
    text : string
    err : string
}

//! the bytes `lo..hi` as the inside of a `daslib/regex` set
def private byte_items(lo, hi : int) : string =>
    lo == hi ? "\\x{fmt(":02X", lo)}" : "\\x{fmt(":02X", lo)}-\\x{fmt(":02X", hi)}"

//! the byte-set sequences matching exactly the UTF-8 encodings of `lo..hi`, a range of one encoded
//! length or more and no surrogate: split until every byte position is one contiguous byte range
def private utf8_sequences(lo, hi : int; var out : array<string>) {
    var stack : array<int2>
    stack |> push(int2(lo, hi))
    while (!empty(stack)) {
        let r = stack |> back()
        stack |> pop()
        var parts = int2(-1, -1)
        for (top in fixed_array(int(0x7F), int(0x7FF), int(0xFFFF))) {
            if (r.x <= top && top < r.y) {
                parts = int2(top, top + 1)
                break
            }
        }
        for (k in range(1, 4)) {
            break if (parts.x >= 0)
            let m = (1 << (6 * k)) - 1
            continue if ((r.x & ~m) == (r.y & ~m))
            if ((r.x & m) != 0) {
                parts = int2(r.x | m, (r.x | m) + 1)
            } elif ((r.y & m) != m) {
                parts = int2((r.y & ~m) - 1, r.y & ~m)
            }
        }
        if (parts.x >= 0) {
            stack |> push(int2(parts.y, r.y))
            stack |> push(int2(r.x, parts.x))
            continue
        }
        var inscope a <- utf8_encode(uint(r.x))
        var inscope b <- utf8_encode(uint(r.y))
        out |> push(join([for (i in range(length(a))); "[{byte_items(int(a[i]), int(b[i]))}]"], ""))
    }
}

//! `r` without the surrogates `D800..DFFF`, appended to `out`
def private push_scalar_values(var out : array<int2>; r : int2) {
    out |> push(int2(r.x, min(r.y, int(0xD7FF)))) if (r.x <= 0xD7FF)
    out |> push(int2(max(r.x, int(0xE000)), r.y)) if (r.y >= 0xE000)
}

//! sorted and merged, the complement over `0..10FFFF` when `negate`, the surrogates `D800..DFFF`
//! taken out
def private codepoint_ranges(var ranges : array<int2>; negate : bool) : array<int2> {
    sort(ranges) <| cmp_by(_.x)
    var merged : array<int2>
    for (r in ranges) {
        let last = length(merged) - 1
        if (last >= 0 && r.x <= merged[last].y + 1) {
            merged[last].y = max(merged[last].y, r.y)
        } else {
            merged |> push(r)
        }
    }
    var out : array<int2>
    if (!negate) {
        for (r in merged) {
            push_scalar_values(out, r)
        }
        return <- out
    }
    var next = 0
    for (r in merged) {
        push_scalar_values(out, int2(next, r.x - 1)) if (r.x > next)
        next = r.y + 1
    }
    push_scalar_values(out, int2(next, int(0x10FFFF))) if (next <= 0x10FFFF)
    return <- out
}

//! a set of code points as `daslib/regex` text: one byte set for the ASCII part and a byte-set
//! sequence per UTF-8 shape for the rest, in one non-capturing group
def private codepoint_set_text(ranges : array<int2>) : string {
    var alts : array<string>
    let ascii = join([for (r in ranges); byte_items(r.x, min(r.y, int(0x7F))); where r.x < 0x80], "")
    if (!empty(ascii)) {
        alts |> push("[{ascii}]")
    }
    for (r in ranges) {
        utf8_sequences(max(r.x, int(0x80)), r.y, alts) if (r.y >= 0x80)
    }
    return empty(alts) ? "(?:[^\\x00-\\xFF])" : "(?:{join(alts, "|")})"
}

//! the code point of the escape `\uHHHH` or `\UHHHHHHHH` at `at`, -1 when its digits are not all hex
//! or it names a surrogate or a value past `10FFFF`
def private escape_codepoint(d : array<uint8>#; at : int) : int {
    let digits = int(d[at + 1]) == 'u' ? 4 : 8
    return -1 if (at + 2 + digits > length(d))
    var cp = 0
    for (k in range(digits)) {
        let h = int(d[at + 2 + k])
        return -1 if (!is_hex(h))
        cp = cp * 16 + (is_number(h) ? h - '0' : (h | 0x20) - 'a' + 10)
        return -1 if (cp > 0x10FFFF)
    }
    return (cp >= 0xD800 && cp <= 0xDFFF) ? -1 : cp
}

def private is_codepoint_escape(d : array<uint8>#; at : int) : bool =>
    int(d[at]) == '\\' && at + 1 < length(d) && (int(d[at + 1]) == 'u' || int(d[at + 1]) == 'U')

//! the index of the `]` closing the set that opens at `at`, -1 when the set does not close; whether a
//! code-point escape stands inside it
def private set_end(d : array<uint8>#; at : int) : int2 {
    var j = at + 1
    var has_escape = 0
    while (j < length(d)) {
        return int2(j, has_escape) if (int(d[j]) == ']')
        if (int(d[j]) == '\\') {
            has_escape = is_codepoint_escape(d, j) ? 1 : has_escape
            j++
        }
        j++
    }
    return int2(-1, 0)
}

let private CONTROL_ESCAPES <- { 'n' => 10, 'r' => 13, 't' => 9, 'f' => 12, 'v' => 11 }

//! the set between `at` (its `[`) and `close` (its `]`) read as code points: characters below 128,
//! their escapes and the code-point escapes, ranges of them; `err` set on anything else
def private codepoint_set(d : array<uint8>#; at, close : int; var err : string&) : string {
    var j = at + 1
    let negate = int(d[j]) == '^'
    j += negate ? 1 : 0
    var ranges : array<int2>
    var low = -1
    var dash = false
    while (j < close && empty(err)) {
        var cp = int(d[j])
        var len = 1
        if (cp == '-' && low >= 0 && !dash && j + 1 < close) {
            dash = true
            j++
            continue
        }
        if (is_codepoint_escape(d, j)) {
            cp = escape_codepoint(d, j)
            len = int(d[j + 1]) == 'u' ? 6 : 10
            err = cp < 0 ? "the escape at offset {j} names no code point" : err
        } elif (cp == '\\') {
            let e = int(d[j + 1])
            len = 2
            cp = CONTROL_ESCAPES?[e] ?? e
            if (is_alpha(e) && !key_exists(CONTROL_ESCAPES, e)) {
                err = "\\{to_char(e)} at offset {j} is not taken in a code-point set"
            }
        }
        if (cp >= 0x80 && len < 6) {
            err = "byte {cp} at offset {j}: a code-point set spells a character past 127 as \\u or \\U"
        }
        j += len
        continue if (!empty(err))
        if (dash) {
            if (cp < low) {
                err = "the range ending at offset {j - len} runs backwards"
                break
            }
            ranges[length(ranges) - 1].y = cp
            dash = false
            low = -1
        } else {
            ranges |> push(int2(cp, cp))
            low = cp
        }
    }
    return empty(err) ? codepoint_set_text(codepoint_ranges(ranges, negate)) : ""
}

//! `pattern` with its code-point escapes `\uHHHH` and `\UHHHHHHHH` rewritten into the UTF-8 byte
//! sequences `daslib/regex` reads: an escape outside a set is its encoding, a set holding one is a
//! set of code points. A pattern without them comes back as it is.
def flex_codepoints(pattern : string) : CodepointText {
    var res = CodepointText(text = pattern)
    return res if (find(pattern, "\\u") < 0 && find(pattern, "\\U") < 0)
    peek_data(pattern) $(d) {
        var i = 0
        var from = 0
        res.text = build_string() $(var w) {
            while (i < length(d) && empty(res.err)) {
                var next = i + 1
                var part = ""
                if (is_codepoint_escape(d, i)) {
                    let cp = escape_codepoint(d, i)
                    res.err = cp < 0 ? "the escape at offset {i} names no code point" : ""
                    part = cp < 0 ? "" : codepoint_set_text([int2(cp, cp)])
                    next = i + (int(d[i + 1]) == 'u' ? 6 : 10)
                } elif (int(d[i]) == '\\') {
                    i += 2
                    continue
                } elif (int(d[i]) == '[') {
                    let close = set_end(d, i)
                    next = close.x < 0 ? length(d) : close.x + 1
                    if (close.y == 0) {
                        i = next
                        continue
                    }
                    part = codepoint_set(d, i, close.x, res.err)
                } else {
                    i++
                    continue
                }
                w |> write(slice(d, from, i))
                w |> write(part)
                from = next
                i = next
            }
            w |> write(slice(d, from, length(d)))
        }
    }
    return res
}

//! One lexer rule: its regex text and the start conditions it is active in (empty = the default condition only).
struct FlexRule {
    pattern : string
    conditions : array<int>
}

//! Build the NFA of a rule set: rule `i` accepts with tag `i`; `starts[c]` is the start state of condition `c`
//! (condition 0 is the default one; an `inclusive` condition lists the default rules too - the caller decides).
//! `err` names the first regex that failed to parse or to fit a DFA.
def build_nfa(rules : array<FlexRule>; ncond : int) : Nfa {
    var n = Nfa()
    n.starts |> resize(ncond)
    for (c in range(ncond)) {
        n.starts[c] = new_state(n)
    }
    for (i, r in count(), rules) {
        let cp = flex_codepoints(r.pattern)
        if (!empty(cp.err)) {
            n.err = "rule {i}: regex '{r.pattern}': {cp.err}"
            n.err_rule = i
            return <- n
        }
        var re : Regex
        if (!regex_compile(re, cp.text)) {
            n.err = "rule {i}: regex '{r.pattern}' does not parse"
            n.err_rule = i
            return <- n
        }
        let f = frag_of(n, re.root)
        if (!empty(n.err)) {
            n.err = "rule {i}: {n.err}"
            n.err_rule = i
            return <- n
        }
        n.accept[f.last] = i
        if (empty(r.conditions)) {
            add_eps(n, n.starts[0], f.first)
        } else {
            for (c in r.conditions) {
                add_eps(n, n.starts[c], f.first)
            }
        }
    }
    return <- n
}
