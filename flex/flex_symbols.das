options gen2
options indenting = 4
options strict_smart_pointers = true

module flex_symbols shared public

require strings

//! one interned name: where its bytes are, its key and hash, and
//! the token kind it carries
struct FlexSymbol {
    key : uint64    //!< a name of up to 8 bytes packed; else its last 8
    hash : uint
    start : int     //!< the offset in the source; -1: `names` holds it
    len : int
    kind : int
}

//! Names as small integers, found by their bytes: an open-addressing
//! table over byte spans of one source at a time, so a hit allocates
//! nothing and a miss copies nothing.
struct FlexSymbols {
    entries : array<FlexSymbol>
    names : array<string>   //!< texts `symbol_text` built; "" before
    slots : array<int>      //!< entry per slot, -1 empty; a power of two
    @do_not_delete src : uint8 const? //!< the source the spans are in
    in_source : int         //!< how many entries point into `src`
    fresh_kind : int        //!< the kind of a name met the first time
}

//! An interner whose table starts with `capacity` slots, rounded up
//! to a power of two and at least 2; it doubles when half full.
def flex_symbols(capacity : int = 64) : FlexSymbols {
    var syms : FlexSymbols
    var cap = 2
    while (cap < capacity) {
        cap *= 2
    }
    place_all(syms, cap)
    return <- syms
}

//! the multiplier of the symbol hash: 2^64 over the golden ratio
let private SYMBOL_MULTIPLIER = 0x9E3779B97F4A7C15ul

//! the symbol of the name `p[0..len)`, added when it is not there:
//! as the span at `start` of the source, or, when `start` is -1, as
//! `name`
[arch(at="../ARCHITECTURE.md#symbols")]
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
                                    kind = syms.fresh_kind))
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

//! The symbol of the bytes `src[start .. start+len)`: found, or added
//! as a span of `src` - no string, no copy. A span is valid while `src`
//! is; another source panics until `flex_symbols_detach`.
[arch(at="../ARCHITECTURE.md#symbols"), inline]
def intern(var syms : FlexSymbols; src : uint8 const?; start, len : int) : int {
    if (src != syms.src) {
        if (syms.in_source > 0) {
            panic("intern: the symbols hold spans of another source; flex_symbols_detach first")
        }
        syms.src = src
    }
    return lookup_or_add(syms, unsafe(src + start), len, start, "")
}

//! The symbol of `name`, added as a name the interner holds.
def intern_name(var syms : FlexSymbols; name : string) : int =>
    lookup_or_add(syms, unsafe(reinterpret<uint8 const?>(name)), length(name), -1, name)

//! The token kind symbol `id` carries.
[inline]
def symbol_kind(syms : FlexSymbols; id : int) : int => syms.entries[id].kind

def set_symbol_kind(var syms : FlexSymbols; id, kind : int) {
    syms.entries[id].kind = kind
}

def symbol_count(syms : FlexSymbols) : int => length(syms.entries)

//! The text of symbol `id`, built on the first call and kept.
def symbol_text(var syms : FlexSymbols; id : int) : string {
    let ent = syms.entries[id]
    if (length(syms.names) <= id) {
        syms.names |> resize(id + 1)
    }
    if (empty(syms.names[id]) && ent.len > 0) {
        var bytes : array<uint8>
        bytes |> resize(ent.len)
        unsafe {
            memcpy(addr(bytes[0]), reinterpret<void?>(syms.src + ent.start), ent.len)
        }
        syms.names[id] = string(bytes)
        delete bytes
    }
    return syms.names[id]
}

//! Every span's text copied into the interner, so the source may go
//! and `intern` may read another one; ids and kinds stay.
[arch(at="../ARCHITECTURE.md#symbols")]
def flex_symbols_detach(var syms : FlexSymbols) {
    for (id in range(length(syms.entries))) {
        if (syms.entries[id].start >= 0) {
            symbol_text(syms, id)
            syms.entries[id].start = -1
        }
    }
    syms.in_source = 0
    syms.src = null
}
