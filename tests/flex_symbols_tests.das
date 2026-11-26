options gen2
options indenting = 4

require dastest/testing_boost public
require strings
require daslib/strings_boost
require flex/flex_macro
require _flex_test_helpers

// The symbol interner of flex/flex_symbols.das: names found by their
// bytes, kinds per symbol, text on request, and the one-source
// contract.

//! the symbol of `text[start .. start+len)`, the span read in place
def intern_at(var syms : FlexSymbols; text : string; start, len : int) : int =>
    intern(syms, unsafe(reinterpret<uint8 const?>(text)), start, len)

[test(description = "the same bytes are one symbol wherever they stand, a span or a name the interner holds; other bytes, a prefix included, are another")]
def test_hit_and_miss(t : T?) {
    let src = "alpha beta alpha alph"
    var syms : FlexSymbols
    let a = intern_at(syms, src, 0, 5)
    let b = intern_at(syms, src, 6, 4)
    t |> equal(intern_at(syms, src, 11, 5), a)
    let p = intern_at(syms, src, 17, 4)
    t |> equal([a, b, p], [0, 1, 2])
    t |> equal(symbol_count(syms), 3)
    t |> equal(intern_name(syms, "beta"), b)
    t |> equal(intern_name(syms, "alph"), p)
    t |> equal(symbol_count(syms), 3)
    var held_syms : FlexSymbols
    let held = intern_name(held_syms, "a_name_longer_than_8")
    t |> equal(intern_at(held_syms, "x a_name_longer_than_8", 2, 20), held)
    t |> equal(symbol_count(held_syms), 1)
}

[test(description = "a hit allocates nothing, on the heap or the string heap")]
def test_hit_allocates_nothing(t : T?) {
    let src = "word word"
    var syms : FlexSymbols
    let id = intern_at(syms, src, 0, 4)
    let heap0 = heap_allocation_count()
    let strings0 = string_heap_allocation_count()
    t |> equal(intern_at(syms, src, 5, 4), id)
    t |> equal(heap_allocation_count() - heap0, 0ul)
    t |> equal(string_heap_allocation_count() - strings0, 0ul)
}

[test(description = "a table of two slots takes many names: it doubles when more than half full, and every name keeps its symbol through each doubling")]
def test_collisions_and_growth(t : T?) {
    var syms <- flex_symbols(2)
    t |> equal(length(syms.slots), 2)
    let words <- [for (i in range(40)); "w{i}"]
    let ids <- [for (w in words); intern_name(syms, w)]
    t |> equal(ids, [for (i in range(40)); i])
    t |> equal(length(syms.slots), 128)
    for (i, w in count(), words) {
        t |> equal(intern_name(syms, w), i)
        t |> equal(symbol_text(syms, i), w)
    }
}

[test(description = "flex_symbols rounds its capacity up to a power of two; the default table and the one a first intern makes have 64 slots")]
def test_capacity_defaults(t : T?) {
    for (asked, slots in [3, 5, 100], [4, 8, 128]) {
        let syms <- flex_symbols(asked)
        t |> equal(length(syms.slots), slots, "{asked}")
    }
    let made <- flex_symbols()
    t |> equal(length(made.slots), 64)
    var lazy : FlexSymbols
    intern_name(lazy, "x")
    t |> equal(length(lazy.slots), 64)
}

[test(description = "the table doubles on the name past half full, not on the one that fills half: 32 names keep 64 slots, the 33rd doubles them")]
def test_doubling_threshold(t : T?) {
    var syms <- flex_symbols()
    for (i in range(32)) {
        intern_name(syms, "n{i}")
    }
    t |> equal(length(syms.slots), 64)
    intern_name(syms, "n32")
    t |> equal(length(syms.slots), 128)
}

[test(description = "names of 4 to 8 bytes whose first and last 4 bytes agree share a packed key, and the length tells them apart")]
def test_packed_key_needs_length(t : T?) {
    let names <- [for (len in range(4, 9)); repeat("a", len)]
    var syms <- flex_symbols(2)
    let ids <- [for (n in names); intern_name(syms, n)]
    t |> equal(ids, [0, 1, 2, 3, 4])
    t |> equal(syms.entries[0].key, syms.entries[4].key)
    for (i, n in count(), names) {
        t |> equal(intern_name(syms, n), i, n)
    }
}

[test(description = "two names past 8 bytes with one hash, one length, one first byte and the same last 8 bytes are two symbols: the comparison reads every byte")]
def test_long_name_compares_every_byte(t : T?) {
    let a = "qjthsdrt_suffix_"
    let b = "qwuztlgl_suffix_"
    let src = "{a} {b}"
    var syms <- flex_symbols(4)
    let ia = intern_at(syms, src, 0, 16)
    let ib = intern_at(syms, src, 17, 16)
    t |> equal(syms.entries[ia].hash, syms.entries[ib].hash)
    t |> success(ia != ib)
    t |> equal(intern_name(syms, a), ia)
    t |> equal(intern_name(syms, b), ib)
}

