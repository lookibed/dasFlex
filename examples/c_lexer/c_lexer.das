options gen2
options indenting = 4

module c_lexer shared public

// A C11 lexer on dasFlex: the rules of the classic c11.l (Degener/Lee) as [flex] rules. Token kinds
// above 127 are the grammar's named terminals in the yacc order; a single-character punctuator is
// its own byte, as in yacc. Keywords are one identifier rule plus a table lookup in the action, and
// `lx.symbols` is the typedef table the caller maintains: a name in it lexes as TYPEDEF_NAME.

require flex/flex_macro public
require strings

enum CTok {
    IDENTIFIER = 128
    I_CONSTANT = 129
    F_CONSTANT = 130
    STRING_LITERAL = 131
    FUNC_NAME = 132
    SIZEOF = 133
    PTR_OP = 134
    INC_OP = 135
    DEC_OP = 136
    LEFT_OP = 137
    RIGHT_OP = 138
    LE_OP = 139
    GE_OP = 140
    EQ_OP = 141
    NE_OP = 142
    AND_OP = 143
    OR_OP = 144
    MUL_ASSIGN = 145
    DIV_ASSIGN = 146
    MOD_ASSIGN = 147
    ADD_ASSIGN = 148
    SUB_ASSIGN = 149
    LEFT_ASSIGN = 150
    RIGHT_ASSIGN = 151
    AND_ASSIGN = 152
    XOR_ASSIGN = 153
    OR_ASSIGN = 154
    TYPEDEF_NAME = 155
    ENUMERATION_CONSTANT = 156
    TYPEDEF = 157
    EXTERN = 158
    STATIC = 159
    AUTO = 160
    REGISTER = 161
    INLINE = 162
    CONST = 163
    RESTRICT = 164
    VOLATILE = 165
    BOOL = 166
    CHAR = 167
    SHORT = 168
    INT = 169
    LONG = 170
    SIGNED = 171
    UNSIGNED = 172
    FLOAT = 173
    DOUBLE = 174
    VOID = 175
    COMPLEX = 176
    IMAGINARY = 177
    STRUCT = 178
    UNION = 179
    ENUM = 180
    ELLIPSIS = 181
    CASE = 182
    DEFAULT = 183
    IF = 184
    ELSE = 185
    SWITCH = 186
    WHILE = 187
    DO = 188
    FOR = 189
    GOTO = 190
    CONTINUE = 191
    BREAK = 192
    RETURN = 193
    ALIGNAS = 194
    ALIGNOF = 195
    ATOMIC = 196
    GENERIC = 197
    NORETURN = 198
    STATIC_ASSERT = 199
    THREAD_LOCAL = 200
}

let KEYWORDS <- {
    "_Alignas" => CTok.ALIGNAS,
    "_Alignof" => CTok.ALIGNOF,
    "_Atomic" => CTok.ATOMIC,
    "_Bool" => CTok.BOOL,
    "_Complex" => CTok.COMPLEX,
    "_Generic" => CTok.GENERIC,
    "_Imaginary" => CTok.IMAGINARY,
    "_Noreturn" => CTok.NORETURN,
    "_Static_assert" => CTok.STATIC_ASSERT,
    "_Thread_local" => CTok.THREAD_LOCAL,
    "__func__" => CTok.FUNC_NAME,
    "auto" => CTok.AUTO,
    "break" => CTok.BREAK,
    "case" => CTok.CASE,
    "char" => CTok.CHAR,
    "const" => CTok.CONST,
    "continue" => CTok.CONTINUE,
    "default" => CTok.DEFAULT,
    "do" => CTok.DO,
    "double" => CTok.DOUBLE,
    "else" => CTok.ELSE,
    "enum" => CTok.ENUM,
    "extern" => CTok.EXTERN,
    "float" => CTok.FLOAT,
    "for" => CTok.FOR,
    "goto" => CTok.GOTO,
    "if" => CTok.IF,
    "inline" => CTok.INLINE,
    "int" => CTok.INT,
    "long" => CTok.LONG,
    "register" => CTok.REGISTER,
    "restrict" => CTok.RESTRICT,
    "return" => CTok.RETURN,
    "short" => CTok.SHORT,
    "signed" => CTok.SIGNED,
    "sizeof" => CTok.SIZEOF,
    "static" => CTok.STATIC,
    "struct" => CTok.STRUCT,
    "switch" => CTok.SWITCH,
    "typedef" => CTok.TYPEDEF,
    "union" => CTok.UNION,
    "unsigned" => CTok.UNSIGNED,
    "void" => CTok.VOID,
    "volatile" => CTok.VOLATILE,
    "while" => CTok.WHILE
}

