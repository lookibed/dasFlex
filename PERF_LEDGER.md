# dasFlex performance ledger (wave 2)

Every row is one step with its measured effect. Numbers come from one exclusive run per column set
(`heavy --exclusive`, quiet machine); a row without numbers has not been measured yet. Interp and JIT are
separate columns; a step that gave nothing stays in the table.

| step | hypothesis | interp before/after | jit before/after | verdict |
|---|---|---|---|---|
| 0 base | wave-1 driver is fair: both lexers build one string per token into a `Tok` array (profile: 17 207 strings each per pass) | - | - | base of wave 2 |
| 2 one-line actions | `emit` is a call per token and the identifier string is built twice (once for the keyword/typedef lookup, once by the driver for the token); the macro rewrites `emit` into its two field writes, `text()` caches the string on the token | pending | pending | token streams identical; JIT IR already inlined `emit`, so this is an interpreter step |
| 1 rule dispatch | the `if (rule == i)` chain costs ~20 comparisons per token (profile: `c_next` own time 40%); a computed `goto` into a label per rule, or a binary tree, is cheaper | pending | pending | shapes `dispatch = "if" / "goto" / "tree"` added; token streams identical on all shapes |
| 3 inline matcher | `flex_match_table` is a call per token across LLVM units with 9 loads and 3 bounds checks per byte, and `flex_consume` re-reads the token; `matcher = "inline"` emits the byte loop into the scanner over one merged table (`next * 256 + accept + 1`) with raw pointers and counts newlines on the way (`\n` now a class of its own) | pending | pending | token streams identical on all shapes |
| 4 goto without second pass | goto mode calls `flex_consume`, a second walk over the token's bytes for line and column; the `\n` move counts the newline on the way and only accepting states some `\n` move reaches copy the count, so every other state pays nothing | pending | pending | token streams identical on all shapes |

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
