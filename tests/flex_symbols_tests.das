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

//! both shapes of the interner, each test that holds for both runs in each
let SHAPES = fixed_array(FlexSymbolsShape.probing, FlexSymbolsShape.native)

//! the symbol of `text[start .. start+len)`, the span read in place
def intern_at(var syms : FlexSymbols; text : string; start, len : int) : int =>
    intern(syms, unsafe(reinterpret<uint8 const?>(text)), start, len)

[test(description = "the same bytes are one symbol wherever they stand, a span or a name the interner holds; other bytes, a prefix included, are another, in both shapes")]
def test_hit_and_miss(t : T?) {
    for (shape in SHAPES) {
        let src = "alpha beta alpha alph"
        var syms <- FlexSymbols(shape = shape)
        let a = intern_at(syms, src, 0, 5)
        let b = intern_at(syms, src, 6, 4)
        t |> equal(intern_at(syms, src, 11, 5), a)
        let p = intern_at(syms, src, 17, 4)
        t |> equal([a, b, p], [0, 1, 2])
        t |> equal(symbol_count(syms), 3)
        t |> equal(intern_name(syms, "beta"), b)
        t |> equal(intern_name(syms, "alph"), p)
        t |> equal(symbol_count(syms), 3)
        var held_syms <- FlexSymbols(shape = shape)
        let held = intern_name(held_syms, "a_name_longer_than_8")
        t |> equal(intern_at(held_syms, "x a_name_longer_than_8", 2, 20), held)
        t |> equal(symbol_count(held_syms), 1)
    }
}

[test(description = "a hit allocates nothing, on the heap or the string heap, in both shapes")]
def test_hit_allocates_nothing(t : T?) {
    for (shape in SHAPES) {
        let src = "word word"
        var syms <- FlexSymbols(shape = shape)
        let id = intern_at(syms, src, 0, 4)
        let heap0 = heap_allocation_count()
        let strings0 = string_heap_allocation_count()
        t |> equal(intern_at(syms, src, 5, 4), id)
        t |> equal(heap_allocation_count() - heap0, 0ul)
        t |> equal(string_heap_allocation_count() - strings0, 0ul)
    }
}

[test(description = "a table of two slots takes many names: it doubles when more than half full, and every name keeps its symbol through each doubling")]
def test_collisions_and_growth(t : T?) {
    var syms <- flex_symbols(2, FlexSymbolsShape.probing)
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
        let syms <- flex_symbols(asked, FlexSymbolsShape.probing)
        t |> equal(length(syms.slots), slots, "{asked}")
    }
    let made <- flex_symbols(64, FlexSymbolsShape.probing)
    t |> equal(length(made.slots), 64)
    var lazy <- FlexSymbols(shape = FlexSymbolsShape.probing)
    intern_name(lazy, "x")
    t |> equal(length(lazy.slots), 64)
}

[test(description = "the table doubles on the name past half full, not on the one that fills half: 32 names keep 64 slots, the 33rd doubles them")]
def test_doubling_threshold(t : T?) {
    var syms <- flex_symbols(64, FlexSymbolsShape.probing)
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
    var syms <- flex_symbols(2, FlexSymbolsShape.probing)
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
    var syms <- flex_symbols(4, FlexSymbolsShape.probing)
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
    var syms <- flex_symbols(2, FlexSymbolsShape.probing)
    for (i, n in count(), names) {
        t |> equal(intern_name(syms, n), i, n)
    }
    t |> equal(length(syms.slots), 16)
    for (i, n in count(), names) {
        t |> equal(int(syms.entries[i].hash) & 15, 15, n)
        t |> equal(intern_name(syms, n), i, n)
    }
}

[test(description = "the empty name's text is the empty string, as a span and after flex_symbols_detach, in both shapes")]
def test_empty_name_text(t : T?) {
    for (shape in SHAPES) {
        let src = "x"
        var syms <- FlexSymbols(shape = shape)
        let id = intern_at(syms, src, 0, 0)
        t |> equal(symbol_text(syms, id), "")
        flex_symbols_detach(syms)
        t |> equal(symbol_text(syms, id), "")
        t |> equal(intern_name(syms, ""), id)
    }
}

