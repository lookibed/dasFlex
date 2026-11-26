# dasFlex performance ledger

## Where the speed stands

Driver `examples/c_lexer/c_lex_compare.das` for the daslang rows; inputs doom_am_map.i (81 647 bytes,
17 207 raw tokens), doom_p_mobj.i (74 386, 13 474), wasm3_m3_parse.i (83 685, 16 484), the same token
counts on every driver. One run, alone on a quiet machine (cpu busy 2%);
daslang 0.6.6, the library at 0aa7ad4. Each cell is ms per pass: the median of 3 rounds, each round
the median of 9 passes in one process, one process per driver and file, the driver order reversed
every other round; the round range stays within 4% of the cell except hand-written JIT (up to 31%)
and dasFlex token-array JIT (5%).

| driver | what the timed loop does | doom_am_map.i | doom_p_mobj.i | wasm3_m3_parse.i |
|---|---|---|---|---|
| dasFlex, count only, interp | `--mode flex --count`: the scanner counts tokens; the identifier rule builds the word's string and looks it up as keyword and typedef name | 9.261 | 8.133 | 9.640 |
| dasFlex, count only, JIT | same, `-jit` | 0.714 | 0.642 | 0.736 |
| dasFlex, token array, interp | `--mode flex`: the above plus one indirect block call per token (`invoke(scan, lx)`; `--count` calls `c_next` directly), `text()` per token and a `{kind, text, line}` array; opens the lexer (typedef table copied) inside the timer | 10.934 | 9.259 | 11.055 |
| dasFlex, token array, JIT | same, `-jit` | 1.086 | 0.937 | 1.092 |
| hand-written lexer, interp | `--mode probe`: a byte loop, keyword and typedef lookup by hash, a string slice per token, the same array; a one-byte punctuator allocates three slices (3-char, 2-char, emitted) and does two hash lookups | 6.514 | 5.524 | 6.377 |
| hand-written lexer, JIT | same, `-jit` | 1.041 | 0.811 | 1.305 |
| hand-written lexer, C `-O2` | a C port of `--mode probe`: the same token stream, not the same work - byte compares for punctuators, one `malloc` per token text, the array freed inside the timer | 1.542 | 1.046 | 0.794 |
| chibicc `tok`, C `-O2` | chibicc's `tokenize()`, punctuators and prefixes picked by the first byte (local edits) | 2.237 | 1.814 | 2.174 |
| chibicc `fast`, C `-O2` | the same plus an arena allocator, ASCII character classes and the identifier hash taken while lexing | 1.953 | 1.600 | 1.927 |

- chibicc `tok` does work no dasFlex row does: a `calloc` per token, every string literal decoded
  into a fresh `calloc` buffer plus a `calloc`'d array type (`array_of` / `new_type`), and line numbers in a second pass over the token list
  (`add_line_numbers`); it does not tell keywords from identifiers and has no typedef lookup. Both
  chibicc rows are a C driver timing `tokenize()` alone over a file read outside the timer.
- chibicc `fast` puts the token and the string buffer on a bump pointer into 1 MB arena blocks and
  tests character classes by ASCII compares instead of `<ctype.h>` calls; each string literal still
  pays the `array_of` / `new_type` `calloc`, and the string decode and the line pass stay. It also
  takes each identifier's FNV hash inside the timer, while the hash's only consumer (`is_keyword`)
  runs outside it.
- Ratios the table supports: chibicc `fast` over dasFlex count-only JIT 2.74 / 2.49 / 2.62, over
  dasFlex token-array JIT 1.80 / 1.71 / 1.76; dasFlex interp over JIT 13.0 / 12.7 / 13.1 (count only).

## Steps

Every row is one step with its measured effect. Numbers come from one run per column set, alone on a
quiet machine; a row without numbers has not been measured yet. Interp and JIT are
separate columns; a step that gave nothing stays in the table.

