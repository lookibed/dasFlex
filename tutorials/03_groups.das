// Tutorial dasFlex-03: capture groups
//
// This tutorial covers:
//   - group(n) and group_span(n) in a rule body: the parts of a token its regex captures
//   - a group that takes no part in the match
//   - the same calls in a %flex~ action
//
// Run: daslang -load_module <dasFlex> tutorials/03_groups.das

options gen2
options indenting = 4

require flex/flex_macro

enum CTok {
    SECTION = 1
    STRING = 2
    NUMBER = 3
}

// What the rule bodies read out of a config text: "section.key" to its value.
var settings : table<string; string>
var section = ""

// A token is a whole `key = value` line part; its parentheses are capture groups. In the body,
// `lx |> group(n)` is the text of group n (group 0 is the token), `lx |> group_span(n)` its byte
// range in the input. The automaton finds the token as always; the first group call on a token
// runs the rule's regex once over it, the next calls reuse that match. Rules that never call
// group - the comment and the blanks here - pay nothing for groups.
[flex]
def config_lexer(var lx : FlexLexer) : bool {
    rule("\\[([A-Za-z_]+)\\]") {
        section = lx |> group(1)
        lx |> emit(CTok.SECTION)
    }
    rule("([A-Za-z_][A-Za-z0-9_]*) *= *\"([^\"]*)\"") {
        settings["{section}.{lx |> group(1)}"] = lx |> group(2)
        lx |> emit(CTok.STRING)
    }
    // `(-)?` is a group that may take no part: then group(2) is "" and its span range(0, 0)
    rule("([A-Za-z_][A-Za-z0-9_]*) *= *(-)?([0-9]+)") {
        let sign = empty(lx |> group(2)) ? "" : "minus "
        settings["{section}.{lx |> group(1)}"] = "{sign}{lx |> group(3)} at {lx |> group_span(3)}"
        lx |> emit(CTok.NUMBER)
    }
    rule("#[^\\n]*") {
    }
    rule("[ \\t\\r\\n]+") {
    }
}

// The same calls in flex-like text: `group(n)` names the lexer implicitly, like `emit`. A
// definition `{NAME}` is not a group, so n counts only the parentheses the rule writes.
%flex~ pair_lexer : CTok
NAME    [A-Za-z_][A-Za-z0-9_]*
%rules
{NAME}=([0-9]+)     { print("  {group(0)}: value {group(1)}\n"); emit(NUMBER) }
[ ]+
%%

[export]
def main() {
    let src = "# server settings\n[server]\nhost = \"localhost\"\nport = 8080\n[limits]\nmin_temp = -5\n"
    var lx : FlexLexer
    flex_open(lx, src, "demo.cfg")
    while (config_lexer(lx)) {
    }
    for (key in ["server.host", "server.port", "limits.min_temp"]) {
        print("{key} = {settings?[key] ?? "?"}\n")    // server.port = 8080 at 53,57
    }
    flex_open(lx, "a=1 b2=20", "pairs")
    while (pair_lexer(lx)) {
    }
}
