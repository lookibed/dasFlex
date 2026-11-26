options gen2
options indenting = 4
options strict_smart_pointers = true

module flex_symbols shared public

require strings
require math
require flex/flex_tier

//! one interned name: where its bytes are, its key and hash, and
//! the token kind it carries
struct FlexSymbol {
    key : uint64    //!< a name of up to 8 bytes packed; else its last 8
    hash : uint
    start : int     //!< the offset in the source; -1: `names` or `view` holds it
    len : int
    kind : int
    @do_not_delete view : uint8 const? //!< native shape: the name's copy in `arena`, a zero after it
    plain_len : int         //!< native shape: `len`, or -1 for a name holding a zero byte
    next_same : int         //!< native shape: the next name the same zero-ended prefix finds; -1
    built : bool            //!< native shape: `symbol_text` built the text
}

//! the shape of a `FlexSymbols`: the zero value takes the one of the
//! tier the program runs in, probing under the JIT, native in the
//! interpreter
enum FlexSymbolsShape {
    by_tier
    probing
    native
}

//! Names as small integers, found by their bytes, in one of two
//! shapes. Probing: an open-addressing table over
//! byte spans of one source at a time, so a hit allocates nothing and
//! a miss copies nothing. Native: a `table<string; int>` over copies
//! of the names, each ending in a zero, so a hit is one native lookup.
struct FlexSymbols {
    entries : array<FlexSymbol>
    names : array<string>   //!< texts `symbol_text` built; "" before
    slots : array<int>      //!< entry per slot, -1 empty; a power of two
    @do_not_delete src : uint8 const? //!< the source the spans are in
    in_source : int         //!< how many entries point into `src`
    fresh_kind : int        //!< the kind of a name met the first time
    shape : FlexSymbolsShape
    ids : table<string; int>            //!< native: a name's zero-ended prefix to its first symbol
    arena : array<array<uint8>>         //!< native: the names' bytes in blocks that never move
    @do_not_delete arena_at : uint8?    //!< native: the first free byte of the last block
    arena_left : int                    //!< native: the free bytes from `arena_at` on
    scratch : array<uint8>              //!< native: a span of a read-only source, a zero after it
}

//! An interner of the shape `shape`; a probing one's table starts with
//! `capacity` slots, rounded up to a power of two and at least 2, and
//! doubles when more than half full.
def flex_symbols(capacity : int = 64; shape : FlexSymbolsShape = FlexSymbolsShape.by_tier) : FlexSymbols {
    var syms = FlexSymbols(shape = shape)
    var cap = 2
    while (cap < capacity) {
        cap *= 2
    }
    if (symbols_native(syms)) {
        syms.ids |> reserve(cap)
    } else {
        place_all(syms, cap)
    }
    return <- syms
}

//! Whether `syms` takes the native shape.
[inline]
def symbols_native(syms : FlexSymbols) : bool {
    static_if (flex_jit_tier()) {
        return syms.shape == FlexSymbolsShape.native
    } else {
        return syms.shape != FlexSymbolsShape.probing
    }
}

//! the multiplier of the symbol hash: 2^64 over the golden ratio
let private SYMBOL_MULTIPLIER = 0x9E3779B97F4A7C15ul

//! the bytes of one arena block; a longer name takes a block of its own
let private ARENA_BLOCK = 16384

