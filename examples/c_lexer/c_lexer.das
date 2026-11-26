options gen2
options indenting = 4

module c_lexer shared public

// A C11 lexer on dasFlex: the rules of the classic c11.l (Degener/Lee) as [flex] rules. Token kinds
// above 127 are the grammar's named terminals in the yacc order; a single-character punctuator is
// its own byte, as in yacc. Keywords are one identifier rule plus a
// symbol lookup in the action: `c_open` interns the keywords with
// their kinds into `lx.syms`, `c_typedef` turns a name into a
// TYPEDEF_NAME, and every other name lexes as IDENTIFIER.

require flex/flex_macro public
require flex/flex_regex
require strings
require daslib/enum_trait
require daslib/utf8_utils

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

//! the yacc name of every named token kind
let private TOKEN_NAMES <- { for (k in each(type<CTok>)); int(k) => string(k) }

//! the yacc name of a token kind; a single-character token prints as itself
def c_token_name(kind : int) : string => TOKEN_NAMES?[kind] ?? to_char(kind)

//! identifier, keyword, or typedef name: the kind of `word`, `typedefs` holding the typedef names
def c_word_kind_of(word : string; typedefs : table<string; int>) : int {
    var kind = int(CTok.IDENTIFIER)
    KEYWORDS |> get(word) $(k) {
        kind = int(k)
    }
    if (kind == int(CTok.IDENTIFIER) && typedefs |> key_exists(word)) {
        kind = int(CTok.TYPEDEF_NAME)
    }
    return kind
}

//! the symbols every C source starts with: the keywords and their
//! kinds, IDENTIFIER for a new name and for a name interned before
//! them; nothing when the keywords are in already
def c_symbols(var syms : FlexSymbols) {
    return if (symbol_kind(syms, intern_name(syms, "int")) == int(CTok.INT))
    for (id in range(symbol_count(syms))) {
        if (symbol_kind(syms, id) == syms.fresh_kind) {
            set_symbol_kind(syms, id, int(CTok.IDENTIFIER))
        }
    }
    syms.fresh_kind = int(CTok.IDENTIFIER)
    for (word, kind in keys(KEYWORDS), values(KEYWORDS)) {
        set_symbol_kind(syms, intern_name(syms, word), int(kind))
    }
}

//! `name` lexes as TYPEDEF_NAME from now on, unless it is a keyword
def c_typedef(var syms : FlexSymbols; name : string) {
    c_symbols(syms)
    let id = intern_name(syms, name)
    if (symbol_kind(syms, id) == int(CTok.IDENTIFIER)) {
        set_symbol_kind(syms, id, int(CTok.TYPEDEF_NAME))
    }
}

//! the identifier rule's decision on the token: the kind of its
//! symbol, found by its bytes
[arch(at="../../ARCHITECTURE.md#symbols")]
def c_word_kind(var lx : FlexLexer) : int {
    if (lx.syms.fresh_kind != int(CTok.IDENTIFIER)) {
        c_symbols(lx.syms)
    }
    return symbol_kind(lx.syms, intern(lx))
}

//! C11 Annex D.1: the code points past ASCII an identifier may hold, as UCNs or as UTF-8
let C11_IDENT_RANGES = fixed_array(uint2(0xA8, 0xA8), uint2(0xAA, 0xAA), uint2(0xAD, 0xAD), uint2(0xAF, 0xAF),
                                   uint2(0xB2, 0xB5), uint2(0xB7, 0xBA), uint2(0xBC, 0xBE), uint2(0xC0, 0xD6),
                                   uint2(0xD8, 0xF6), uint2(0xF8, 0xFF), uint2(0x100, 0x167F), uint2(0x1681, 0x180D),
                                   uint2(0x180F, 0x1FFF), uint2(0x200B, 0x200D), uint2(0x202A, 0x202E), uint2(0x203F, 0x2040),
                                   uint2(0x2054, 0x2054), uint2(0x2060, 0x206F), uint2(0x2070, 0x218F), uint2(0x2460, 0x24FF),
                                   uint2(0x2776, 0x2793), uint2(0x2C00, 0x2DFF), uint2(0x2E80, 0x2FFF), uint2(0x3004, 0x3007),
                                   uint2(0x3021, 0x302F), uint2(0x3031, 0x303F), uint2(0x3040, 0xD7FF), uint2(0xF900, 0xFD3D),
                                   uint2(0xFD40, 0xFDCF), uint2(0xFDF0, 0xFE44), uint2(0xFE47, 0xFFFD), uint2(0x10000, 0x1FFFD),
                                   uint2(0x20000, 0x2FFFD), uint2(0x30000, 0x3FFFD), uint2(0x40000, 0x4FFFD), uint2(0x50000, 0x5FFFD),
                                   uint2(0x60000, 0x6FFFD), uint2(0x70000, 0x7FFFD), uint2(0x80000, 0x8FFFD), uint2(0x90000, 0x9FFFD),
                                   uint2(0xA0000, 0xAFFFD), uint2(0xB0000, 0xBFFFD), uint2(0xC0000, 0xCFFFD), uint2(0xD0000, 0xDFFFD),
                                   uint2(0xE0000, 0xEFFFD))

