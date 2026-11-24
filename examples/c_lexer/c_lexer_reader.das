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
L       [a-zA-Z_]
A       [a-zA-Z_0-9]
H       [a-fA-F0-9]
HP      0[xX]
E       [Ee][+-]?{D}+
P       [Pp][+-]?{D}+
FS      (f|F|l|L)
IS      (((u|U)(l|L|ll|LL)?)|((l|L|ll|LL)(u|U)?))
CP      (u|U|L)
SP      (u8|u|U|L)
ES      \\([\'"?\\abfnrtv]|{O}+|x{H}+)
WS      [ \t\v\f\r\n]
%rules
{WS}+
#[^\n]*
"//"[^\n]*
"/*"                            { begin(COMMENT) }
{L}{A}*                         { emit(c_word_kind(lx)) }
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