let private TOKEN_NAMES <- ["IDENTIFIER", "I_CONSTANT", "F_CONSTANT", "STRING_LITERAL", "FUNC_NAME",
                            "SIZEOF", "PTR_OP", "INC_OP", "DEC_OP", "LEFT_OP", "RIGHT_OP", "LE_OP",
    "GE_OP", "EQ_OP", "NE_OP", "AND_OP", "OR_OP", "MUL_ASSIGN", "DIV_ASSIGN", "MOD_ASSIGN",
    "ADD_ASSIGN", "SUB_ASSIGN", "LEFT_ASSIGN", "RIGHT_ASSIGN", "AND_ASSIGN", "XOR_ASSIGN",
    "OR_ASSIGN", "TYPEDEF_NAME", "ENUMERATION_CONSTANT", "TYPEDEF", "EXTERN", "STATIC", "AUTO",
    "REGISTER", "INLINE", "CONST", "RESTRICT", "VOLATILE", "BOOL", "CHAR", "SHORT", "INT", "LONG",
    "SIGNED", "UNSIGNED", "FLOAT", "DOUBLE", "VOID", "COMPLEX", "IMAGINARY", "STRUCT", "UNION",
    "ENUM", "ELLIPSIS", "CASE", "DEFAULT", "IF", "ELSE", "SWITCH", "WHILE", "DO", "FOR", "GOTO",
    "CONTINUE", "BREAK", "RETURN", "ALIGNAS", "ALIGNOF", "ATOMIC", "GENERIC", "NORETURN",
    "STATIC_ASSERT", "THREAD_LOCAL"]

//! the yacc name of a token kind; a single-character token prints as itself
def c_token_name(kind : int) : string =>
    kind >= 128 && kind - 128 < length(TOKEN_NAMES) ? TOKEN_NAMES[kind - 128] : to_char(kind)

//! identifier, keyword, or typedef name: the rule action's decision
def c_word_kind(lx : FlexLexer) : int {
    let word = text(lx)
    var kind = int(CTok.IDENTIFIER)
    KEYWORDS |> get(word) $(k) {
        kind = int(k)
    }
    if (kind == int(CTok.IDENTIFIER) && lx.symbols |> key_exists(word)) {
        kind = int(CTok.TYPEDEF_NAME)
    }
    return kind
}

//! a one-byte punctuator is its own kind
def c_byte_kind(lx : FlexLexer) : int => int(unsafe(lx.data[lx.tok.start]))

