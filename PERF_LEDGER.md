# dasFlex performance ledger (wave 2)

Every row is one step with its measured effect. Numbers come from one exclusive run per column set
(`heavy --exclusive`, quiet machine); a row without numbers has not been measured yet. Interp and JIT are
separate columns; a step that gave nothing stays in the table.

| step | hypothesis | interp before/after | jit before/after | verdict |
|---|---|---|---|---|
| 0 base | wave-1 driver is fair: both lexers build one string per token into a `Tok` array (profile: 17 207 strings each per pass) | - | - | base of wave 2 |
| 2 one-line actions | `emit` is a call per token and the identifier string is built twice (once for the keyword/typedef lookup, once by the driver for the token); the macro rewrites `emit` into its two field writes, `text()` caches the string on the token | 15.60 -> 16.25 ms (+4%); BASE flex -> FINAL flex-call, both call matcher + if chain, the pair also carries the other FINAL changes to shared code | 1.550 -> 1.436 ms (-7%); same pair | token streams identical; JIT IR already inlined `emit`, so this is an interpreter step |
| 1 rule dispatch | the `if (rule == i)` chain costs ~20 comparisons per token (profile: `c_next` own time 40%); a computed `goto` into a label per rule, or a binary tree, is cheaper | 16.25 -> 12.18 ms (-25%); FINAL flex-call (if) -> flex-dgoto (goto), both matcher = call; flex-dtree 12.16 | 1.436 -> 1.356 ms (-6%, dgoto round range 1.307-1.820); flex-dtree 1.354 | shapes `dispatch = "if" / "goto" / "tree"` added; token streams identical on all shapes |
| 3 inline matcher | `flex_match_table` is a call per token across LLVM units with 9 loads and 3 bounds checks per byte, and `flex_consume` re-reads the token; `matcher = "inline"` emits the byte loop into the scanner over one merged table (`next * 256 + accept + 1`) with raw pointers and counts newlines on the way (`\n` now a class of its own) | 12.18 -> 12.36 ms (+1%, within round range); FINAL flex-dgoto -> FINAL flex, both dispatch = goto | 1.356 -> 1.210 ms (-11%) | token streams identical on all shapes |
| 4 goto without second pass | goto mode calls `flex_consume`, a second walk over the token's bytes for line and column; the `\n` move counts the newline on the way and only accepting states some `\n` move reaches copy the count, so every other state pays nothing | 22.61 -> 22.78 ms (+1%); BASE goto -> FINAL goto, the pair also carries step 2 | 1.291 -> 1.082 ms (-16%) | token streams identical on all shapes |
| 5 keyword lookup without the hash | `c_word_kind` hashes the word into `KEYWORDS` and then into `lx.symbols`; keywords bucketed by (length, first byte) and compared with `text_is` skip the first hash for most identifiers | not kept, no number | not kept, no number | not kept: a directional check showed no clear gain (interpreter a little slower, JIT within noise) - the typedef lookup still hashes every identifier and the driver builds the string per token anyway |
| 6 defaults | `[flex]` with no arguments takes the inline matcher and goto dispatch; the old default (call + if) stays as `--mode flex-call`, `flex-inline` is now `flex` | 15.60 -> 12.36 ms (-21%); BASE flex -> FINAL flex | 1.550 -> 1.210 ms (-22%); same pair | token streams identical on all seven shapes; the new default is 21% faster interp and 22% faster jit than the wave-1 default on this file; still 1.9x behind the hand-written lexer in the interpreter, within 0.93-1.28x of it under JIT (0.93 on doom_am_map, 1.28 on doom_p_mobj, 1.27 on wasm3_m3_parse) |

Measured cells: doom_am_map.i (81 647 bytes), median of 3 rounds of in-process medians (`--time 9`), daslang 0.6.6, BASE = ee7eec8,
FINAL = 40f12d8. Run `TIMING-dasflex-wave2`, 2026-11-22 21:28 MSK, `heavy --exclusive`, machine quiet (cpu busy 1%).

## What the JIT IR says (LLVM 22, `--jit-dump`; the dumps are kept locally)
- the rule dispatch is already a `switch` in both shapes, so the dispatch step is an interpreter step only;
- the matcher loop does 9 loads and 3 bounds checks per byte (`class_of`, `next`, `accept` each reload their
  header behind the check), `flex_consume` adds a load, a compare and a `col` store per byte;
- `flex_match_table`, `flex_consume` and `text` are calls on every token because the default JIT compiles each
  module as its own LLVM unit; code the macro emits into the scanner's own module inlines by construction;
- the reference `lex_probe` is not lean either: an indirect `is_alpha` call per identifier byte and a bounds check
  per byte, which is why dasFlex can pass it.

## Ideas parked for wave 3
- groups / tagged DFA, reader macro `%flex~`, trailing context (not speed)
- the typedef lookup hashes every identifier's string; a hash folded into the DFA walk over the identifier's bytes
  (or a span-keyed symbol table) would let both the keyword and the typedef lookup skip the string - the condition
  under which step 5's buckets would pay
- a driver mode that keeps tokens as spans (no `text()` per token), so a timing sees the scanner rather than the
  string building that dominates both lexers' per-token cost
- `matcher` is ignored in goto mode; the annotation could reject `mode = "goto", matcher = ...` (not speed)