//! C11 Annex D.2: the code points of D.1 an identifier may not start with
let C11_NOT_INITIAL = fixed_array(uint2(0x300, 0x36F), uint2(0x1DC0, 0x1DFF), uint2(0x20D0, 0x20FF), uint2(0xFE20, 0xFE2F))

//! whether code point `cp` past ASCII may stand in an identifier, at its start when `initial`
def c11_ident_char(cp : int; initial : bool) : bool {
    let u = uint(cp)
    return ((find_index_if(C11_IDENT_RANGES) $(r) => u >= r.x && u <= r.y) >= 0
        && !(initial && (find_index_if(C11_NOT_INITIAL) $(r) => u >= r.x && u <= r.y) >= 0))
}

//! the code point of the UCN at `at` (`\uHHHH` or `\UHHHHHHHH`, the digits all hex) and its length;
//! -1 for a surrogate or a value past U+10FFFF
def private ucn_at(bytes : array<uint8> | #; at : int) : int2 {
    let digits = int(bytes[at + 1]) == 'u' ? 4 : 8
    return int2(escape_codepoint(bytes, at), digits + 2)
}

//! the code point of the well-formed UTF-8 character at `at` and its length
def private utf8_at(bytes : auto; at : int) : int2 {
    let b = int(bytes[at])
    let n = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
    var cp = b & (int(0x7F) >> n)
    for (k in range(1, n)) {
        cp = (cp << 6) | (int(bytes[at + k]) & 0x3F)
    }
    return int2(cp, n)
}

//! the bytes of `bytes[start..end)` - ASCII identifier characters, well-formed UTF-8 and UCNs -
//! that open it as a C identifier: up to the first character Annex D does not allow there
def c_ident_prefix(bytes : auto; start, end : int) : int {
    var at = start
    while (at < end) {
        let b = int(bytes[at])
        if (b < 0x80 && b != '\\') {
            at++
            continue
        }
        let ch = b == '\\' ? ucn_at(bytes, at) : utf8_at(bytes, at)
        break if (!c11_ident_char(ch.x, at == start))
        at += ch.y
    }
    return at - start
}

//! the extended identifier rule's check, for a token holding a UCN or a character outside Annex D:
//! the token shortened to the identifier that opens it, or, when none does, the lexer failed at
//! the token's first byte (false)
[arch(at="../../ARCHITECTURE.md#c-unicode")]
def c_ident_cut(var lx : FlexLexer) : bool {
    let n = c_ident_prefix(lx.bytes, lx.tok.start, lx.tok.start + lx.tok.len)
    return true if (n == lx.tok.len)
    lx.pos = lx.tok.start + n
    lx.line = lx.tok.line
    lx.col = lx.tok.col + n
    if (n > 0) {
        lx.tok.len = n
        lx.tok.text = ""
        return true
    }
    lx.failed = true
    lx.err = flex_error_text(lx)
    return false
}

//! `flex_open` for C source: the keywords interned (`c_symbols`), a
//! UTF-8 byte order mark at offset 0 skipped as clang and gcc skip it
def c_open(var lx : FlexLexer; src : string; file : string = "") {
    flex_open(lx, src, file)
    c_symbols(lx.syms)
    if (contains_utf8_bom(lx.bytes)) {
        lx.pos = 3
        lx.col = 4
    }
}

