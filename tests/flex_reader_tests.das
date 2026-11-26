options gen2
options indenting = 4

require dastest/testing_boost public
require daslib/rtti
require daslib/ast
require strings
require daslib/strings_boost
require flex/flex_macro
require _flex_test_helpers

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

%flex~ r_alt : RTok
XY      x|y
%rules
{XY}z               { emit(WORD) }
"\u00e9+\U0001F600"  { emit(LIT) }
" "+
%%

%flex~ r_untyped
%rules
[0-9]+              { lx |> emit(7) }
"/"[a-z]+           { lx |> emit(8) }
\/[/]               { lx |> emit(9) }
.                   { }
%%

// what the actions of `r_groups` saw, one line per token
var private reader_group_log : array<string>

%flex~ r_groups : RTok
D       [0-9]
%rules
{D}+"="([a-z]+)     { reader_group_log |> push("{group(1)}@{group_span(1)}"); emit(WORD) }
(0x)?{D}+           {
    reader_group_log |> push("'{lx |> group(1)}'@{lx |> group_span(1)}")
    emit(NUM)
}
" "+
%%

// what the actions of `r_braces` saw, one entry per token
var private brace_log : array<string>

%flex~ r_braces : RTok
%rules
a                   { brace_log |> push(to_char('}')); emit(WORD) }
b                   { brace_log |> push("\}"); emit(NUM) }
c                   {
    // a } in a comment closes nothing
    brace_log |> push("c")
    emit(PLUS)
}
" "+
%%

