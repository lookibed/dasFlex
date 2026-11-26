options gen2
options indenting = 4

module c_lexer_reader shared public

// The C11 lexer of `c_lexer.das` written in the `%flex~` text form, rule for rule in the same
// order: the definitions are those of the classic c11.l, the keyword and typedef decision is the
// same `c_word_kind` hook.

require flex/flex_macro public
require c_lexer

%flex~ c_next_reader : CTok
%x COMMENT
O       [0-7]
D       [0-9]
NZ      [1-9]
L       [a-zA-Z_$\u00A8\u00AA\u00AD\u00AF\u00B2-\u00B5\u00B7-\u00BA\u00BC-\u00BE\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u00FF\u0100-\u02FF\u0370-\u167F\u1681-\u180D\u180F-\u1DBF\u1E00-\u1FFF\u200B-\u200D\u202A-\u202E\u203F-\u2040\u2054\u2060-\u206F\u2070-\u20CF\u2100-\u218F\u2460-\u24FF\u2776-\u2793\u2C00-\u2DFF\u2E80-\u2FFF\u3004-\u3007\u3021-\u302F\u3031-\u303F\u3040-\uD7FF\uF900-\uFD3D\uFD40-\uFDCF\uFDF0-\uFE1F\uFE30-\uFE44\uFE47-\uFFFD\U00010000-\U0001FFFD\U00020000-\U0002FFFD\U00030000-\U0003FFFD\U00040000-\U0004FFFD\U00050000-\U0005FFFD\U00060000-\U0006FFFD\U00070000-\U0007FFFD\U00080000-\U0008FFFD\U00090000-\U0009FFFD\U000A0000-\U000AFFFD\U000B0000-\U000BFFFD\U000C0000-\U000CFFFD\U000D0000-\U000DFFFD\U000E0000-\U000EFFFD]
A       [a-zA-Z_$0-9\u00A8\u00AA\u00AD\u00AF\u00B2-\u00B5\u00B7-\u00BA\u00BC-\u00BE\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u00FF\u0100-\u167F\u1681-\u180D\u180F-\u1FFF\u200B-\u200D\u202A-\u202E\u203F-\u2040\u2054\u2060-\u206F\u2070-\u218F\u2460-\u24FF\u2776-\u2793\u2C00-\u2DFF\u2E80-\u2FFF\u3004-\u3007\u3021-\u302F\u3031-\u303F\u3040-\uD7FF\uF900-\uFD3D\uFD40-\uFDCF\uFDF0-\uFE44\uFE47-\uFFFD\U00010000-\U0001FFFD\U00020000-\U0002FFFD\U00030000-\U0003FFFD\U00040000-\U0004FFFD\U00050000-\U0005FFFD\U00060000-\U0006FFFD\U00070000-\U0007FFFD\U00080000-\U0008FFFD\U00090000-\U0009FFFD\U000A0000-\U000AFFFD\U000B0000-\U000BFFFD\U000C0000-\U000CFFFD\U000D0000-\U000DFFFD\U000E0000-\U000EFFFD]
XL      [a-zA-Z_$\u0080-\U0010FFFF]
XA      [a-zA-Z_$0-9\u0080-\U0010FFFF]
H       [a-fA-F0-9]
HP      0[xX]
E       [Ee][+-]?{D}+
P       [Pp][+-]?{D}+
FS      (f|F|l|L)
IS      (((u|U)(l|L|ll|LL)?)|((l|L|ll|LL)(u|U)?))
CP      (u|U|L)
SP      (u8|u|U|L)
UCN     \\u{H}{4}|\\U{H}{8}
ES      \\([\'"?\\abfnrtv]|{O}+|x{H}+|u{H}{4}|U{H}{8})
WS      [ \t\v\f\r\n]
%rules
{WS}+
#[^\n]*
"//"[^\n]*
"/*"                            { begin(COMMENT) }
{L}{A}*                         { emit(c_word_kind(lx)) }
({XL}|{UCN})({XA}|{UCN})*       { return false if (!c_ident_cut(lx)); emit(c_word_kind(lx)) }
{HP}{H}+{IS}?                   { emit(I_CONSTANT) }
{NZ}{D}*{IS}?                   { emit(I_CONSTANT) }
0{O}*{IS}?                      { emit(I_CONSTANT) }
{CP}?'([^'\\\n]|{ES})+'         { emit(I_CONSTANT) }
{D}+{E}{FS}?                    { emit(F_CONSTANT) }
{D}*\.{D}+{E}?{FS}?             { emit(F_CONSTANT) }
{D}+\.{E}?{FS}?                 { emit(F_CONSTANT) }
{HP}{H}+{P}{FS}?                { emit(F_CONSTANT) }
{HP}{H}*\.{H}+{P}{FS}?          { emit(F_CONSTANT) }
{HP}{H}+\.{P}{FS}?              { emit(F_CONSTANT) }
{SP}?\"([^"\\\n]|{ES})*\"       { emit(STRING_LITERAL) }
"..."                           { emit(ELLIPSIS) }
">>="                           { emit(RIGHT_ASSIGN) }
"<<="                           { emit(LEFT_ASSIGN) }
"+="                            { emit(ADD_ASSIGN) }
"-="                            { emit(SUB_ASSIGN) }
"*="                            { emit(MUL_ASSIGN) }
"/="                            { emit(DIV_ASSIGN) }
"%="                            { emit(MOD_ASSIGN) }
"&="                            { emit(AND_ASSIGN) }
"^="                            { emit(XOR_ASSIGN) }
"|="                            { emit(OR_ASSIGN) }
">>"                            { emit(RIGHT_OP) }
"<<"                            { emit(LEFT_OP) }
"++"                            { emit(INC_OP) }
"--"                            { emit(DEC_OP) }
"->"                            { emit(PTR_OP) }
"&&"                            { emit(AND_OP) }
"||"                            { emit(OR_OP) }
"<="                            { emit(LE_OP) }
">="                            { emit(GE_OP) }
"=="                            { emit(EQ_OP) }
"!="                            { emit(NE_OP) }
[;{},:=()\[\].&!~\-+*/%<>^|?]   { emit(c_byte_kind(lx)) }
<COMMENT>"*/"                   { begin(INITIAL) }
<COMMENT>[^*]+
<COMMENT>\*
%%