//! a one-byte punctuator is its own kind
[inline]
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
    rule("[a-zA-Z_$\\u00A8\\u00AA\\u00AD\\u00AF\\u00B2-\\u00B5\\u00B7-\\u00BA\\u00BC-\\u00BE\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u00FF\\u0100-\\u02FF\\u0370-\\u167F\\u1681-\\u180D\\u180F-\\u1DBF\\u1E00-\\u1FFF\\u200B-\\u200D\\u202A-\\u202E\\u203F-\\u2040\\u2054\\u2060-\\u206F\\u2070-\\u20CF\\u2100-\\u218F\\u2460-\\u24FF\\u2776-\\u2793\\u2C00-\\u2DFF\\u2E80-\\u2FFF\\u3004-\\u3007\\u3021-\\u302F\\u3031-\\u303F\\u3040-\\uD7FF\\uF900-\\uFD3D\\uFD40-\\uFDCF\\uFDF0-\\uFE1F\\uFE30-\\uFE44\\uFE47-\\uFFFD\\U00010000-\\U0001FFFD\\U00020000-\\U0002FFFD\\U00030000-\\U0003FFFD\\U00040000-\\U0004FFFD\\U00050000-\\U0005FFFD\\U00060000-\\U0006FFFD\\U00070000-\\U0007FFFD\\U00080000-\\U0008FFFD\\U00090000-\\U0009FFFD\\U000A0000-\\U000AFFFD\\U000B0000-\\U000BFFFD\\U000C0000-\\U000CFFFD\\U000D0000-\\U000DFFFD\\U000E0000-\\U000EFFFD][a-zA-Z_$0-9\\u00A8\\u00AA\\u00AD\\u00AF\\u00B2-\\u00B5\\u00B7-\\u00BA\\u00BC-\\u00BE\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u00FF\\u0100-\\u167F\\u1681-\\u180D\\u180F-\\u1FFF\\u200B-\\u200D\\u202A-\\u202E\\u203F-\\u2040\\u2054\\u2060-\\u206F\\u2070-\\u218F\\u2460-\\u24FF\\u2776-\\u2793\\u2C00-\\u2DFF\\u2E80-\\u2FFF\\u3004-\\u3007\\u3021-\\u302F\\u3031-\\u303F\\u3040-\\uD7FF\\uF900-\\uFD3D\\uFD40-\\uFDCF\\uFDF0-\\uFE44\\uFE47-\\uFFFD\\U00010000-\\U0001FFFD\\U00020000-\\U0002FFFD\\U00030000-\\U0003FFFD\\U00040000-\\U0004FFFD\\U00050000-\\U0005FFFD\\U00060000-\\U0006FFFD\\U00070000-\\U0007FFFD\\U00080000-\\U0008FFFD\\U00090000-\\U0009FFFD\\U000A0000-\\U000AFFFD\\U000B0000-\\U000BFFFD\\U000C0000-\\U000CFFFD\\U000D0000-\\U000DFFFD\\U000E0000-\\U000EFFFD]*") {
        lx |> emit(c_word_kind(lx))
    }
    rule("(?:[a-zA-Z_$\\u0080-\\U0010FFFF]|\\\\u[0-9a-fA-F]\{4\}|\\\\U[0-9a-fA-F]\{8\})(?:[a-zA-Z_$0-9\\u0080-\\U0010FFFF]|\\\\u[0-9a-fA-F]\{4\}|\\\\U[0-9a-fA-F]\{8\})*") {
        return false if (!c_ident_cut(lx))
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
    rule("(u|U|L)?'([^'\\\\\\n]|(\\\\([\\'\"?\\\\abfnrtv]|[0-7]+|x[a-fA-F0-9]+|u[a-fA-F0-9]\{4\}|U[a-fA-F0-9]\{8\})))+'") {
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
    rule("(u8|u|U|L)?\"([^\"\\\\\\n]|(\\\\([\\'\"?\\\\abfnrtv]|[0-7]+|x[a-fA-F0-9]+|u[a-fA-F0-9]\{4\}|U[a-fA-F0-9]\{8\})))*\"") {
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