//! the tokens of `src` as `kind:text` from one of the reader lexers, then the error text
def stream(src, which : string) : array<string> {
    var lx : FlexLexer
    var out <- lex_tokens(lx, src, $(var l : FlexLexer) {
        return (which == "kinds" ? r_kinds(l) : which == "defs" ? r_defs(l)
            : which == "groups" ? r_groups(l) : which == "braces" ? r_braces(l)
            : which == "alt" ? r_alt(l) : r_untyped(l))
    }, $(var l : FlexLexer) => "{l.tok.kind}:{text(l)}")
    out |> push(lx.err)
    return <- out
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

[test(description = "a quoted pattern is literal text, an unquoted one a regex, a quoted, escaped or bracketed slash a literal; definitions expand in parentheses, so `\{XY\}z` with `XY x|y` takes no lone x")]
def test_quoted_and_regex(t : T?) {
    t |> equal(stream("/ab // y", "untyped"), ["8:/ab", "9://", ""])
    t |> equal(stream("a+ aa", "kinds"), ["{int(RTok.LIT)}:a+", "{int(RTok.WORD)}:aa", ""])
    t |> equal(stream("a1 123 4", "defs"),
               ["{int(RTok.WORD)}:a1", "{int(RTok.NUM)}:12", "t.txt:1:6: unexpected '3'"])
    t |> equal(stream("xz yz x", "alt"),
               ["{int(RTok.WORD)}:xz", "{int(RTok.WORD)}:yz", "t.txt:1:7: unexpected 'x'"])
}

[test(description = "inside a quoted pattern \\u and \\U name a code point, as in a regex, while the rest of the text stays literal")]
def test_quoted_codepoint_escapes(t : T?) {
    t |> equal(stream("é+😀", "alt"), ["{int(RTok.LIT)}:é+😀", ""])
    t |> equal(stream("u00e9+", "alt"), ["t.txt:1:1: unexpected 'u'"])
}

[test(description = "emit, begin, an empty action, a brace-less and a multi-line action all run as daslang code")]
def test_actions(t : T?) {
    t |> equal(stream("1+2", "kinds"),
               ["{int(RTok.NUM)}:1", "{int(RTok.PLUS)}:+", "{int(RTok.NUM)}:2", ""])
    t |> equal(stream("#x\ny#", "kinds"), ["{int(RTok.BODY)}:x\ny", ""])
}

[test(description = "a closing brace inside a character literal, a string or a comment of an action does not end the action")]
def test_action_braces(t : T?) {
    brace_log |> clear()
    t |> equal(stream("a b c", "braces"),
               ["{int(RTok.WORD)}:a", "{int(RTok.NUM)}:b", "{int(RTok.PLUS)}:c", ""])
    t |> equal(brace_log, ["\}", "\}", "c"])
}

[test(description = "an action calls group(n) and group_span(n); a definition is a non-capturing group, so n counts the rule's own groups")]
def test_groups(t : T?) {
    reader_group_log |> clear()
    t |> equal(stream("12=ab 0x7 9", "groups"),
               ["{int(RTok.WORD)}:12=ab", "{int(RTok.NUM)}:0x7", "{int(RTok.NUM)}:9", ""])
    t |> equal(reader_group_log, ["ab@3,5", "'0x'@6,8", "''@0,0"])
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
    t |> run("an unknown definition") @(t : T?) {
        let issues = compile_issues("e5.das", reader_module("", "\"a\"  \{ emit(A) \}\n\{X\}+\n"))
        t |> success(find(issues, "\{X\}: no such definition") >= 0, issues)
        t |> success(find(issues, "e5.das:9:") >= 0, issues)
    }
    t |> run("trailing context: an unquoted, unescaped slash outside a set") @(t : T?) {
        let issues = compile_issues("e7.das",
                                    reader_module("", "\"a\"  \{ emit(A) \}\nab/c   \{ \}\n"))
        t |> success(find(issues, "trailing context (r/s) is not carried by dasFlex") >= 0,
                     issues)
        t |> success(find(issues, "e7.das:9:") >= 0, issues)
    }
}

[test(description = "reader text with CRLF line ends reads as with LF: the carriage returns are dropped, an error keeps its line")]
def test_crlf_text(t : T?) {
    let clean = replace(reader_module("D  [0-9]\n", "\"a\"  \{ emit(A) \}\n\{D\}+\n"), "\n", "\r\n")
    t |> equal(compile_issues("crlf1.das", clean), "")
    let bad = replace(reader_module("", "\"a\"  \{ emit(A) \}\n<NOPE>b\n"), "\n", "\r\n")
    let issues = compile_issues("crlf2.das", bad)
    t |> success(find(issues, "<NOPE>: no such start condition") >= 0, issues)
    t |> success(find(issues, "crlf2.das:9:") >= 0, issues)
}

//! a module with a `[flex]` function whose body is `body`, starting at line 5
def private flex_module(body : string) : string =>
    "options gen2\nrequire flex/flex_macro\n[flex]\ndef bad(var lx : FlexLexer) : bool \{\n{body}\}\n"

[test(description = "every refusal of the %flex~ reader names its reason at the line it met it on")]
def test_reader_refusals(t : T?) {
    let cases <- [
        (reader_module("", "\"ab  \{ emit(A) \}\n"),
         "a quoted literal ends at the end of the line", 8),
        (reader_module("", "\"a\\\n"), "a quoted literal ends at the end of the line", 8),
        (reader_module("", "[ab  \{ \}\n"), "a [set] ends at the end of the line", 8),
        (reader_module("", "ab\\\n"), "the pattern ends with a backslash", 8),
        (reader_module("", "a  \{ emit(A)\n"), "the action ends at the end of the rules", 9),
        (reader_module("", "<A b  \{ \}\n"), "<CONDITION> expected", 8),
        (reader_module("", "<A> \{ \}\n"), "a rule starts with a pattern", 8),
        (reader_module("", "a  \{ emit(A) \} x\n"),
         "nothing but a comment follows an action on its line", 8),
        (reader_module("", "a  emit(A) // c\n"),
         "an action with a comment on its line is written in braces", 8),
        ("options gen2\nrequire flex/flex_macro\n%flex~ bad bad\n%rules\na\n%%\n",
         "the header is `%flex~ name : TokenEnum`", 3),
        (reader_module("%option speed=fast\n", "a\n"),
         "%option takes mode=, dispatch= and matcher=, not speed=fast", 7),
        (reader_module("D  [0-9] x\n", "a\n"), "a definition is `NAME regex`, one pattern", 7),
        (reader_module("%y C\n", "a\n"),
         "a definition is `%x NAMES`, `%s NAMES`, `%option key=value` or `NAME regex`", 7),
        ("options gen2\nrequire flex/flex_macro\n%flex~ bad\nD  [0-9]\n%%\n",
         "the rules section starts at a line `%rules`", 5)]
    for (i, c in count(), cases) {
        let issues = compile_issues("r{i}.das", c._0)
        t |> success(find(issues, "%flex~: {c._1}") >= 0, issues)
        t |> success(find(issues, "r{i}.das:{c._2}:") >= 0, issues)
    }
}

[test(description = "every refusal of a [flex] body names its reason at the statement it met, or at the annotation for the whole function")]
def test_flex_body_refusals(t : T?) {
    let cases <- [
        (flex_module("    rule(1) \{\n    \}\n"), "rule(\"regex\") \{ ... \} expected", 5),
        (flex_module("    rule(\"a\") $(x : int) \{\n    \}\n"),
         "a rule block takes no arguments: the lexer is the function's parameter", 5),
        (flex_module("    condition(\"C\") \{\n    \}\n"),
         "condition(\"NAME\", exclusive|inclusive) \{ rules \} expected", 5),
        (flex_module("    condition(\"C\", both) \{\n    \}\n"),
         "condition kind is exclusive or inclusive, not both", 5),
        (flex_module("    let x = 1\n"),
         "only rule(...) and condition(...) calls belong in a [flex] body", 5),
        (flex_module("    condition(\"C\", exclusive) \{\n        let x = 1\n    \}\n"),
         "only rule(...) calls belong in a condition block", 6),
        (flex_module("    print(\"x\")\n"),
         "only rule(...) and condition(...) calls belong in a [flex] body, not print", 5),
        (flex_module(""), "[flex] body has no rules", 3),
        (replace(flex_module("    rule(\"a\") \{\n    \}\n"), "FlexLexer)", "FlexLexer; n : int)"),
         "[flex] takes one argument: var lx : FlexLexer", 3)]
    for (i, c in count(), cases) {
        let issues = compile_issues("f{i}.das", c._0)
        t |> success(find(issues, c._1) >= 0, issues)
        t |> success(find(issues, "f{i}.das:{c._2}:") >= 0, issues)
    }
}

[test(description = "group() in a rule whose regex has no capture group, or past its last group, fails the compile at the rule's line, once, in both forms")]
def test_group_errors(t : T?) {
    t |> run("reader: a regex without groups") @(t : T?) {
        let issues = compile_issues("g1.das",
                                    reader_module("", "\"a\"  \{ emit(A) \}\n[0-9]+   \{ print(group(1)) \}\n"))
        t |> success(find(issues, "group() asks for a capture group, the regex has none") >= 0,
                     issues)
        t |> success(find(issues, "g1.das:9:") >= 0, issues)
    }
    t |> run("reader: an index past the last group") @(t : T?) {
        let issues = compile_issues("g2.das",
                                    reader_module("", "\"a\"  \{ emit(A) \}\n([0-9]+)   \{ print(group_span(2)) \}\n"))
        t |> success(find(issues, "group(2) asks for a group the regex does not have (1)") >= 0,
                     issues)
        t |> success(find(issues, "g2.das:9:") >= 0, issues)
    }
    t |> run("[flex]: a regex without groups") @(t : T?) {
        let src = ("options gen2\nrequire flex/flex_macro\n[flex]\ndef bad(var lx : FlexLexer) : bool \{\n"
            + "    rule(\"a\") \{\n        lx |> emit(1)\n    \}\n"
            + "    rule(\"[0-9]+\") \{\n        print(lx |> group(1))\n    \}\n\}\n")
        let issues = compile_issues("g3.das", src)
        t |> equal(count(issues, "group() asks for a capture group, the regex has none"), 1, issues)
        t |> success(find(issues, "g3.das:8:") >= 0, issues)
        t |> success(find(issues, "see the error at line 8") >= 0, issues)
    }
}

[test(description = "a type error in the arguments of emit or group is reported at the rule body's line, in both forms")]
def test_action_error_lines(t : T?) {
    t |> run("[flex]: emit and group") @(t : T?) {
        let src = ("options gen2\nrequire flex/flex_macro\n[flex]\ndef bad(var lx : FlexLexer) : bool \{\n"
            + "    rule(\"a\") \{\n        lx |> emit(\"oops\")\n    \}\n"
            + "    rule(\"b(c)\") \{\n        print(lx |> group(\"x\"))\n    \}\n\}\n")
        let issues = compile_issues("a1.das", src)
        t |> success(find(issues, "a1.das:6:") >= 0, issues)
        t |> success(find(issues, "a1.das:9:") >= 0, issues)
        t |> success(find(issues, "flex_macro.das") < 0, issues)
    }
    t |> run("reader: emit") @(t : T?) {
        let issues = compile_issues("a2.das",
                                    reader_module("", "\"a\"  \{ emit(A) \}\nb   \{ emit(\"oops\") \}\n"))
        t |> success(find(issues, "a2.das:9:") >= 0, issues)
        t |> success(find(issues, "flex_macro.das") < 0, issues)
    }
}

[test(description = "a start condition declared twice, INITIAL included, fails the compile at the second declaration, in both forms")]
def test_duplicate_conditions(t : T?) {
    let head = "options gen2\nrequire flex/flex_macro\n[flex]\ndef bad(var lx : FlexLexer) : bool \{\n"
    let rule_a = "    rule(\"a\") \{\n        lx |> emit(1)\n    \}\n"
    t |> run("[flex]: a condition declared twice") @(t : T?) {
        let cond_c = "    condition(\"C\", exclusive) \{\n        rule(\"b\") \{\n        \}\n    \}\n"
        let issues = compile_issues("d1.das", head + rule_a + cond_c + cond_c + "\}\n")
        t |> success(find(issues, "a start condition of that name is declared already") >= 0,
                     issues)
        t |> success(find(issues, "d1.das:12:") >= 0, issues)
    }
    t |> run("[flex]: INITIAL declared") @(t : T?) {
        let cond_i = "    condition(\"INITIAL\", inclusive) \{\n        rule(\"b\") \{\n        \}\n    \}\n"
        let issues = compile_issues("d2.das", head + rule_a + cond_i + "\}\n")
        t |> success(find(issues, "INITIAL is every lexer's default start condition") >= 0, issues)
        t |> success(find(issues, "d2.das:8:") >= 0, issues)
    }
    t |> run("reader: a condition declared twice, INITIAL declared") @(t : T?) {
        let rules = "\"a\"  \{ emit(A) \}\n"
        var issues = compile_issues("d3.das", reader_module("%x C\n%s C\n", rules))
        t |> success(find(issues, "%s C: a start condition of that name is declared already") >= 0,
                     issues)
        t |> success(find(issues, "d3.das:8:") >= 0, issues)
        issues = compile_issues("d4.das", reader_module("%x INITIAL\n", rules))
        t |> success(find(issues, "INITIAL is every lexer's default start condition") >= 0, issues)
        t |> success(find(issues, "d4.das:7:") >= 0, issues)
    }
}

