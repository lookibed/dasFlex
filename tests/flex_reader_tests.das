options gen2
options indenting = 4

require dastest/testing_boost public
require daslib/rtti
require daslib/ast
require strings
require daslib/strings_boost
require flex/flex_macro

enum RTok {
    WORD = 1
    NUM = 2
    PLUS = 3
    LIT = 4
    TAG = 5
    BODY = 6
}

%flex~ r_kinds : RTok
%x TAGGED
%s ANGLE
%rules
[a-z]+              { emit(WORD) }
[0-9]+              { emit(NUM) }
"a+"                { emit(LIT) }
\+                  emit(PLUS)
[ ]+
"<"                 { begin(ANGLE) }
"#"                 { begin(TAGGED) }
<ANGLE>">"          { begin(INITIAL) }
<ANGLE>"="          { emit(TAG) }
<TAGGED>[^#]+       {
    emit(BODY)
}
<TAGGED>"#"         { begin(INITIAL) }
<ANGLE,TAGGED>"!"   { emit(int(RTok.TAG) * 10) }
<*>"?"              { emit(lx.tok.len + 100) }
%%

%flex~ r_defs : RTok
D       [0-9]
WORD    [a-z]({D}|[a-z])*
%option mode=goto dispatch=tree
%rules
// a definition expands in parentheses, a {n} repetition stays a repetition
{WORD}              { emit(WORD) }
{D}{2}              { emit(NUM) }
" "+
%%

%flex~ r_untyped
%rules
[0-9]+              { lx |> emit(7) }
.                   { }
%%

//! the tokens of `src` as `kind:text` from one of the reader lexers, then the error text
def stream(src, which : string) : array<string> {
    var lx : FlexLexer
    flex_open(lx, src, "t.txt")
    var out : array<string>
    while (which == "kinds" ? r_kinds(lx) : which == "defs" ? r_defs(lx) : r_untyped(lx)) {
        out |> push("{lx.tok.kind}:{text(lx)}")
    }
    out |> push(lx.err)
    return <- out
}

//! compiles `text` as the virtual file `name`; "" when it compiled clean, the issue text otherwise
def private compile_issues(name, text : string) : string {
    var out = ""
    var inscope access <- make_file_access("")
    set_file_source(access, name, text)
    using() $(var mg : ModuleGroup) {
        using() $(var cop : CodeOfPolicies) {
            compile_file(name, access, unsafe(addr(mg)), cop) $(ok; _program; issues) {
                out = ok ? "" : string(issues)
            }
        }
    }
    return out
}

//! a module with the enum `E { A = 1 }` and a reader lexer of `rules` after `defs`
def private reader_module(defs, rules : string) : string =>
    "options gen2\nrequire flex/flex_macro\nenum E \{\n    A = 1\n\}\n%flex~ bad : E\n{defs}%rules\n{rules}%%\n"

[test(description = "the header names the token enum: a bare name in emit() is one of its members")]
def test_header_enum(t : T?) {
    t |> equal(stream("ab 12", "kinds"), ["{int(RTok.WORD)}:ab", "{int(RTok.NUM)}:12", ""])
    t |> equal(stream("x 42 y", "untyped"), ["7:42", ""])
}

[test(description = "%x hides the default rules, %s keeps them, <*> and <A,B> list the conditions a rule is active in")]
def test_start_conditions(t : T?) {
    t |> run("exclusive") @(t : T?) {
        t |> equal(stream("a#b 1#2", "kinds"),
                   ["{int(RTok.WORD)}:a", "{int(RTok.BODY)}:b 1", "{int(RTok.NUM)}:2", ""])
    }
    t |> run("inclusive keeps the default rules and adds its own") @(t : T?) {
        t |> equal(stream("<x 5=>=", "kinds"), ["{int(RTok.WORD)}:x", "{int(RTok.NUM)}:5",
                                                "{int(RTok.TAG)}:=", "t.txt:1:7: unexpected '='"])
    }
    t |> run("a rule listed for two conditions, and one for all") @(t : T?) {
        t |> equal(stream("<!?>#?#?", "kinds"),
                   ["50:!", "101:?", "{int(RTok.BODY)}:?", "101:?", ""])
        t |> equal(stream("!", "kinds")[0], "t.txt:1:1: unexpected '!'")
    }
}

