options gen2
options indenting = 4
options strict_smart_pointers = true

module flex_dfa shared public

require flex/flex_regex

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
    err_rule : int = -1     //!< the rule `err` names
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

//! `states` grown by every state an epsilon path reaches, then sorted; `seen[s] == stamp` marks a
//! state already in, so each call takes a fresh `stamp`
def private eps_closure(n : Nfa; var seen : array<int>; stamp : int; var states : array<int>) {
    for (s in states) {
        seen[s] = stamp
    }
    var i = 0
    while (i < length(states)) {
        for (t in n.eps[states[i]]) {
            if (seen[t] != stamp) {
                seen[t] = stamp
                states |> push(t)
            }
        }
        i++
    }
    sort(states)
}

//! interned sorted NFA state sets, numbered in the order they were added: `head[h]` is the newest
//! set whose hash is `h`, `chain[id]` the set added before it with the same hash
struct SetIndex {
    sets : array<array<int>>
    head : table<uint64; int>
    chain : array<int>
}

def private set_hash(st : array<int>) : uint64 {
    var h = 14695981039346656037ul
    for (s in st) {
        h = (h ^ uint64(s)) * 1099511628211ul
    }
    return h
}

def private same_set(a, b : array<int>) : bool {
    return false if (length(a) != length(b))
    for (x, y in a, b) {
        return false if (x != y)
    }
    return true
}

//! the number of `st` in `idx`, or -1
def find_set(idx : SetIndex; st : array<int>; h : uint64) : int {
    var at = idx.head?[h] ?? -1
    while (at >= 0 && !same_set(idx.sets[at], st)) {
        at = idx.chain[at]
    }
    return at
}

//! the number of the new set `st`, moved into `idx`
def add_set(var idx : SetIndex; var st : array<int>; h : uint64) : int {
    let at = length(idx.sets)
    idx.chain |> push(idx.head?[h] ?? -1)
    idx.head[h] = at
    idx.sets |> emplace(st)
    return at
}

//! subset construction's state sets: a DFA state is the epsilon closure of a kernel, the NFA states
//! one class moves to, so a kernel met again maps to its DFA state without a second closure
struct private Subsets {
    states : SetIndex
    kernels : SetIndex
    kernel_state : array<int>   //!< per kernel: its DFA state
    seen : array<int>
    stamp : int
}

//! the DFA state of `kernel`, added when its closure is new
def private intern_kernel(n : Nfa; var sb : Subsets; kernel : array<int>) : int {
    let kh = set_hash(kernel)
    let k = find_set(sb.kernels, kernel, kh)
    return sb.kernel_state[k] if (k >= 0)
    var inscope st := kernel
    sb.stamp++
    eps_closure(n, sb.seen, sb.stamp, st)
    let h = set_hash(st)
    var at = find_set(sb.states, st, h)
    if (at < 0) {
        at = add_set(sb.states, st, h)
    }
    var inscope kept := kernel
    add_set(sb.kernels, kept, kh)
    sb.kernel_state |> push(at)
    return at
}

//! the lowest and the highest byte of every byte class
struct ClassBounds {
    lo : array<int>
    hi : array<int>
}

//! a byte class is a run of consecutive bytes (`byte_classes` numbers them in byte order), so its
//! bounds are where `class_of` changes
def class_bounds(t : FlexTables) : ClassBounds {
    var cb : ClassBounds
    cb.lo |> resize(t.nclasses)
    cb.hi |> resize(t.nclasses)
    for (b, c in count(), t.class_of) {
        if (b == 0 || t.class_of[b - 1] != c) {
            cb.lo[c] = b
        }
        cb.hi[c] = b
    }
    return <- cb
}

