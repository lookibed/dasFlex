options gen2
options indenting = 4
options strict_smart_pointers = true

module flex_dfa shared public

require flex/flex_regex
require daslib/strings_boost

// The NFA to tables: byte equivalence classes from every edge boundary, subset construction over
// epsilon closures, one DFA start state per start condition, and the rule an accepting state carries -
// the lowest rule id among the NFA accepting states it holds, so the rule written first wins a tie.

//! The scanner's tables. `next[state * nclasses + cls]` is the next state or -1; `accept[state]` the
//! rule id or -1; `class_of[byte]` the byte's class; `start[cond]` the start state of a condition.
struct FlexTables {
    nclasses : int
    nstates : int
    class_of : array<int>
    next : array<int>
    accept : array<int>
    start : array<int>
    err : string
}

//! the finest partition of the byte alphabet every edge is a union of
def byte_classes(n : Nfa; var class_of : array<int>) : int {
    var cut : array<bool>
    cut |> resize(257)
    cut[0] = true
    cut[256] = true
    for (es in n.edges) {
        for (e in es) {
            cut[e.lo] = true
            cut[e.hi + 1] = true
        }
    }
    class_of |> resize(256)
    var cls = -1
    for (b in range(256)) {
        if (cut[b]) {
            cls++
        }
        class_of[b] = cls
    }
    return cls + 1
}

def private eps_closure(n : Nfa; var states : array<int>) {
    var seen : table<int>
    for (s in states) {
        seen |> insert(s)
    }
    var i = 0
    while (i < length(states)) {
        for (t in n.eps[states[i]]) {
            if (!(seen |> key_exists(t))) {
                seen |> insert(t)
                states |> push(t)
            }
        }
        i++
    }
    sort(states)
}

def private set_key(states : array<int>) : string => join(states, ",")

//! Subset construction. The result's `err` repeats the NFA's.
def build_tables(n : Nfa) : FlexTables {
    var t : FlexTables
    t.err = n.err
    return <- t if (!empty(n.err))
    t.nclasses = byte_classes(n, t.class_of)
    // a representative byte per class, to walk edges by class
    var rep : array<int>
    rep |> resize(t.nclasses)
    for (b in range(256)) {
        rep[t.class_of[255 - b]] = 255 - b
    }
    var sets : array<array<int>>
    var index : table<string; int>
    t.start |> resize(length(n.starts))
    for (c, s0 in count(), n.starts) {
        var st : array<int>
        st |> push(s0)
        eps_closure(n, st)
        let key = set_key(st)
        if (!(index |> key_exists(key))) {
            index[key] = length(sets)
            sets |> emplace(st)
        }
        t.start[c] = index[key]
    }
    var si = 0
    while (si < length(sets)) {
        var acc = -1
        for (s in sets[si]) {
            if (n.accept[s] >= 0 && (acc < 0 || n.accept[s] < acc)) {
                acc = n.accept[s]
            }
        }
        t.accept |> push(acc)
        for (cls in range(t.nclasses)) {
            let b = rep[cls]
            var moved : array<int>
            var seen : table<int>
            for (s in sets[si]) {
                for (e in n.edges[s]) {
                    if (b >= e.lo && b <= e.hi && !(seen |> key_exists(e.to))) {
                        seen |> insert(e.to)
                        moved |> push(e.to)
                    }
                }
            }
            if (empty(moved)) {
                t.next |> push(-1)
                continue
            }
            eps_closure(n, moved)
            let key = set_key(moved)
            if (!(index |> key_exists(key))) {
                index[key] = length(sets)
                sets |> emplace(moved)
            }
            t.next |> push(index[key])
        }
        si++
    }
    t.nstates = length(sets)
    return <- t
}

//! Build tables straight from rules.
def flex_tables(rules : array<FlexRule>; ncond : int = 1) : FlexTables {
    let n <- build_nfa(rules, ncond)
    return <- build_tables(n)
}