[test(description = "names whose hashes all land in the last slot are placed again through each doubling, the probe wrapping to slot 0, and stay found")]
def test_rehash_wraps(t : T?) {
    let names <- ["w1", "w30", "w40", "w79", "w83", "w86"]
    var syms <- flex_symbols(2)
    for (i, n in count(), names) {
        t |> equal(intern_name(syms, n), i, n)
    }
    t |> equal(length(syms.slots), 16)
    for (i, n in count(), names) {
        t |> equal(int(syms.entries[i].hash) & 15, 15, n)
        t |> equal(intern_name(syms, n), i, n)
    }
}

[test(description = "the empty name's text is the empty string, as a span and after flex_symbols_detach")]
def test_empty_name_text(t : T?) {
    let src = "x"
    var syms : FlexSymbols
    let id = intern_at(syms, src, 0, 0)
    t |> equal(symbol_text(syms, id), "")
    flex_symbols_detach(syms)
    t |> equal(symbol_text(syms, id), "")
    t |> equal(intern_name(syms, ""), id)
}

[test(description = "two names of one length and one hash are two symbols: the bytes decide, not the hash - a short name by its packed bytes, a long one sharing its last 8 bytes by the comparison")]
def test_full_hash_collision(t : T?) {
    for (pair in [("xfglyq", "oeinac"), ("fxcclhge_suffix_", "jtmmxmwe_suffix_")]) {
        let src = "{pair._0} {pair._1} {pair._0} {pair._1}"
        let len = length(pair._0)
        var syms <- flex_symbols(4)
        let a = intern_at(syms, src, 0, len)
        let b = intern_at(syms, src, len + 1, len)
        t |> equal(syms.entries[a].hash, syms.entries[b].hash, pair._0)
        t |> success(a != b, pair._0)
        t |> equal(intern_at(syms, src, 2 * len + 2, len), a)
        t |> equal(intern_at(syms, src, 3 * len + 3, len), b)
        t |> equal(intern_name(syms, pair._1), b)
    }
}

[test(description = "the empty name and names of 1 to 19 bytes - packed in the key up to 8, one to two words and the last 8 bytes past it - are told apart, and so are two names of one length that differ in the first or the last byte")]
def test_name_lengths(t : T?) {
    let src = "abcdefghijklmnopqrs"
    var syms : FlexSymbols
    let ids <- [for (len in range(20)); intern_at(syms, src, 0, len)]
    t |> equal(ids, [for (i in range(20)); i])
    peek_data(src) $(d) {
        for (len in range(20)) {
            t |> equal(intern_name(syms, slice(d, 0, len)), len)
            t |> equal(intern_at(syms, src, 0, len), len)
        }
    }
    t |> equal(intern_name(syms, "!"), 20)
    var next = 21
    peek_data(src) $(d) {
        for (len in range(2, 20)) {
            let name = slice(d, 0, len)
            for (other in ["!{slice(name, 1)}", "{slice(name, 0, len - 1)}!"]) {
                t |> equal(intern_name(syms, other), next, other)
                next++
            }
        }
    }
}

[test(description = "a new symbol takes fresh_kind; set_symbol_kind changes it for every later occurrence")]
def test_kinds(t : T?) {
    let src = "int x int"
    var syms : FlexSymbols
    syms.fresh_kind = 7
    let kw = intern_name(syms, "int")
    set_symbol_kind(syms, kw, 3)
    t |> equal(intern_at(syms, src, 0, 3), kw)
    t |> equal(symbol_kind(syms, kw), 3)
    let x = intern_at(syms, src, 4, 1)
    t |> equal(symbol_kind(syms, x), 7)
    set_symbol_kind(syms, x, 9)
    t |> equal(symbol_kind(syms, intern_at(syms, src, 4, 1)), 9)
    t |> equal(symbol_kind(syms, intern_at(syms, src, 6, 3)), 3)
}

[test(description = "a span's text is built on the first symbol_text call and reused by the next; a name interned as a string is its text already")]
def test_lazy_text(t : T?) {
    let src = "lazy"
    var syms : FlexSymbols
    let id = intern_at(syms, src, 0, 4)
    t |> equal(length(syms.names), 0)
    let strings0 = string_heap_allocation_count()
    t |> equal(symbol_text(syms, id), "lazy")
    let strings1 = string_heap_allocation_count()
    t |> success(strings1 > strings0)
    t |> equal(symbol_text(syms, id), "lazy")
    t |> equal(string_heap_allocation_count(), strings1)
    let named = intern_name(syms, "held")
    t |> equal(symbol_text(syms, named), "held")
    t |> equal(string_heap_allocation_count(), strings1)
}