[test(description = "two names of one length and one hash are two symbols: the bytes decide, not the hash - a short name by its packed bytes, a long one sharing its last 8 bytes by the comparison")]
def test_full_hash_collision(t : T?) {
    for (pair in [("xfglyq", "oeinac"), ("fxcclhge_suffix_", "jtmmxmwe_suffix_")]) {
        let src = "{pair._0} {pair._1} {pair._0} {pair._1}"
        let len = length(pair._0)
        var syms <- flex_symbols(4, FlexSymbolsShape.probing)
        let a = intern_at(syms, src, 0, len)
        let b = intern_at(syms, src, len + 1, len)
        t |> equal(syms.entries[a].hash, syms.entries[b].hash, pair._0)
        t |> success(a != b, pair._0)
        t |> equal(intern_at(syms, src, 2 * len + 2, len), a)
        t |> equal(intern_at(syms, src, 3 * len + 3, len), b)
        t |> equal(intern_name(syms, pair._1), b)
    }
}

[test(description = "the empty name and names of 1 to 19 bytes - packed in the key up to 8, one to two words and the last 8 bytes past it - are told apart, and so are two names of one length that differ in the first or the last byte, in both shapes")]
def test_name_lengths(t : T?) {
    for (shape in SHAPES) {
        let src = "abcdefghijklmnopqrs"
        var syms <- FlexSymbols(shape = shape)
        var inscope ids <- [for (len in range(20)); intern_at(syms, src, 0, len)]
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
}

[test(description = "a new symbol takes fresh_kind; set_symbol_kind changes it for every later occurrence, in both shapes")]
def test_kinds(t : T?) {
    for (shape in SHAPES) {
        let src = "int x int"
        var syms <- FlexSymbols(shape = shape)
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
}

[test(description = "a span's text is built on the first symbol_text call and reused by the next; a name interned as a string is its text already, in both shapes")]
def test_lazy_text(t : T?) {
    for (shape in SHAPES) {
        let src = "lazy"
        var syms <- FlexSymbols(shape = shape)
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
}

[test(description = "spans of one source at a time: another source panics until flex_symbols_detach copies the names out; ids, kinds and text survive")]
def test_source_contract(t : T?) {
    let first = "one two identifier_9"
    let second = "two three identifier_9"
    var syms <- FlexSymbols(shape = FlexSymbolsShape.probing)
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

[test(description = "a span starting with a zero byte is built once, and its text - all its bytes - survives flex_symbols_detach, in both shapes")]
def test_zero_byte_span_text(t : T?) {
    for (shape in SHAPES) {
        var bytes <- array<uint8>(0u8, uint8('a'), uint8('b'))
        var syms <- FlexSymbols(shape = shape)
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
}

[test(description = "the shape of an interner follows the tier when nothing names it - native in the interpreter, probing under the JIT - and flex_symbols takes the one it is given")]
def test_shape_follows_tier(t : T?) {
    t |> equal(symbols_native(FlexSymbols()), !tier_is_jit())
    t |> equal(symbols_native(flex_symbols()), !tier_is_jit())
    t |> success(symbols_native(flex_symbols(8, FlexSymbolsShape.native)))
    t |> success(!symbols_native(flex_symbols(8, FlexSymbolsShape.probing)))
    let probing <- flex_symbols(8, FlexSymbolsShape.probing)
    t |> equal(length(probing.slots), 8)
    let native <- flex_symbols(8, FlexSymbolsShape.native)
    t |> equal(length(native.slots), 0)
}

[test(description = "flex_jit_tier() given an argument fails the compile at the call, with the macro's message")]
def test_jit_tier_takes_no_arguments(t : T?) {
    let issues = compile_issues("tier.das", "options gen2\nrequire flex/flex_tier\n\nlet x = flex_jit_tier(1)\n")
    t |> success(starts_with(issues, "error[50503]: flex_jit_tier() takes no arguments\ntier.das:4:8\n"), issues)
    t |> equal(compile_issues("tier_ok.das", "options gen2\nrequire flex/flex_tier\n\nlet x = flex_jit_tier()\n"), "")
}

[test(description = "a native interner tells apart names that hold a zero byte and agree up to it - and the name that ends there - by comparing all their bytes, and finds each again")]
def test_native_zero_byte_names(t : T?) {
    var bytes <- array<uint8>(uint8('a'), 0u8, uint8('b'), uint8('a'), 0u8, uint8('c'), uint8('a'), 0u8, uint8('b'))
    var syms <- FlexSymbols(shape = FlexSymbolsShape.native)
    let p = unsafe(addr<uint8 const?>(bytes[0]))
    let ab = intern(syms, p, 0, 3)
    let ac = intern(syms, p, 3, 3)
    let a = intern(syms, p, 0, 1)
    let empty_name = intern(syms, p, 1, 0)
    t |> equal([ab, ac, a, empty_name], [0, 1, 2, 3])
    t |> equal(intern(syms, p, 6, 3), ab)
    t |> equal(intern(syms, p, 3, 3), ac)
    t |> equal(intern_name(syms, "a"), a)
    t |> equal(intern_name(syms, ""), empty_name)
    t |> equal(symbol_count(syms), 4)
    let text = symbol_text(syms, ac)
    let q = unsafe(reinterpret<uint8 const?>(text))
    t |> equal([for (i in range(3)); unsafe(q[i])], [uint8('a'), 0u8, uint8('c')])
    delete bytes
}

[test(description = "a name interned before names that hold a zero byte after it keeps its id: the names sharing its bytes up to the zero join it, and it and each of them are found again, in both shapes")]
def test_zero_byte_names_after_prefix(t : T?) {
    var bytes <- array<uint8>(uint8('a'), 0u8, uint8('b'), uint8('a'), 0u8, uint8('c'))
    let p = unsafe(addr<uint8 const?>(bytes[0]))
    for (shape in SHAPES) {
        var syms <- flex_symbols(shape = shape)
        let a = intern(syms, p, 0, 1)
        let ab = intern(syms, p, 0, 3)
        let ac = intern(syms, p, 3, 3)
        t |> equal([a, ab, ac], [0, 1, 2])
        t |> equal([intern(syms, p, 3, 1), intern(syms, p, 0, 3), intern(syms, p, 3, 3), intern(syms, p, 0, 1)],
                   [a, ab, ac, a])
        t |> equal(symbol_count(syms), 3)
        t |> equal(symbol_text(syms, a), "a")
    }
    delete bytes
}

[test(description = "a native interner copies a name on its miss, so it reads one source after another with no flex_symbols_detach, and a name of the first source keeps its id and text after that source is gone")]
def test_native_any_source(t : T?) {
    var syms <- FlexSymbols(shape = FlexSymbolsShape.native)
    var first <- to_bytes("one two")
    let one = intern(syms, unsafe(addr<uint8 const?>(first[0])), 0, 3)
    let two = intern(syms, unsafe(addr<uint8 const?>(first[0])), 4, 3)
    for (b in first) {
        b = uint8('x')
    }
    delete first
    t |> equal(intern_at(syms, "two one three", 0, 3), two)
    t |> equal(intern_at(syms, "two one three", 4, 3), one)
    t |> equal(intern_at(syms, "two one three", 8, 5), 2)
    t |> equal(symbol_text(syms, one), "one")
    t |> equal(syms.src, null)
}

[test(description = "a native interner keeps its names in blocks that never move: a name longer than a block takes its own, and every earlier name is still found after many blocks")]
def test_native_arena_blocks(t : T?) {
    var syms <- FlexSymbols(shape = FlexSymbolsShape.native)
    let long_name = repeat("L", 20000)
    let names <- [for (i in range(3000)); "name_number_{i}"]
    let ids <- [for (n in names); intern_name(syms, n)]
    let long_id = intern_at(syms, " {long_name} ", 1, 20000)
    t |> success(length(syms.arena) > 2)
    for (n, id in names, ids) {
        t |> equal(intern_at(syms, " {n}", 1, length(n)), id, n)
    }
    t |> equal(intern_name(syms, long_name), long_id)
    t |> equal(symbol_text(syms, long_id), long_name)
}

[test(description = "a name that leaves one byte of an arena block makes the next name, of one byte and its zero, take a new block: the block never overflows, and the first name's bytes, view, id and text stay")]
def test_native_arena_exact_fit(t : T?) {
    var syms <- FlexSymbols(shape = FlexSymbolsShape.native)
    let long_name = repeat("F", 16382)
    let long_id = intern_name(syms, long_name)
    t |> equal(length(syms.arena), 1)
    t |> equal(syms.arena_left, 1)
    let view = syms.entries[long_id].view
    let short_id = intern_at(syms, " z ", 1, 1)
    t |> equal(length(syms.arena), 2)
    t |> success(syms.arena_left >= 0, "{syms.arena_left}")
    t |> equal(syms.entries[long_id].view, view)
    t |> equal(syms.arena[0][16381], uint8('F'))
    t |> equal(syms.arena[0][16382], 0u8)
    t |> equal(intern_name(syms, long_name), long_id)
    t |> equal(intern_at(syms, "z", 0, 1), short_id)
    t |> equal(symbol_text(syms, long_id), long_name)
    t |> equal(symbol_text(syms, short_id), "z")
}

[flex]
def interning_lexer(var lx : FlexLexer) : bool {
    rule("[a-z]+") {
        lx |> emit(intern(lx))
    }
    rule("[ \\n]+") {
    }
}

[test(description = "flex_open on another input detaches the symbols: the old names keep their ids and text, and meet them again in the new input, in both shapes")]
def test_reopen_keeps_symbols(t : T?) {
    for (shape in SHAPES) {
        var lx : FlexLexer
        lx.syms.shape = shape
        var inscope first <- lex_tokens(lx, "red green red", $(var l : FlexLexer) => interning_lexer(l)) $(var l : FlexLexer) {
            return l.tok.sym
        }
        t |> equal(first, [0, 1, 0])
        var inscope second <- lex_tokens(lx, "blue\ngreen red", $(var l : FlexLexer) => interning_lexer(l)) $(var l : FlexLexer) {
            return l.tok.kind
        }
        t |> equal(second, [2, 1, 0])
        t |> equal([for (id in range(3)); symbol_text(lx.syms, id)], ["red", "green", "blue"])
    }
}

[test(description = "tok.sym is -1 after flex_open, on a new lexer and after an input whose last token interned, in both shapes")]
def test_token_sym_after_open(t : T?) {
    for (shape in SHAPES) {
        var lx : FlexLexer
        lx.syms.shape = shape
        flex_open(lx, "red")
        t |> equal(lx.tok.sym, -1)
        t |> success(interning_lexer(lx))
        t |> equal(lx.tok.sym, 0)
        flex_open(lx, "blue")
        t |> equal(lx.tok.sym, -1)
    }
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

//! the names of `[a-z]+` interned, a run of other characters past
//! ASCII a token of its own with no symbol
[flex]
def utf8_interning_lexer(var lx : FlexLexer) : bool {
    rule("[a-z]+") {
        lx |> emit(intern(lx))
    }
    rule("[\\u0080-\\U0010FFFF]+") {
        lx |> emit(-1)
    }
    rule("[ \\n]+") {
    }
}

//! the tokens `utf8_interning_lexer` takes from `src` with an interner
//! of `shape` - a name as `id:text`, any other token as `-` - and
//! whether the lexer's bytes are `src`'s with one zero after them when
//! it is done
def scan_in_place(src : string; shape : FlexSymbolsShape) : tuple<toks : array<string>; bytes_kept : bool> {
    var lx : FlexLexer
    lx.syms.shape = shape
    var toks <- lex_tokens(lx, src, $(var l : FlexLexer) => utf8_interning_lexer(l)) $(var l : FlexLexer) {
        return l.tok.sym < 0 ? "-" : "{l.tok.sym}:{symbol_text(l.syms, l.tok.sym)}"
    }
    var kept = length(lx.bytes) == length(src) + 1 && lx.bytes[length(src)] == 0u8
    peek_data(src) $(d) {
        for (i in range(length(src))) {
            kept = kept && lx.bytes[i] == d[i]
        }
    }
    return (toks <- toks, bytes_kept = kept)
}

[test(description = "intern(lx) ends the token with a zero byte in place and puts back the byte it covered: a token at the very end of the input (where the spare byte after the input is), a token a multi-byte character follows, and a token before a newline leave the lexer's bytes as the input was, in both shapes")]
def test_in_place_terminator_restored(t : T?) {
    for (shape in SHAPES) {
        let res <- scan_in_place("ab\xC3\xA9cd ab\ncd", shape)
        t |> equal(res.toks, ["0:ab", "-", "1:cd", "0:ab", "1:cd"], "{shape}")
        t |> success(res.bytes_kept, "{shape}")
        let at_end <- scan_in_place("zz yy", shape)
        t |> equal(at_end.toks, ["0:zz", "1:yy"], "{shape}")
        t |> success(at_end.bytes_kept, "{shape}")
    }
}

[test(description = "flex_open keeps one zero byte past the input, an empty input included, so the in-place terminator never writes outside the lexer's bytes")]
def test_open_keeps_spare_byte(t : T?) {
    var lx : FlexLexer
    flex_open(lx, "")
    t |> equal(lx.len, 0)
    t |> equal(length(lx.bytes), 1)
    t |> success(lx.data != null)
    flex_open(lx, "abc")
    t |> equal(lx.len, 3)
    t |> equal(lx.bytes[3], 0u8)
}

[test(description = "a panic in the native insert of intern(lx) - the table locked - leaves the byte after the token as the input had it, in both tiers")]
def test_native_panic_restores_byte(t : T?) {
    var lx : FlexLexer
    lx.syms.shape = FlexSymbolsShape.native
    flex_open(lx, "ab cd")
    var panicked = false
    lock(lx.syms.ids) $(_ids) {
        try {
            interning_lexer(lx)
        } recover {
            panicked = true
        }
    }
    t |> success(panicked)
    t |> equal(lx.bytes[2], uint8(' '))
}

//! a name a run of bytes other than `;`, zero bytes included, its rule
//! emitting the kind of the token's symbol
[flex]
def zero_byte_lexer(var lx : FlexLexer) : bool {
    rule("[^;]+") {
        lx |> emit(symbol_kind(lx.syms, intern(lx)))
    }
    rule(";") {
    }
}

[test(description = "intern(lx) on names holding a zero byte - a\\0b, a\\0c, their prefix a, each again, a `;` after each - gives each its own stable id, kind and full text, and leaves the lexer's bytes as the input, in both shapes")]
def test_lexer_zero_byte_names(t : T?) {
    var inscope expected <- [[uint8('a'), 0u8, uint8('b')], [uint8('a'), 0u8, uint8('c')], [uint8('a')]]
    for (shape in SHAPES) {
        var lx : FlexLexer
        lx.syms.shape = shape
        lx.syms.fresh_kind = -1
        flex_open(lx, "a\x01b;a\x01c;a;a\x01b;a\x01c;a;")
        for (at in [1, 5, 11, 15]) {
            lx.bytes[at] = 0u8
        }
        var inscope input <- clone_to_move(lx.bytes)
        var inscope ids, kinds : array<int>
        ids |> reserve(6)
        kinds |> reserve(6)
        while (zero_byte_lexer(lx)) {
            t |> equal(lx.bytes, input, "{shape}")
            ids |> push(lx.tok.sym)
            kinds |> push(lx.tok.kind)
            if (lx.tok.kind < 0) {
                set_symbol_kind(lx.syms, lx.tok.sym, 10 + lx.tok.sym)
            }
        }
        t |> equal(lx.err, "", "{shape}")
        t |> equal(ids, [0, 1, 2, 0, 1, 2], "{shape}")
        t |> equal(kinds, [-1, -1, -1, 10, 11, 12], "{shape}")
        t |> equal(symbol_count(lx.syms), 3, "{shape}")
        continue if (symbol_count(lx.syms) != 3)
        for (id, want in count(), expected) {
            let text = symbol_text(lx.syms, id)
            let q = unsafe(reinterpret<uint8 const?>(text))
            t |> equal([for (i in range(length(want))); unsafe(q[i])], want, "{shape} {id}")
        }
    }
}