[test(description = "a quoted pattern is literal text, an unquoted one a regex; definitions expand in parentheses")]
def test_quoted_and_regex(t : T?) {
    t |> equal(stream("a+ aa", "kinds"), ["{int(RTok.LIT)}:a+", "{int(RTok.WORD)}:aa", ""])
    t |> equal(stream("a1 123 4", "defs"),
               ["{int(RTok.WORD)}:a1", "{int(RTok.NUM)}:12", "t.txt:1:6: unexpected '3'"])
}

[test(description = "emit, begin, an empty action, a brace-less and a multi-line action all run as daslang code")]
def test_actions(t : T?) {
    t |> equal(stream("1+2", "kinds"),
               ["{int(RTok.NUM)}:1", "{int(RTok.PLUS)}:+", "{int(RTok.NUM)}:2", ""])
    t |> equal(stream("#x\ny#", "kinds"), ["{int(RTok.BODY)}:x\ny", ""])
}

[test(description = "the source the reader writes keeps every rule on the line it was written on")]
def test_line_preserving_source(t : T?) {
    let text = " lex : E\n%x C\n\n%rules\n\"a\"   \{\n    emit(A)\n\}\n<C>b\n"
    let out = flex_reader_source(text)
    t |> equal(out.err, "")
    let lines <- split(out.source, "\n")
    t |> success(
                 starts_with(lines[0],
                             "[flex_text(tokens = \"E\", conditions = \"C:x\")] def lex("))
    t |> equal(lines[4], "rule(\"a\", \"\") \{")
    t |> equal(lines[5], "    emit(A)")
    t |> equal(lines[7], "rule(\"b\", \"C\") \{\}")
}

[test(description = "an unknown condition, token, definition or a bad regex fails the compile at the rule's line")]
def test_errors(t : T?) {
    t |> run("unknown start condition") @(t : T?) {
        let issues = compile_issues("e1.das", reader_module("", "\"a\"  \{ emit(A) \}\n<NOPE>b\n"))
        t |> success(find(issues, "<NOPE>: no such start condition") >= 0, issues)
        t |> success(find(issues, "e1.das:9:") >= 0, issues)
    }
    t |> run("unknown condition in begin") @(t : T?) {
        let issues = compile_issues("e2.das",
                                    reader_module("",
                                                  "\"a\"  \{ emit(A) \}\nb   \{ begin(NOPE) \}\n"))
        t |> success(find(issues, "begin(\"NOPE\"): no such start condition") >= 0, issues)
        t |> success(find(issues, "e2.das:9:") >= 0, issues)
    }
    t |> run("unknown token name") @(t : T?) {
        let issues = compile_issues("e3.das",
                                    reader_module("", "\"a\"  \{ emit(A) \}\nb   \{ emit(B) \}\n"))
        t |> success(find(issues, "e3.das:9:") >= 0, issues)
    }
    t |> run("a regex that does not parse") @(t : T?) {
        let issues = compile_issues("e4.das",
                                    reader_module("", "\"a\"  \{ emit(A) \}\n(b   \{ \}\n"))
        t |> success(find(issues, "does not parse") >= 0, issues)
        t |> success(find(issues, "e4.das:9:") >= 0, issues)
    }
    t |> run("an unknown definition and a malformed line in the reader itself") @(t : T?) {
        var issues = compile_issues("e5.das", reader_module("", "\"a\"  \{ emit(A) \}\n\{X\}+\n"))
        t |> success(find(issues, "\{X\}: no such definition") >= 0, issues)
        t |> success(find(issues, "e5.das:9:") >= 0, issues)
        issues = compile_issues("e6.das", reader_module("%y C\n", "\"a\"  \{ emit(A) \}\n"))
        t |> success(find(issues, "e6.das:7:") >= 0, issues)
    }
}
