# dasFlex architecture: the symbol interner

This companion of `ARCHITECTURE.md` follows `ARCHITECTURE_COMMON.md`. It holds the mechanism of
`flex/flex_symbols.das` and of `intern(lx)` in `flex/flex.das`.

## Symbols by their bytes {#symbols}

`flex/flex_symbols.das` turns a name into a small integer without building its string. Every symbol
is an entry - the name's length, where its bytes are and the token kind it carries - and its id is
the entry's index. How an entry is found takes one of two shapes, `FlexSymbols.shape`; the zero
value, `by_tier`, takes the one of the tier the program is compiled for, read through
`flex_jit_tier()` (`flex/flex_tier.das`), the way the scanner's mode follows the tier
(`ARCHITECTURE.md#two-shapes`).

**Probing, the JIT's shape.** An open-addressing table - linear probing over a power-of-two number
of slots, doubled when more than half full - of entries that also hold a 64-bit key and a 32-bit
hash. A name of at most 8 bytes is its key: its bytes packed, which with the length tell it from
every other name, so a lookup compares integers and reads no byte of either name. A longer name's
key is its last 8 bytes, and `memcmp` confirms a match on key and length. The hash multiplies the
key - and, for a longer name, each 8-byte word before the last - by 2^64 over the golden ratio and
keeps the high half: a name of up to 8 bytes costs one multiplication and no loop. A hit allocates
nothing; a miss appends an entry that points into the source, copying no byte.

**Native, the interpreter's shape.** A `table<string; int>` from a name to its id, whose keys are
copies of the names, each followed by a zero byte, in an arena of 16 KB blocks that never move once
filled (a longer name takes a block of its own). `intern_terminated` looks up `len` bytes that a
zero byte follows: one native lookup hashes and compares them, so a hit is one call into the
runtime. `intern(lx)` gets that zero byte in place: it saves the byte after the token, writes a
zero there, looks the token up and writes the byte back, so the lexer's bytes are the input again
when it returns. `flex_open` keeps one zero byte past the input, so a token that ends the input has
a byte after it too; the raw `intern(syms, src, start, len)` reads a source it may not write and
copies the span into a scratch buffer instead. A native string ends at its first zero byte, so the
table finds a name by its bytes up to the first zero: an entry records whether it holds a zero
byte, a hit on an entry without one whose length is the token's is the name, and any other result
- a miss, or a name holding a zero byte - walks the entries sharing that prefix with `memcmp` and
adds the name to them when none is it. A miss copies the name into the arena once; the interner
then reads no source, so it binds none.

Each shape wins in its own tier. In the interpreter every statement is a simulation node, and the
probing hash and probe are about twenty of them per name - 220 ns per hit, against 100 ns for the
native lookup, about what the string and the two table lookups it replaces cost (indicative, a hit
loop over the identifiers of one file). A native miss costs about 170 ns more than a hit: the copy,
the entry and the insert, which hashes the name a second time. Under the JIT the probing code compiles to a few
instructions (12 ns per hit) while the native lookup stays a call into the runtime that hashes the
name byte by byte (27 ns), and a native miss pays the copy and a second hash to insert. Folding the
symbol hash into the scanner's byte loop, so the interner skips the hash, costs every byte of the
input a few nodes in the interpreter and lengthens the goto code under the JIT; it is slower in both
tiers (`PERF_LEDGER.md`, "Identifiers as symbols").

`symbol_text` builds a symbol's string on its first call and keeps it - a probing entry then points
into that string, not the source - so a parser pays one string per distinct name it asks for, and a
scan that only classifies names pays none; `intern_name` keeps the string it is given as the
name's text. The interner is not the `SetIndex` of the table builder: that one numbers sets the
builder owns as int arrays, needs a lookup that does not add, and runs at build time, while the
interner compares borrowed byte spans on the scanner's hot path; nor is it
`daslib/flat_hash_table`, whose keys compare by value `==`, so a span would have to become a string
- an allocation per lookup - to be its key.

A kind per symbol stands where a string-keyed table stood: the C example interns its keywords with
their kinds before the first token (`c_symbols`), `c_typedef` turns a name into a TYPEDEF_NAME, and
the identifier rule emits the kind of the token's symbol - one lookup for the keyword and the
typedef question together. The rule interns the keywords itself when the interner has no IDENTIFIER
kind for a new name yet, so a lexer opened by `flex_open` rather than `c_open` lexes the same kinds.

A probing span is only as good as its source. A probing interner reads one source at a time: the
first span binds its pointer, and a span of another source panics while any entry still points into
the first. The guard compares pointers, so a new source at the freed address of the old one passes
it: the raw `intern` contract is to detach before the source is freed, and `FlexLexer` keeps it by
detaching in `flex_open`. `flex_symbols_detach` copies the text of every span into the interner and
unbinds it; the ids and kinds stay, and a native interner has no span to copy. `flex_open` detaches
the lexer's interner before it replaces the bytes, so a lexer reopened on another input keeps its
symbols - a name of the first file is the same id in the second - for one string per distinct name
of the first. An interner per source would be the cheaper contract and would lose those ids between
the files a parser lexes in turn.

The arena and the native keys point into the interner's own blocks, so a `FlexSymbols` moves (`<-`)
safely - the blocks stay where they are - while a clone (`:=`) would copy the blocks and keep keys
into the original's.

`FlexLexer.syms` is a field of the lexer, not a global, so two lexers never share symbols by
accident. `intern(lx)` interns the current token's span and keeps the id in `tok.sym`, which every
scanner shape sets to -1 when it takes a token, so a token whose rule did not intern carries none.