| step | hypothesis | interp before/after | jit before/after | verdict |
|---|---|---|---|---|
| 0 base | the driver is fair: both lexers build one string per token into a `Tok` array (profile: 17 207 strings each per pass) | - | - | base of steps 1-6 |
| 2 one-line actions | `emit` is a call per token and the identifier string is built twice (once for the keyword/typedef lookup, once by the driver for the token); the macro rewrites `emit` into its two field writes, `text()` caches the string on the token | 15.60 -> 16.25 ms (+4%); BASE flex -> FINAL flex-call, both call matcher + if chain, the pair also carries the other FINAL changes to shared code | 1.550 -> 1.436 ms (-7%); same pair | token streams identical; JIT IR already inlined `emit`, so this is an interpreter step |
| 1 rule dispatch | the `if (rule == i)` chain costs ~20 comparisons per token (profile: `c_next` own time 40%); a computed `goto` into a label per rule, or a binary tree, is cheaper | 16.25 -> 12.18 ms (-25%); FINAL flex-call (if) -> flex-dgoto (goto), both matcher = call; flex-dtree 12.16 | 1.436 -> 1.356 ms (-6%, dgoto round range 1.307-1.820); flex-dtree 1.354 | shapes `dispatch = "if" / "goto" / "tree"` added; token streams identical on all shapes |
| 3 inline matcher | `flex_match_table` is a call per token across LLVM units with 9 loads and 3 bounds checks per byte, and `flex_consume` re-reads the token; `matcher = "inline"` emits the byte loop into the scanner over one merged table (`next * 256 + accept + 1`) with raw pointers and counts newlines on the way (`\n` now a class of its own) | 12.18 -> 12.36 ms (+1%, within round range); FINAL flex-dgoto -> FINAL flex, both dispatch = goto | 1.356 -> 1.210 ms (-11%) | token streams identical on all shapes |
| 4 goto without second pass | goto mode calls `flex_consume`, a second walk over the token's bytes for line and column; the `\n` move counts the newline on the way and only accepting states some `\n` move reaches copy the count, so every other state pays nothing | 22.61 -> 22.78 ms (+1%); BASE goto -> FINAL goto, the pair also carries step 2 | 1.291 -> 1.082 ms (-16%) | token streams identical on all shapes |
| 5 keyword lookup without the hash | `c_word_kind` hashes the word into `KEYWORDS` and then into `lx.symbols`; keywords bucketed by (length, first byte) and compared with `text_is` skip the first hash for most identifiers | not kept, no number | not kept, no number | not kept: a directional check showed no clear gain (interpreter a little slower, JIT within noise) - the typedef lookup still hashes every identifier and the driver builds the string per token anyway |
| 6 defaults | `[flex]` with no arguments takes the inline matcher and goto dispatch; the old default (call + if) stays as `--mode flex-call`, `flex-inline` is now `flex` | 15.60 -> 12.36 ms (-21%); BASE flex -> FINAL flex | 1.550 -> 1.210 ms (-22%); same pair | token streams identical on all seven shapes; the new default is 21% faster interp and 22% faster jit than the old default on this file; against the hand-written lexer, the table above gives 1.68-1.73x interp and 0.84-1.16x JIT (token-array driver, three files) |
| 7 mode by tier | the interpreter is fastest on the table shape and the JIT on the goto shape (steps 1-6), and the macro sees the tier in `compiling_program().policies.jit_enabled`; the default `mode` now follows it, `mode = "table"\|"goto"` overrides | 14.89 -> 11.76 ms (-21%); BASE flex -> FINAL flex, which is the table shape here (FINAL table 11.67); hand-written 6.50, FINAL flex 1.81x of it | jit split 1.399 -> 1.143 ms (-18%), hand-written 1.032 (1.11x); jit `--jit-split-modules=0` 1.368 -> 1.125 (-18%), hand-written 1.060 (1.06x); exe 1.727 -> 1.655 (-4%), hand-written 1.634 (1.01x) | token streams identical in both tiers; the module cache keeps one record per tier (a `-jit` run after an interpreter run recompiles the module), checked on the tutorial. The default under JIT is goto mode with goto dispatch: 12% slower than `goto` with if dispatch (1.017) and 4% faster than the table (1.185); in the exe the table (1.502) beats both goto shapes (default 1.655, `goto` 1.600), so the exe default is not the fastest shape in this run |
| 8 dispatch by tier | under JIT the goto shape with the `if` chain beats goto mode with computed-goto dispatch (the step-7 JIT default) by 6-14% (default/`goto` 1.06-1.14x, jit-split and jit-mono, three files; measured with step 7), because LLVM already turns the chain into a `switch` and the computed goto adds a `switch` over label indices; table mode keeps computed-goto dispatch (step 1: -25% interp). The default `dispatch` now goes with the mode: `goto` for table, `if` for goto; an explicit `dispatch =` overrides | no change by design, table mode unchanged: 10.754 -> 10.743 ms (0%); V7 flex -> V8 flex | 1.177 -> 1.048 ms (-11%; V7 round range 0.980-1.181); doom_p_mobj -16%, wasm3_m3_parse -10% | kept: token streams identical on every version, shape and tier; the JIT default now runs with the `goto` shape (V8 flex 1.048, `goto` 1.079) |
| 9 DFA minimization | subset construction leaves states with identical futures (one per NFA path, e.g. per keyword/operator branch); Hopcroft minimization in flex_tables merges them, shrinking the table and the goto code without changing a token | 10.743 -> 10.711 ms (0%); V8 flex -> V9 flex (table mode); `table` 10.642 -> 10.981 (+3%), `goto` 21.090 -> 21.181 (0%) | 1.048 -> 1.008 ms (-4%, V9 round range 0.929-1.163, within noise); wasm3_m3_parse -4%, doom_p_mobj +15% (0.769 -> 0.882, all three rounds); `goto` 1.079 -> 1.013 (-6%) | C11 lexer 193 -> 115 states, merged table 14282 -> 8510 entries (74 classes); token streams identical on flex/table/goto/flex-call over the five C inputs |
| 10 groups by re-match | `group(n)` / `group_span(n)` re-run the rule's own anchored regex once per token, only in rules whose bodies call them; the automaton, the scanner loop and the token stream are untouched, so the token stream and the speed of rules without groups do not change | 10.471 -> 10.254 ms (-2%); A flex -> B flex (table mode); `goto` 20.874 -> 20.901 (0%), `reader` 10.421 -> 10.406 (0%); doom_p_mobj -2%, wasm3_m3_parse -1% | 1.024 -> 1.031 ms (+1%; A round range 0.882-1.033); `goto` 1.043 -> 1.039 (0%), `reader` 1.066 -> 1.054 (-1%); doom_p_mobj -1%, wasm3_m3_parse +4%; the unchanged hand-written control `probe` moved +10% / +9% / -1% between the same two binaries, the noise floor of this run | kept: rules without `group` pay nothing within noise, B/A 0.93-1.04 over flex/goto/reader, three files, both tiers; token streams of A and B identical on flex/goto/reader/probe over the three inputs |
| 11 identifiers as symbols | the identifier rule builds a string per identifier and hashes it twice (keywords, typedefs); a span-keyed interner (`flex/flex_symbols.das`) finds the name by its bytes, keywords and typedef names become kinds of symbols, and the token array keeps the symbol instead of the text | 11.692 -> 14.340 ms (+23%); 7f2285f -> f48271a, token array | 0.922 -> 0.750 ms (-19%); count only 0.693 -> 0.522 (-25%) | kept: no string per identifier in either tier; JIT faster on every driver and file, interpreter slower on every one - "Identifiers as symbols" |

