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

The scanner cannot tell a comment from other skipped text, so a newline inside a block comment
would set `at_bol`. Translation phase 3 replaces the comment with one space, and gcc and clang take
no directive after `x /*` newline `*/ #define`, so the C example's comment rules keep `bol_pending`
in `bol_saved` at `/*` and put it back at `*/` - a field of the lexer for rule bodies that the
scanner never touches - so the token after the comment is `at_bol` exactly when it would be with
the comment one space. `has_space` stays set across a newline, as gcc and clang have it; chibicc clears it, the
one place these flags differ from chibicc's.

## Preprocessing tokens {#pp-tokens}

`examples/c_lexer/c_lexer_pp.das` is the rule list of `c_next` rewritten by `gen_variants.das` into
the pp-token grammar of C11 6.4, so a preprocessor gets its tokens from the same rules the compiler
phase lexes with. The skipped `#` line becomes the `#` and `##` punctuators. The numeric constant
rules become one pp-number rule (6.4.8): after a digit, or a dot and a digit, it continues with
digits, dots, exponent signs after `e`, `E`, `p` and `P`, and the identifier-nondigits - ASCII
letters and `_`, UCNs, and the code points the identifier rule continues with, a set the generator
copies from that rule, so `1é` is one pp-number as clang lexes it, and `1$` is `1` then `$`.
An identifier is IDENTIFIER and keeps its symbol, never a keyword or a typedef name: the pp-token
grammar has only `identifier`, and the kinds belong to the phase after it, so the lexer reads no
kind its symbols carry. A last rule takes any other character as a PP_OTHER token of its own
(6.4p3): one code point, or one byte that starts none; a character Annex D refuses where the
extended identifier rule meets it is one too, so the lexer reaches the end of any input.

The input is past translation phase 2: a backslash-newline is not removed by a rule, since a rule
that skipped it would set `has_space`, and one that matched across it would need it in every
pattern. Neither lexer takes digraphs (`<:`, `%:`, `%:%:`): the classic c11.l rules have none.