[flex]
def c_next(var lx : FlexLexer) : bool {  // nolint:STYLE038 - a rule list is one function by construction
    rule("[ \\t\\v\\f\\r\\n]+") {
    }
    rule("#[^\\n]*") {
    }
    rule("//[^\\n]*") {
    }
    rule("/\\*") {
        lx |> begin("COMMENT")
    }
    rule("[a-zA-Z_][a-zA-Z_0-9]*") {
        lx |> emit(c_word_kind(lx))
    }
    rule("0[xX][a-fA-F0-9]+(((u|U)(l|L|ll|LL)?)|((l|L|ll|LL)(u|U)?))?") {
        lx |> emit(CTok.I_CONSTANT)
    }
    rule("[1-9][0-9]*(((u|U)(l|L|ll|LL)?)|((l|L|ll|LL)(u|U)?))?") {
        lx |> emit(CTok.I_CONSTANT)
    }
    rule("0[0-7]*(((u|U)(l|L|ll|LL)?)|((l|L|ll|LL)(u|U)?))?") {
        lx |> emit(CTok.I_CONSTANT)
    }
    rule("(u|U|L)?'([^'\\\\\\n]|(\\\\([\\'\"?\\\\abfnrtv]|[0-7]+|x[a-fA-F0-9]+)))+'") {
        lx |> emit(CTok.I_CONSTANT)
    }
    rule("[0-9]+([Ee][+-]?[0-9]+)(f|F|l|L)?") {
        lx |> emit(CTok.F_CONSTANT)
    }
    rule("[0-9]*\\.[0-9]+([Ee][+-]?[0-9]+)?(f|F|l|L)?") {
        lx |> emit(CTok.F_CONSTANT)
    }
    rule("[0-9]+\\.([Ee][+-]?[0-9]+)?(f|F|l|L)?") {
        lx |> emit(CTok.F_CONSTANT)
    }
    rule("0[xX][a-fA-F0-9]+([Pp][+-]?[0-9]+)(f|F|l|L)?") {
        lx |> emit(CTok.F_CONSTANT)
    }
    rule("0[xX][a-fA-F0-9]*\\.[a-fA-F0-9]+([Pp][+-]?[0-9]+)(f|F|l|L)?") {
        lx |> emit(CTok.F_CONSTANT)
    }
    rule("0[xX][a-fA-F0-9]+\\.([Pp][+-]?[0-9]+)(f|F|l|L)?") {
        lx |> emit(CTok.F_CONSTANT)
    }
    rule("(u8|u|U|L)?\"([^\"\\\\\\n]|(\\\\([\\'\"?\\\\abfnrtv]|[0-7]+|x[a-fA-F0-9]+)))*\"") {
        lx |> emit(CTok.STRING_LITERAL)
    }
    rule("\\.\\.\\.") {
        lx |> emit(CTok.ELLIPSIS)
    }
    rule(">>=") {
        lx |> emit(CTok.RIGHT_ASSIGN)
    }
    rule("<<=") {
        lx |> emit(CTok.LEFT_ASSIGN)
    }
    rule("\\+=") {
        lx |> emit(CTok.ADD_ASSIGN)
    }
    rule("-=") {
        lx |> emit(CTok.SUB_ASSIGN)
    }
    rule("\\*=") {
        lx |> emit(CTok.MUL_ASSIGN)
    }
    rule("/=") {
        lx |> emit(CTok.DIV_ASSIGN)
    }
    rule("%=") {
        lx |> emit(CTok.MOD_ASSIGN)
    }
    rule("&=") {
        lx |> emit(CTok.AND_ASSIGN)
    }
    rule("\\^=") {
        lx |> emit(CTok.XOR_ASSIGN)
    }
    rule("\\|=") {
        lx |> emit(CTok.OR_ASSIGN)
    }
    rule(">>") {
        lx |> emit(CTok.RIGHT_OP)
    }
    rule("<<") {
        lx |> emit(CTok.LEFT_OP)
    }
    rule("\\+\\+") {
        lx |> emit(CTok.INC_OP)
    }
    rule("--") {
        lx |> emit(CTok.DEC_OP)
    }
    rule("->") {
        lx |> emit(CTok.PTR_OP)
    }
    rule("&&") {
        lx |> emit(CTok.AND_OP)
    }
    rule("\\|\\|") {
        lx |> emit(CTok.OR_OP)
    }
    rule("<=") {
        lx |> emit(CTok.LE_OP)
    }
    rule(">=") {
        lx |> emit(CTok.GE_OP)
    }
    rule("==") {
        lx |> emit(CTok.EQ_OP)
    }
    rule("!=") {
        lx |> emit(CTok.NE_OP)
    }
    rule(";|\\\{|\\\}|,|:|=|\\(|\\)|\\[|\\]|\\.|&|!|~|-|\\+|\\*|/|%|<|>|\\^|\\||\\?") {
        lx |> emit(c_byte_kind(lx))
    }
    condition("COMMENT", exclusive) {
        rule("\\*/") {
            lx |> begin("INITIAL")
        }
        rule("[^*]+") {
        }
        rule("\\*") {
        }
    }
}