Measured cells: doom_am_map.i, median of 3 rounds of in-process medians (`--time 9`), daslang 0.6.6, each
column set one run alone on a quiet machine (cpu busy 1-2%). Steps 1-6: BASE = ee7eec8, FINAL = 40f12d8. Step 7:
FINAL = 4c0c30a. Step 10: A = b18ebd2, B = 58f9d63 (A/B order flipped every round). Step 11: "Identifiers as symbols" below. The driver of these rows is the
token-array `--mode flex` of the table above; in steps 0-5 and for BASE the mode name `flex` meant the call matcher with the
`if` chain, the shape `flex-call` names since step 6.

## Unicode in the C lexer

What the Annex D identifier rules, `$`, the UCN escapes and the extended identifier rule cost
against the ASCII rules: before = `main` (f2a6bd0), after = the `unicode` branch, the same driver in
both. One run, alone on a quiet machine (cpu busy 1%), daslang 0.6.6; each cell is the median of 3
rounds, the two trees in alternating order, every round one process per tree, tier, driver and
file, each process the median of 9 passes (5 for the build). The build row is `flex_tables` over the
rules of `c_next` read from `c_lexer.das` (subset construction and minimization, no macro and no code
emission), called from a driver program; the `[flex]` annotation runs it once per scanner when the
module compiles. The scan rows are `c_lex_compare.das` as in the table above. Ms; the round range
stays within 3% of the cell except interp token-array wasm3_m3_parse after (22%, one round) and JIT
token-array wasm3_m3_parse before (17%, one round).