//! the symbol of the name `p[0..len)`, added when it is not there:
//! as the span at `start` of the source, or, when `start` is -1, as
//! `name`
[arch(at="../ARCHITECTURE_SYMBOLS.md#symbols")]
def private lookup_or_add(var syms : FlexSymbols; p : uint8 const?; len, start : int;
                          name : string) : int {
    if (empty(syms.slots)) {
        place_all(syms, 64)
    }
    var key = 0ul
    var mix = 0ul
    unsafe {
        if (len > 8) {
            var i = 0
            while (i + 8 < len) {
                mix = (mix ^ *reinterpret<uint64 const?>(p + i)) * SYMBOL_MULTIPLIER
                i += 8
            }
            key = *reinterpret<uint64 const?>(p + len - 8)
        } elif (len >= 4) {
            key = (uint64(*reinterpret<uint const?>(p))
                | (uint64(*reinterpret<uint const?>(p + len - 4)) << 32ul))
        } else {
            for (i in range(len)) {
                key = (key << 8ul) | uint64(p[i])
            }
        }
    }
    let h = uint(((mix ^ key ^ uint64(len)) * SYMBOL_MULTIPLIER) >> 32ul)
    let mask = length(syms.slots) - 1
    var slot = int(h) & mask
    while (true) {
        let e = syms.slots[slot]
        break if (e < 0)
        if (syms.entries[e].key == key && syms.entries[e].len == len) {
            return e if (len <= 8)
            let at = syms.entries[e].start
            unsafe {
                let q = at >= 0 ? syms.src + at : reinterpret<uint8 const?>(syms.names[e])
                return e if (memcmp(reinterpret<void?>(q), reinterpret<void?>(p), len) == 0)
            }
        }
        slot = (slot + 1) & mask
    }
    let id = length(syms.entries)
    syms.entries |> push(FlexSymbol(key = key, hash = h, start = start, len = len,
                                    kind = syms.fresh_kind, next_same = -1))
    syms.slots[slot] = id
    if (start >= 0) {
        syms.in_source++
    } else {
        syms.names |> resize(id + 1)
        syms.names[id] = name
    }
    if (id * 2 + 2 > length(syms.slots)) {
        place_all(syms, length(syms.slots) * 2)
    }
    return id
}

//! a table of `cap` slots, each entry placed again by its hash
def private place_all(var syms : FlexSymbols; cap : int) {
    syms.slots |> resize(cap)
    for (s in syms.slots) {
        s = -1
    }
    let mask = cap - 1
    for (e, ent in count(), syms.entries) {
        var i = int(ent.hash) & mask
        while (syms.slots[i] >= 0) {
            i = (i + 1) & mask
        }
        syms.slots[i] = e
    }
}

//! Native shape: the symbol of the `len` bytes at `p`, a zero after
//! them, when the table's lookup of the bytes up to the first zero gave
//! `first` and did not settle it - a miss (-1), or a name holding a
//! zero byte: the names sharing that prefix compared in full, the name
//! added when none is it, its bytes copied into the arena.
[arch(at="../ARCHITECTURE_SYMBOLS.md#symbols")]
def intern_unsettled(var syms : FlexSymbols; p : uint8 const?; len, first : int) : int {
    if (first >= 0) {
        var e = first
        while (e >= 0) {
            if (syms.entries[e].len == len) {
                unsafe {
                    return e if (memcmp(reinterpret<void?>(syms.entries[e].view), reinterpret<void?>(p), len) == 0)
                }
            }
            e = syms.entries[e].next_same
        }
    }
    if (len >= syms.arena_left) {
        var chunk : array<uint8>
        chunk |> resize(max(ARENA_BLOCK, len + 1))
        syms.arena_left = length(chunk)
        syms.arena_at = unsafe(addr(chunk[0]))
        syms.arena |> emplace(chunk)
    }
    let id = length(syms.entries)
    unsafe {
        var view = syms.arena_at
        memcpy(reinterpret<void?>(view), reinterpret<void?>(p), len)
        view[len] = 0u8
        syms.arena_at += len + 1
        syms.arena_left -= len + 1
        let prefix = reinterpret<string>(view)
        let plain = length(prefix) == len ? len : -1
        syms.entries |> push(FlexSymbol(start = -1, len = len, kind = syms.fresh_kind, view = view,
                                        plain_len = plain, next_same = -1))
        if (first < 0) {
            syms.ids[prefix] = id
            return id
        }
    }
    syms.entries[id].next_same = syms.entries[first].next_same
    syms.entries[first].next_same = id
    return id
}

