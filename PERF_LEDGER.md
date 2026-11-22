# dasFlex performance ledger (wave 2)

Every row is one step with its measured effect. Numbers come from one exclusive run per column set
(`heavy --exclusive`, quiet machine); a row without numbers has not been measured yet. Interp and JIT are
separate columns; a step that gave nothing stays in the table.

| step | hypothesis | interp before/after | jit before/after | verdict |
|---|---|---|---|---|
| 0 base | wave-1 driver is fair: both lexers build one string per token into a `Tok` array (profile: 17 207 strings each per pass) | - | - | base of wave 2 |
| 1 rule dispatch | the `if (rule == i)` chain costs ~20 comparisons per token (profile: `c_next` own time 40%); a computed `goto` into a label per rule, or a binary tree, is cheaper | pending | pending | shapes `dispatch = "if" / "goto" / "tree"` added; token streams identical on all shapes |

## Ideas parked for wave 3
- groups / tagged DFA, reader macro `%flex~`, trailing context (not speed)