| measure | interp before | interp after | jit before | jit after |
|---|---|---|---|---|
| DFA: states x byte classes (merged-table entries) | 115 x 74 (8 510) | 177 x 143 (25 311) | same | same |
| table build of `c_next` (`flex_tables`) | 11.006 | 401.312 (36x) | 3.393 | 210.683 (62x) |
| count only, doom_am_map.i | 10.253 | 10.399 (+1%) | 0.662 | 0.679 (+3%) |
| count only, doom_p_mobj.i | 8.784 | 8.799 (0%) | 0.577 | 0.601 (+4%) |
| count only, wasm3_m3_parse.i | 10.520 | 10.651 (+1%) | 0.670 | 0.695 (+4%) |
| token array, doom_am_map.i | 12.011 | 12.317 (+3%) | 0.916 | 0.931 (+2%) |
| token array, doom_p_mobj.i | 10.001 | 10.211 (+2%) | 0.739 | 0.765 (+4%) |
| token array, wasm3_m3_parse.i | 12.146 | 12.440 (+2%) | 0.952 | 0.931 (-2%) |

The cost is the build, not the scan: the Annex D code-point sets cut the lead and continuation bytes
into 143 byte classes (74 for the ASCII rules) and add the states of their UTF-8 byte sequences, so
subset construction and minimization walk about three times the table, while an ASCII input still
takes one class lookup and one move per byte - the scan stays within 4% in both tiers. Every
`[flex]` scanner of these rules pays the build once at compile time, and `c_lex_compare.das`
compiles eight of them.

### The table build, made algorithmic

The 36x was not the table: one epsilon closure ran per (DFA state, class) move with a `table<int>`
for its marks and every state set was joined into a string key, over an NFA with one alternative per
UTF-8 byte sequence. Five changes, each its own commit, took the build back below the ASCII rules'
old cost:

- subset construction reads a state's moves on every class in one pass over its NFA edges and
  interns the kernel by a hash of its sorted states, so a kernel met again skips its closure - 722
  closures instead of 30 005 for the Unicode C rules (470 -> 47 ms interp, indicative);
- the UTF-8 sequences of a code-point set join a trie sharing their prefixes (NFA 2 201 -> 1 917
  states, -7%, indicative);
- Hopcroft's work list starts without the dead state's block, which has the largest preimage (21 674
  of the 25 311 moves of the minimal table go to -1; minimization -29%, indicative);