[test(description = "spans of one source at a time: another source panics until flex_symbols_detach copies the names out; ids, kinds and text survive")]
def test_source_contract(t : T?) {
    let first = "one two identifier_9"
    let second = "two three identifier_9"
    var syms : FlexSymbols
    let one = intern_at(syms, first, 0, 3)
    let two = intern_at(syms, first, 4, 3)
    let long_name = intern_at(syms, first, 8, 12)
    set_symbol_kind(syms, two, 5)
    let why = panic_text() $ {
        intern_at(syms, second, 0, 3)
    }
    t |> success(find(why, "flex_symbols_detach first") >= 0, why)
    flex_symbols_detach(syms)
    t |> equal(syms.in_source, 0)
    t |> equal(intern_at(syms, second, 0, 3), two)
    t |> equal(symbol_kind(syms, two), 5)
    t |> equal(intern_at(syms, second, 10, 12), long_name)
    let three = intern_at(syms, second, 4, 5)
    t |> equal(symbol_text(syms, one), "one")
    t |> equal(symbol_text(syms, two), "two")
    t |> equal(symbol_text(syms, three), "three")
}

[test(description = "a span starting with a zero byte is built once, and its text - all its bytes - survives flex_symbols_detach")]
def test_zero_byte_span_text(t : T?) {
    var bytes <- array<uint8>(0u8, uint8('a'), uint8('b'))
    var syms : FlexSymbols
    let id = intern(syms, unsafe(addr<uint8 const?>(bytes[0])), 0, 3)
    symbol_text(syms, id)
    let strings0 = string_heap_allocation_count()
    symbol_text(syms, id)
    t |> equal(string_heap_allocation_count(), strings0)
    flex_symbols_detach(syms)
    let text = symbol_text(syms, id)
    t |> equal(string_heap_allocation_count(), strings0)
    let p = unsafe(reinterpret<uint8 const?>(text))
    t |> success(p != null)
    t |> equal([for (i in range(3)); unsafe(p[i])], [0u8, uint8('a'), uint8('b')])
    delete bytes
}

[flex]
def interning_lexer(var lx : FlexLexer) : bool {
    rule("[a-z]+") {
        lx |> emit(intern(lx))
    }
    rule("[ \\n]+") {
    }
}

[test(description = "flex_open on another input detaches the symbols: the old names keep their ids and text, and meet them again in the new input")]
def test_reopen_keeps_symbols(t : T?) {
    var lx : FlexLexer
    let first <- lex_tokens(lx, "red green red", $(var l : FlexLexer) => interning_lexer(l)) $(var l : FlexLexer) {
        return l.tok.sym
    }
    t |> equal(first, [0, 1, 0])
    let second <- lex_tokens(lx, "blue\ngreen red", $(var l : FlexLexer) => interning_lexer(l)) $(var l : FlexLexer) {
        return l.tok.kind
    }
    t |> equal(second, [2, 1, 0])
    t |> equal([for (id in range(3)); symbol_text(lx.syms, id)], ["red", "green", "blue"])
}

[test(description = "tok.sym is -1 after flex_open, on a new lexer and after an input whose last token interned")]
def test_token_sym_after_open(t : T?) {
    var lx : FlexLexer
    flex_open(lx, "red")
    t |> equal(lx.tok.sym, -1)
    t |> success(interning_lexer(lx))
    t |> equal(lx.tok.sym, 0)
    flex_open(lx, "blue")
    t |> equal(lx.tok.sym, -1)
}

//! a rule that interns and rules that do not, the second reporting
//! the `tok.sym` it sees
let private SYM_RULES = ("    rule(\"[a-z]+\") \{ lx |> emit(100 + intern(lx)) \}\n"
    + "    rule(\"[0-9]+\") \{ lx |> emit(lx.tok.sym) \}\n"
    + "    rule(\" +\") \{ \}\n")

[test(description = "tok.sym is the token's symbol after intern and -1 for a token whose rule did not intern, in every scanner shape")]
def test_token_sym_reset(t : T?) {
    let shapes <- ["mode = \"table\", matcher = \"call\"", "mode = \"table\"", "mode = \"goto\""]
    let res <- shape_streams("syms.das", SYM_RULES, shapes, "ab 1 cd ab 22", tier_is_jit())
    t |> equal(res.issues, "")
    for (stream in res.streams) {
        t |> equal(stream, ["100@1:1:ab", "-1@1:4:1", "101@1:6:cd", "100@1:9:ab", "-1@1:12:22", ""])
    }
}