//! Subset construction. The result's `err` and `err_rule` repeat the NFA's.
[arch(at="../ARCHITECTURE.md#one-automaton")]
def build_tables(n : Nfa) : FlexTables {
    var t = FlexTables(err = n.err, err_rule = n.err_rule)
    return <- t if (!empty(n.err))
    t.nclasses = byte_classes(n, t.class_of)
    var sb : Subsets
    sb.seen |> resize(length(n.accept))
    for (s in range(length(n.accept))) {
        sb.seen[s] = -1
    }
    t.start |> resize(length(n.starts))
    for (c, s0 in count(), n.starts) {
        var inscope kernel <- [s0]
        t.start[c] = intern_kernel(n, sb, kernel)
    }
    var moves : array<array<int>>
    moves |> resize(t.nclasses)
    var si = 0
    while (si < length(sb.states.sets)) {
        var acc = -1
        for (s in sb.states.sets[si]) {
            for (e in n.edges[s]) {
                for (cls in range(t.class_of[e.lo], t.class_of[e.hi] + 1)) {
                    moves[cls] |> push(e.to)  // nolint:PERF006 - the per-class lists keep their capacity from state to state
                }
            }
            if (n.accept[s] >= 0 && (acc < 0 || n.accept[s] < acc)) {
                acc = n.accept[s]
            }
        }
        t.accept |> push(acc)
        for (m in moves) {
            if (empty(m)) {
                t.next |> push(-1)
                continue
            }
            sort(m)
            var w = 1
            for (i in range(1, length(m))) {
                if (m[i] != m[w - 1]) {
                    m[w] = m[i]
                    w++
                }
            }
            m |> resize(w)
            t.next |> push(intern_kernel(n, sb, m))
            m |> clear()
        }
        si++
    }
    t.nstates = length(sb.states.sets)
    return <- t
}

//! the moves into state `to` are `at[to] .. at[to + 1] - 1`: move `i` leads from `from[i]` on class
//! `cls[i]`
struct private Preimage {
    at : array<int>
    cls : array<int>
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
    var target : array<int>
    target |> resize(n * t.nclasses)
    p.at |> resize(n + 1)
    for (s in range(n)) {
        for (c in range(t.nclasses)) {
            let to = move_of(t, s, c)
            target[s * t.nclasses + c] = to
            p.at[to + 1]++
        }
    }
    for (i in range(1, length(p.at))) {
        p.at[i] += p.at[i - 1]
    }
    var fill := p.at
    p.cls |> resize(n * t.nclasses)
    p.from |> resize(n * t.nclasses)
    for (s in range(n)) {
        for (c in range(t.nclasses)) {
            let to = target[s * t.nclasses + c]
            p.cls[fill[to]] = c
            p.from[fill[to]] = s
            fill[to]++
        }
    }
    return <- p
}

//! one block per `accept` value, the dead state alone; every block but the dead state's starts on
//! the work list
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
        continue if (b == p.blk[t.nstates])
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
[arch(at="../ARCHITECTURE.md#one-automaton")]
def private refine(t : FlexTables) : array<int> {
    let n = t.nstates + 1
    let pre <- preimage(t)
    var p <- initial_partition(t)
    var by_class : array<array<int>>
    by_class |> resize(t.nclasses)
    var classes, touched : array<int>
    classes |> reserve(t.nclasses)
    touched |> reserve(n)
    while (!empty(p.work)) {
        let a = p.work[length(p.work) - 1]
        p.work |> pop()
        p.in_work[a] = false
        for (i in range(p.bstart[a], p.bend[a])) {
            let to = p.elems[i]
            for (j in range(pre.at[to], pre.at[to + 1])) {
                let c = pre.cls[j]
                if (empty(by_class[c])) {
                    classes |> push(c)
                }
                by_class[c] |> push(pre.from[j])  // nolint:PERF006 - the per-class lists keep their capacity from splitter to splitter
            }
        }
        for (c in classes) {
            for (s in by_class[c]) {
                mark(p, touched, s)
            }
            split_touched(p, touched)
            by_class[c] |> clear()
        }
        classes |> clear()
    }
    return <- p.blk
}

//! Merges equivalent states in place. `nclasses` and `class_of` stay as they are; `start` is renumbered.
[arch(at="../ARCHITECTURE.md#one-automaton")]
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