- a Hopcroft splitter reads its incoming moves grouped by target state and splits only on the classes
  among them, instead of walking every class for every state (minimization -21%, indicative);
- trie siblings with the same tail share one byte set, so the lead bytes of one shape lead into one
  NFA path: NFA 1 917 -> 1 313 states, DFA before minimization 722 -> 462, and F1/F2 one class, so
  the minimal table is 177 x 142 (34 -> 21 ms interp, indicative).

The tables of the pre-Unicode rules are byte-identical, the Unicode tables differ only by that one
merged class, and `c_lex_compare --dump` is identical in all ten modes, both tiers, over the five
inputs and the 43 case inputs. Before = 6e35a9c (the `unicode` head these changes start from), after
= 6d61381; one run alone on a quiet machine (cpu busy 2%), daslang 0.6.6, the same driver as above
(9 passes per process, 3 rounds, tree order alternating), JIT `-jit -jit-no-cache`. Ms; the round
range stays within 3% of the cell except JIT after for the pre-Unicode rules (13%).

| measure | interp before | interp after | jit before | jit after |
|---|---|---|---|---|
| DFA of `c_next`, states x byte classes | 177 x 143 | 177 x 142 | same | same |
| table build of `c_next`, Unicode rules | 407.147 | 19.854 (20.5x faster) | 213.083 | 3.646 (58x faster) |
| table build of `c_next`, pre-Unicode rules (`main`) | 11.045 | 4.686 (2.4x faster) | 3.336 | 0.672 (5.0x faster) |
| count only, doom_am_map.i | 10.293 | 10.138 (-2%) | 0.683 | 0.683 (0%) |
| count only, doom_p_mobj.i | 8.657 | 8.835 (+2%) | 0.602 | 0.607 (+1%) |
| count only, wasm3_m3_parse.i | 10.563 | 10.482 (-1%) | 0.701 | 0.691 (-1%) |

The Unicode build now costs 1.8x the pre-Unicode build of the old code (19.9 against 11.0 ms
interp), and the scan rows stay within 2%. The front-end module cache hides the build entirely on a
warm compile: it stores the post-macro module - the scanner's rewritten body and the table globals -
so a warm run of `c_lexer_demo.das` deserializes the lexer module and never calls `flex_tables`; a
compile without a cache pays it once per `[flex]` scanner.

## Identifiers as symbols

What finding identifiers by their bytes costs against the string per identifier: before = `main`
(7f2285f), after = `intern` (f48271a), the same driver in both. Before, the
identifier rule built the word's string (`text()`) and looked it up in `KEYWORDS` and in the
typedef table; after, it interns the span (`flex/flex_symbols.das`) and emits the symbol's kind -
keywords and typedef names are kinds of symbols - and the token arrays of `--mode flex` and
`--mode probe` keep an identifier as its symbol, with no string (the probe interns through the same
call). One run, alone on a quiet machine (cpu busy 2%), daslang 0.6.6; each cell is the median of 3
rounds, the two trees in alternating order, every round one process per tree, tier, driver and
file, each process the median of 9 passes; JIT is `-jit -jit-no-cache`. Ms; the round range stays
within 5% of the cell except hand-written interp doom_am_map before (10%, one round).

| measure | interp before | interp after | jit before | jit after |
|---|---|---|---|---|
| count only, doom_am_map.i | 10.151 | 12.509 (+23%) | 0.693 | 0.522 (-25%) |
| count only, doom_p_mobj.i | 8.689 | 10.903 (+25%) | 0.603 | 0.464 (-23%) |
| count only, wasm3_m3_parse.i | 10.674 | 12.098 (+13%) | 0.706 | 0.506 (-28%) |
| token array, doom_am_map.i | 11.692 | 14.340 (+23%) | 0.922 | 0.750 (-19%) |
| token array, doom_p_mobj.i | 9.872 | 12.430 (+26%) | 0.790 | 0.615 (-22%) |
| token array, wasm3_m3_parse.i | 12.123 | 13.986 (+15%) | 0.937 | 0.723 (-23%) |
| hand-written, doom_am_map.i | 8.287 | 10.334 (+25%) | 1.232 | 1.078 (-12%) |
| hand-written, doom_p_mobj.i | 6.829 | 8.838 (+29%) | 0.963 | 0.859 (-11%) |
| hand-written, wasm3_m3_parse.i | 8.084 | 9.734 (+20%) | 1.174 | 1.002 (-15%) |

