# dasFlex architecture - tokens

This companion of `ARCHITECTURE.md` follows `ARCHITECTURE_COMMON.md`. It holds what the scanner
hands a preprocessor beyond the token's span: two flags on every token of a lexer that asks for them. The symbol a rule interns
for a name is the companion `ARCHITECTURE_SYMBOLS.md`.

## Token flags for a preprocessor {#pp-flags}

A lexer that asks for them - `[flex(flags = true)]`, or `%option flags` in the reader - gives every
token two flags a C preprocessor reads, named as chibicc's tokenizer names them: `has_space`, true
when text was skipped since the previous token - whitespace, a comment, any match whose rule did not
emit - and `at_bol`, true for the first token of the input and for a token that a newline separates
from the previous one. The newline counts when skipped text holds it or when the previous token ends
with it; a newline inside the previous token followed by more of its bytes does not, since the next
token then shares that token's last line.

Both flags are derived from where the previous emitted token ended, two fields of the lexer that
`flex_open` sets to 0: `prev_end`, its end offset, and `prev_end_line`, the line of its last byte -
the cursor's line after it, or the line before when that byte is a newline. `has_space` is
`tok.start != prev_end` and `at_bol` is `tok.line != prev_end_line`; no input has a line 0, so the
first token is `at_bol` whatever text precedes it. The two are written at the head of every rule body
that is not empty, before its own statements, so a body reads them (a `#` rule deciding on a
directive); an empty body can neither read them nor emit, so a skipped span of whitespace pays
nothing. A rule that emits stores the two fields as it hands the token out. Nothing runs per byte,
and every scanner shape - each `mode`, `matcher` and `dispatch` - shares the code and gives the same
flags.

A lexer that does not ask generates the scanner it would without the flags, node for node: nothing
writes a flag or the two fields, so `has_space` and `at_bol` stay false from `flex_open` on and the
flags cost it nothing. The fields sit at the ends of `FlexToken` and `FlexLexer`, where they move no
field the scanner reads.

The scanner cannot tell a comment from other skipped text, so a newline inside a block comment would
set `at_bol`. Translation phase 3 replaces the comment with one space, and gcc and clang take no
directive after `x /*` newline `*/ #define`, so the pp lexer's comment rules move `prev_end_line` by
the lines the comment spans: `c_pp_comment_open` takes the line of `/*` off it and
`c_pp_comment_close` adds the line of `*/`. A comment opening on the previous token's last line
leaves `prev_end_line` at its closing line, so a token after it on that line is not `at_bol`; one
opening after a newline leaves `prev_end_line` below its closing line, so the token is - in both
cases what it would be with the comment one space. `has_space` stays set across a newline, as gcc
and clang have it; chibicc clears it, the one place these flags differ from chibicc's.

## Preprocessing tokens {#pp-tokens}

`examples/c_lexer/c_lexer_pp.das` is the rule list of `c_next` rewritten by `gen_variants.das` into
the pp-token grammar of C11 6.4, so a preprocessor gets its tokens from the same rules the compiler
phase lexes with. It is the one C lexer that asks for the token flags; `c_next` and its other shapes
do not. The skipped `#` line becomes the `#` and `##` punctuators. The numeric constant
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
