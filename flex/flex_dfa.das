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

//! the finest partition of the byte alphabet every edge is a union of; `\n` is a class of its own
def byte_classes(n : Nfa; var class_of : array<int>) : int {
    var cut : array<bool>
    cut |> resize(257)
    cut[0] = true
    cut[256] = true
    cut[10] = true
    cut[11] = true
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
            var inscope moved : array<int>
            var inscope seen : table<int>
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

// Minimization is Hopcroft's partition refinement over the DFA plus one virtual dead state (index
// `nstates`, every move to itself, standing for -1): the first partition groups states by their `accept`
// value with the dead state alone, so two states merge only when they accept the same rule and every
// byte class leads both into one block. The dead state's block never meets a live state, so -1 stays the
// only dead state; the blocks are renumbered in order of their lowest old state, and `start` follows.

//! the states moving to `to` on class `c` are `from[at[c * n + to]] .. from[at[c * n + to + 1] - 1]`
struct private Preimage {
    at : array<int>
    from : array<int>
}

//! a partition of `0..n-1`: block `b` is `elems[bstart[b]] .. elems[bend[b] - 1]`
struct private Partition {
    elems : array<int>
    pos : array<int>
    blk : array<int>
    bstart : array<int>
    bend : array<int>
    marked : array<int>
    in_work : array<bool>
    work : array<int>
}

def private move_of(t : FlexTables; s, c : int) : int {
    return s if (s == t.nstates)
    let nx = t.next[s * t.nclasses + c]
    return nx < 0 ? t.nstates : nx
}

def private preimage(t : FlexTables) : Preimage {
    let n = t.nstates + 1
    var p : Preimage
    p.at |> resize(t.nclasses * n + 1)
    for (s in range(n)) {
        for (c in range(t.nclasses)) {
            p.at[c * n + move_of(t, s, c) + 1]++
        }
    }
    for (i in range(1, length(p.at))) {
        p.at[i] += p.at[i - 1]
    }
    var fill := p.at
    p.from |> resize(n * t.nclasses)
    for (s in range(n)) {
        for (c in range(t.nclasses)) {
            let k = c * n + move_of(t, s, c)
            p.from[fill[k]] = s
            fill[k]++
        }
    }
    return <- p
}

//! one block per `accept` value, the dead state alone; every block starts on the work list
def private initial_partition(t : FlexTables) : Partition {
    let n = t.nstates + 1
    var p : Partition
    var block_of : table<int; int>
    p.blk |> resize(n)
    for (s in range(n)) {
        let key = s == t.nstates ? -2 : t.accept[s]
        var b = block_of?[key] ?? -1
        if (b < 0) {
            b = length(p.bstart)
            block_of[key] = b
            p.bstart |> push(0)
        }
        p.blk[s] = b
    }
    let nblocks = length(p.bstart)
    p.bend |> resize(nblocks)
    for (s in range(n)) {
        p.bend[p.blk[s]]++
    }
    var total = 0
    for (b in range(nblocks)) {
        p.bstart[b] = total
        total += p.bend[b]
        p.bend[b] = p.bstart[b]
    }
    p.elems |> resize(n)
    p.pos |> resize(n)
    for (s in range(n)) {
        let b = p.blk[s]
        p.elems[p.bend[b]] = s
        p.pos[s] = p.bend[b]
        p.bend[b]++
    }
    p.marked |> resize(nblocks)
    p.in_work |> resize(nblocks)
    p.work |> reserve(n)
    for (b in range(nblocks)) {
        p.work |> push(b)
        p.in_work[b] = true
    }
    return <- p
}

//! moves `s` into the marked prefix of its block
def private mark(var p : Partition; var touched : array<int>; s : int) {
    let b = p.blk[s]
    let m = p.bstart[b] + p.marked[b]
    let o = p.elems[m]
    let at = p.pos[s]
    p.elems[m] = s
    p.pos[s] = m
    p.elems[at] = o
    p.pos[o] = at
    if (p.marked[b] == 0) {
        touched |> push(b)
    }
    p.marked[b]++
}

//! splits every touched block into its marked prefix and the rest; the work list gets the new block
//! when the old one is on it, else the smaller half
def private split_touched(var p : Partition; var touched : array<int>) {
    for (b in touched) {
        let m = p.marked[b]
        p.marked[b] = 0
        continue if (m == p.bend[b] - p.bstart[b])
        let nb = length(p.bstart)
        p.bstart |> push(p.bstart[b])
        p.bend |> push(p.bstart[b] + m)
        p.marked |> push(0)
        p.in_work |> push(false)
        p.bstart[b] += m
        for (i in range(p.bstart[nb], p.bend[nb])) {
            p.blk[p.elems[i]] = nb
        }
        let pick = p.in_work[b] || m <= p.bend[b] - p.bstart[b] ? nb : b
        p.work |> push(pick)
        p.in_work[pick] = true
    }
    touched |> clear()
}

//! Hopcroft's refinement: the block of every state, the dead state (`nstates`) included
def private refine(t : FlexTables) : array<int> {
    let n = t.nstates + 1
    let pre <- preimage(t)
    var p <- initial_partition(t)
    var splitter, touched : array<int>
    splitter |> reserve(n)
    touched |> reserve(n)
    while (!empty(p.work)) {
        let a = p.work[length(p.work) - 1]
        p.work |> pop()
        p.in_work[a] = false
        splitter |> clear()
        for (i in range(p.bstart[a], p.bend[a])) {
            splitter |> push(p.elems[i])
        }
        for (c in range(t.nclasses)) {
            for (to in splitter) {
                for (i in range(pre.at[c * n + to], pre.at[c * n + to + 1])) {
                    mark(p, touched, pre.from[i])
                }
            }
            split_touched(p, touched)
        }
    }
    return <- p.blk
}

//! Merges equivalent states in place. `nclasses` and `class_of` stay as they are; `start` is renumbered.
def minimize(var t : FlexTables) {
    return if (!empty(t.err) || t.nstates == 0)
    let blk <- refine(t)
    var new_id : array<int>
    new_id |> resize(length(blk))
    for (b in range(length(blk))) {
        new_id[b] = -1
    }
    var rep : array<int>
    for (s in range(t.nstates)) {
        if (new_id[blk[s]] < 0) {
            new_id[blk[s]] = length(rep)
            rep |> push(s)
        }
    }
    var next : array<int>
    next |> reserve(length(rep) * t.nclasses)
    var accept : array<int>
    accept |> reserve(length(rep))
    for (s in rep) {
        accept |> push(t.accept[s])
        for (c in range(t.nclasses)) {
            let nx = t.next[s * t.nclasses + c]
            next |> push(nx < 0 ? -1 : new_id[blk[nx]])
        }
    }
    for (c in range(length(t.start))) {
        t.start[c] = new_id[blk[t.start[c]]]
    }
    t.next <- next
    t.accept <- accept
    t.nstates = length(rep)
}

//! Build minimized tables straight from rules.
def flex_tables(rules : array<FlexRule>; ncond : int = 1) : FlexTables {
    let n <- build_nfa(rules, ncond)
    var t <- build_tables(n)
    minimize(t)
    return <- t
}