Heap probe, one count-only scan (`--count` prints it as `HEAP`), both tiers: before, 7 009 / 6 478 /
7 498 string-heap allocations per pass on the three files - one per identifier - and no heap
allocation; after, no string-heap allocation, and 16 / 16 / 8 heap allocations under the
interpreter, 8 / 8 / 4 under the JIT - the interner's arrays growing to 2 669 / 2 734 / 1 273
distinct names, since every pass opens a fresh lexer. `tests/c_lexer_tests.das` holds the property:
twenty copies of a source allocate what one does, and no string.

The JIT gains 23-28% on the count-only scan, short of the 35-40% the study expected from a
lookup-only table of keywords and typedef names with a 4-byte hash. The difference is the interning
itself: about 40% of the identifiers of a preprocessed file are first occurrences (2 669 distinct
names in 7 009 on doom_am_map.i), so the table holds every name rather than a few hundred, a lookup
misses the cache more often, and each first occurrence appends an entry.

The interpreter loses 13-29%: the string and the two table lookups it replaces were three native
calls, the hash and the probe are daslang code whose every statement is a node - 145-190 ns per
hit interpreted against 8-11 under the JIT (indicative, a hit loop over the identifiers of one
file into a filled table). daslang binds no native hash of a byte span: `hash` takes a whole string
or value, a span has no terminating zero for `hash64z`, and `build_hash` goes through a block and a
writer. Two shapes were tried against this one, both indicative and neither kept:

- slots holding two key words and the length, so a probe reads the slot and no entry and a name of
  up to 16 bytes is compared as integers: 6-7% faster per hit interpreted, but the count-only scan
  4-7% slower in both tiers - the slots grow from 4 to 24 bytes, and the scan's misses and inserts
  pay for it;
- a native `table<uint64; int>` for names of up to 7 bytes, keyed by their exact packing with the
  length in the top byte, so a short name's hit is one native lookup: the count-only scan 1-2% slower
  interpreted and 2-4% slower under the JIT.

Folding the hash into the scanner's byte loop (the study's lesson 2) removes the hash from both
tiers and is the next step for the interpreter.

## What the JIT IR says (LLVM 22, `--jit-dump`)
- the rule dispatch is already a `switch` in both shapes, so the dispatch step is an interpreter step only;
- the matcher loop does 9 loads and 3 bounds checks per byte (`class_of`, `next`, `accept` each reload their
  header behind the check), `flex_consume` adds a load, a compare and a `col` store per byte;
- `flex_match_table`, `flex_consume` and `text` are calls on every token because the default JIT compiles each
  module as its own LLVM unit; code the macro emits into the scanner's own module inlines by construction;
- the reference `lex_probe` is not lean either: an indirect `is_alpha` call per identifier byte and a bounds check
  per byte, which is why dasFlex can pass it.

## Ideas parked
- tagged DFA for single-pass groups (the re-match of step 10 is the carried path), trailing context
- the symbol hash folded into the DFA walk over the identifier's bytes, so the interner probes with a hash the
  scanner already took - the interpreter's cost of identifiers as symbols ("Identifiers as symbols")
- a driver mode that keeps tokens as spans (no `text()` per token), so a timing sees the scanner rather than the
  string building that dominates both lexers' per-token cost
- `matcher` is ignored in goto mode; the annotation could reject `mode = "goto", matcher = ...` (not speed)