//! Native shape: the symbol of the `len` bytes at `p`, which a zero
//! byte follows; found by one native lookup of the bytes up to the
//! first zero, added when it is not there.
[arch(at="../ARCHITECTURE_SYMBOLS.md#symbols"), inline]
def intern_terminated(var syms : FlexSymbols; p : uint8 const?; len : int) : int {
    let first = syms.ids?[unsafe(reinterpret<string>(p))] ?? -1
    return first if (first >= 0 && syms.entries[first].plain_len == len)
    return intern_unsettled(syms, p, len, first)
}

//! The symbol of the bytes `src[start .. start+len)`: found, or added.
//! Probing, the symbol is a span of `src` - no string, no copy - valid
//! while `src` is, and another source panics until
//! `flex_symbols_detach`; native, the name is copied on a miss.
[arch(at="../ARCHITECTURE_SYMBOLS.md#symbols"), inline]
def intern(var syms : FlexSymbols; src : uint8 const?; start, len : int) : int {
    if (symbols_native(syms)) {
        if (length(syms.scratch) < len + 1) {
            syms.scratch |> resize(len + 1)
        }
        unsafe {
            var q = addr(syms.scratch[0])
            if (len > 0) {
                memcpy(reinterpret<void?>(q), reinterpret<void?>(src + start), len)
            }
            q[len] = 0u8
            return intern_terminated(syms, q, len)
        }
    }
    if (src != syms.src) {
        if (syms.in_source > 0) {
            panic("intern: the symbols hold spans of another source; flex_symbols_detach first")
        }
        syms.src = src
    }
    return lookup_or_add(syms, unsafe(src + start), len, start, "")
}

//! The symbol of `name`, added as a name the interner holds; `name`
//! is its text.
def intern_name(var syms : FlexSymbols; name : string) : int {
    let p = unsafe(reinterpret<uint8 const?>(name))
    return lookup_or_add(syms, p, length(name), -1, name) if (!symbols_native(syms))
    return intern(syms, p, 0, 0) if (p == null)
    let known = symbol_count(syms)
    let id = intern_terminated(syms, p, length(name))
    if (id == known) {
        syms.names |> resize(id + 1)
        syms.names[id] = name
        syms.entries[id].built = true
    }
    return id
}

//! The token kind symbol `id` carries.
[inline]
def symbol_kind(syms : FlexSymbols; id : int) : int => syms.entries[id].kind

def set_symbol_kind(var syms : FlexSymbols; id, kind : int) {
    syms.entries[id].kind = kind
}

def symbol_count(syms : FlexSymbols) : int => length(syms.entries)

//! The text of symbol `id`, built on the first call and kept; a
//! probing entry reads its bytes from that text from then on.
def symbol_text(var syms : FlexSymbols; id : int) : string {
    let ent = syms.entries[id]
    if (length(syms.names) <= id) {
        syms.names |> resize(id + 1)
    }
    let p = ent.start >= 0 ? unsafe(syms.src + ent.start) : ent.view
    if (ent.start >= 0 || (p != null && !ent.built)) {
        if (ent.len > 0) {
            unsafe {
                map_to_ro_array(reinterpret<void?>(p), ent.len) $(v : array<uint8>#) {
                    syms.names[id] = slice(v, 0, ent.len)
                }
            }
        }
        syms.entries[id].built = true
    }
    if (ent.start >= 0) {
        syms.entries[id].start = -1
        syms.in_source--
    }
    return syms.names[id]
}

//! Every span's text copied into the interner, so the source may go
//! and `intern` may read another one; ids and kinds stay. A native
//! interner holds no span.
[arch(at="../ARCHITECTURE_SYMBOLS.md#symbols")]
def flex_symbols_detach(var syms : FlexSymbols) {
    for (id in range(length(syms.entries))) {
        if (syms.entries[id].start >= 0) {
            symbol_text(syms, id)
        }
    }
    syms.src = null
}
