options gen2
options indenting = 4
options strict_smart_pointers = true

module flex_regex shared public

require daslib/regex
require daslib/strings_boost
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
        var re : Regex
        if (!regex_compile(re, r.pattern)) {
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
