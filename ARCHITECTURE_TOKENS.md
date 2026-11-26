# dasFlex architecture - tokens

This companion of `ARCHITECTURE.md` follows `ARCHITECTURE_COMMON.md`. It holds what the scanner
hands a preprocessor beyond the token's span: two flags on every token. The symbol a rule interns
for a name is the companion `ARCHITECTURE_SYMBOLS.md`.

## Token flags for a preprocessor {#pp-flags}

Every token carries two flags a C preprocessor reads, named as chibicc's tokenizer names them:
`has_space`, true when a rule that did not emit - whitespace, a comment, any skipped text - ran
since the previous token, and `at_bol`, true for the first token of the input and for a token that a
newline separates from the previous one. The newline counts when skipped text holds it or when the
previous token ends with it; a newline inside the previous token followed by more of its bytes does
not, since the next token then shares that token's last line.

The scanner loop keeps them as two pending flags on the lexer, `space_pending` and `bol_pending`,
which `flex_open` starts at false and true. After a match is taken they are copied into the token,
before the rule body runs, so a body may read them (a `#` rule deciding on a directive). A body that
emits resets `space_pending` and sets `bol_pending` to whether the token ended a line; a body that
does not sets `space_pending` and adds to `bol_pending` whether the skipped span moved the line.
Both tests read the line and column the token take already wrote, so the flags cost a few field
writes per token, nothing per byte, and every scanner shape - each `mode`, `matcher` and `dispatch`
- shares the code and gives the same flags.

The definitions are the lexer's, not the C standard's or chibicc's: a newline inside a block comment
sets `at_bol`, where translation phase 3 replaces the comment with one space and chibicc leaves the
flag unset, and `has_space` stays set across a newline, which chibicc clears.
