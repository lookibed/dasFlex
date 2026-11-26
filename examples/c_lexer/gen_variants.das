options gen2
options indenting = 4

// Writes `c_lexer_goto.das` and `c_lexer_variants.das`: the rule list of `c_next` in `c_lexer.das`
// stamped under the scanner shapes the timing driver compares, and in the second file `c_scanner`,
// the scanner of each shape by its `--mode` name in `c_lex_compare.das`; and `c_lexer_pp.das`, the
// same rules as preprocessing tokens. A file that already holds its text is not touched, so a second
// run writes nothing.
//
//   daslang examples/c_lexer/gen_variants.das

require daslib/fio
require daslib/rtti
require daslib/strings_boost
require daslib/stringify
require strings

//! one generated scanner: its function name, the `[flex(...)]` arguments and its `--mode` name
struct Variant {
    name : string
    shape : string
    mode : string
}

//! one generated file: the module, the sentence saying what its scanners are for, the scanners,
//! whether `c_scanner` goes with them, and whether their rules are the preprocessing-token form
//! (`pp_rule_lines`), a token stream `c_scanner` does not hand out
struct Target {
    file : string
    module_name : string
    purpose : string
    variants : array<Variant>
    dispatch : bool
    pp : bool
}

def targets() : array<Target> {
    return <- [
        Target(file = "c_lexer_goto.das", module_name = "c_lexer_goto",
               purpose = ("The example's C11 rules compiled in `goto` mode with an if chain over the "
                   + "rule number, for the\n// table-against-code measurement only."),
               variants <- [
                   Variant(name = "c_next_goto", shape = "mode = \"goto\", dispatch = \"if\"", mode = "goto")]),
        Target(file = "c_lexer_variants.das", module_name = "c_lexer_variants",
               purpose = ("The example's C11 rules under the shapes other than the default, for the "
                   + "measurement only: table\n// mode calling `flex_match_table` with an if chain, a "
                   + "computed goto and a binary tree over the rule\n// number, and goto mode with "
                   + "the computed goto."),
               dispatch = true,
               variants <- [
                   Variant(name = "c_next_dgoto",
                           shape = "dispatch = \"goto\", matcher = \"call\"", mode = "flex-dgoto"),
                   Variant(name = "c_next_dtree",
                           shape = "dispatch = \"tree\", matcher = \"call\"", mode = "flex-dtree"),
                   Variant(name = "c_next_goto_dgoto",
                           shape = "mode = \"goto\", dispatch = \"goto\"", mode = "goto-dgoto"),
                   Variant(name = "c_next_call", shape = "dispatch = \"if\", matcher = \"call\"", mode = "flex-call"),
                   Variant(name = "c_next_table", shape = "mode = \"table\"", mode = "table")]),
        Target(file = "c_lexer_pp.das", module_name = "c_lexer_pp",
               purpose = ("The example's C11 rules as preprocessing tokens (C11 6.4): one pp-number "
                   + "rule in place of the\n// constant rules, `#` and `##` punctuators in place of "
                   + "the skipped `#` line, every identifier an\n// IDENTIFIER - no keyword, no typedef "
                   + "name - and any other character a PP_OTHER token. The input is\n// past "
                   + "translation phase 2, its backslash-newline line splices removed: a skipping rule "
                   + "cannot\n// remove one, since it sets the token flags. Neither this lexer nor "
                   + "`c_next` takes digraphs\n// (`<:`, `%:`)."),
               pp = true,
               variants <- [Variant(name = "c_next_pp", shape = "flags = true", mode = "pp")])]
}

//! the rules `pp_rule_lines` puts in place of the skipped `#` line; the reader's text starts with the
//! newline after its `~`, cut off
let private PP_HASH_RULES = slice(%stringify~
    rule("##") {
        lx |> emit(CTok.HASHHASH)
    }
    rule("#") {
        lx |> emit(c_byte_kind(lx))
    }
%%, 1)

//! the pp-number of C11 6.4.8, in place of the first numeric constant rule: after a digit, the
//! identifier-nondigits - `IDENT_CONTINUE` stands for the code points the identifier rule continues
//! with, UCNs as the extended identifier rule spells them - dots and exponent signs; the sign set
//! escapes its `-`, which `daslib/regex` drops from the edge of a set
let private PP_NUMBER_RULE = slice(%stringify~
    rule("\\.?[0-9]([0-9a-zA-Z_.IDENT_CONTINUE]|\\\\u[0-9a-fA-F]\{4\}|\\\\U[0-9a-fA-F]\{8\}|[eEpP][+\\-])*") {
        lx |> emit(CTok.PP_NUMBER)
    }
%%, 1)

//! C11 6.4p3: the last rule, any other character - one code point, or one byte no code point starts
//! with - is a preprocessing token of its own
let private PP_OTHER_RULE = slice(%stringify~
    rule(".|[\\x80-\\xFF]") {
        lx |> emit(CTok.PP_OTHER)
    }
%%, 1)

//! the code points of the identifier rule's continue set in `lines`, as the rule spells them, past
//! its ASCII `a-zA-Z_$0-9`; "" when no rule opens with that set
def private ident_continue(lines : array<string>) : string {
    let head = "][a-zA-Z_$0-9"
    let at = find_index_if(lines) $(line) => starts_with(line, "    rule(\"[a-zA-Z_$") && find(line, head) > 0
    return "" if (at < 0)
    let from = find(lines[at], head) + length(head)
    return slice(lines[at], from, find(lines[at], "]*\")", from))
}

//! whether the rule in `lines[first..last]` lexes a number: an integer or floating constant, the
//! character constant left out
def private is_number_rule(lines : array<string>; first, last : int) : bool {
    let emits_constant = find_index_if(subarray(lines, range(first, last + 1))) $(line) {
        return find(line, "CTok.F_CONSTANT") >= 0 || find(line, "CTok.I_CONSTANT") >= 0
    }
    return emits_constant >= 0 && find(lines[first], "'") < 0
}

//! `rules` as preprocessing tokens: the skipped `#` line becomes the `#` and `##` punctuators, the
//! numeric constant rules one pp-number rule, an identifier is IDENTIFIER whatever its symbol's kind
//! and the extended identifier rule's refused character PP_OTHER, a block comment keeps `at_bol` as
//! one space would (`c_pp_comment_open`, `c_pp_comment_close`), and a catch-all rule comes last
//! before the start conditions; every other line as it is
[arch(at="../../ARCHITECTURE_TOKENS.md#pp-tokens")]
def pp_rule_lines(rules : string) : string {
    let words = replace(replace(rules, "        return false if (!c_ident_cut(lx))\n        lx |> emit(c_word_kind(lx))",
                                "        lx |> emit(c_pp_ident_cut(lx))"), "c_word_kind(lx)", "c_pp_word(lx)")
    let comments = replace(replace(words, "        lx |> begin(\"COMMENT\")",
                                   "        c_pp_comment_open(lx)\n        lx |> begin(\"COMMENT\")"),
                           "            lx |> begin(\"INITIAL\")",
                           "            c_pp_comment_close(lx)\n            lx |> begin(\"INITIAL\")")
    let lines <- split(comments, "\n")
    let n = length(lines)
    let number_rule = replace(PP_NUMBER_RULE, "IDENT_CONTINUE", ident_continue(lines))
    var number_done = false
    var other_done = false
    return build_string() $(var w) {
        var i = 0
        while (i < n) {
            var last = i
            if (starts_with(lines[i], "    rule(")) {
                while (last + 1 < n && lines[last] != "    }") {
                    last++
                }
            }
            if (!other_done && (starts_with(lines[i], "    condition(") || (i + 1 == n && empty(lines[i])))) {
                w |> write(PP_OTHER_RULE)
                other_done = true
            }
            if (lines[i] == "    rule(\"#[^\\\\n]*\") \{") {
                w |> write(PP_HASH_RULES)
            } elif (last > i && is_number_rule(lines, i, last)) {
                w |> write(number_done ? "" : number_rule)
                number_done = true
            } else {
                for (k in range(i, last + 1)) {
                    w |> write(lines[k])
                    w |> write(k + 1 < n ? "\n" : "")
                }
            }
            i = last + 1
        }
    }
}

//! the lines between `def c_next(...) {` and the `}` that closes it, each with its newline; "" when
//! the source holds no such function
def rule_lines(source : string) : string {
    let lines <- split(source, "\n")
    let first = find_index_if(lines) $(line) => starts_with(line, "def c_next(")
    return "" if (first < 0)
    return build_string() $(var w) {
        for (i in range(first + 1, length(lines))) {
            break if (lines[i] == "}")
            w |> write(lines[i])
            w |> write("\n")
        }
    }
}

//! `C_SHAPES` and `c_scanner` over `scanners`, the scanners written by hand (`c_next`, `c_next_reader`)
//! first
def private write_dispatch(var w : StringBuilderWriter; scanners : array<Variant>) {
    let names = join([for (v in scanners); "\"{v.mode}\""], ", ")
    w |> write("\n//! the `--mode` name in `c_lex_compare.das` of every scanner shape of the C rules\n")
    w |> write("let C_SHAPES = fixed_array({names})\n")
    w |> write("\n//! the scanner of the shape `C_SHAPES` names `shape`; `c_next` for any other name\n")
    w |> write("def c_scanner(shape : string) : function<(var lx : FlexLexer) : bool> \{\n")
    for (v in scanners) {
        w |> write("    return @@{v.name} if (shape == \"{v.mode}\")\n") if (v.name != "c_next")
    }
    w |> write("    return @@c_next\n\}\n")
}

def file_text(target : Target; rules : string; scanners : array<Variant>) : string {
    return build_string() $(var w) {
        w |> write("options gen2\noptions indenting = 4\n\nmodule {target.module_name} shared public\n\n")
        w |> write("// Generated by gen_variants.das from the rules of `c_next` in c_lexer.das: edit "
            + "those, then run it.\n// {target.purpose}\n\n")
        w |> write("require flex/flex_macro public\nrequire c_lexer\n")
        w |> write("require c_lexer_goto\nrequire c_lexer_reader\n") if (target.dispatch)
        let body = target.pp ? pp_rule_lines(rules) : rules
        for (v in target.variants) {
            let args = empty(v.shape) ? "" : "({v.shape})"
            w |> write("\n[flex{args}]\ndef {v.name}(var lx : FlexLexer) : bool \{  "
                + "// nolint:STYLE038 - a rule list is one function by construction\n{body}\}\n")
        }
        write_dispatch(w, scanners) if (target.dispatch)
    }
}

//! one generated file: its path and the text it is to hold
struct Generated {
    path : string
    text : string
}

//! every generated file under `dir`, from the rules of `c_next` in `dir/c_lexer.das`; empty when
//! that file holds no `def c_next(`
def generated_files(dir : string) : array<Generated> {
    let rules = rule_lines(fread(path_join(dir, "c_lexer.das")))
    let all <- targets()
    var scanners <- [Variant(name = "c_next", mode = "flex"), Variant(name = "c_next_reader", mode = "reader")]
    for (target in all) {
        if (!target.pp) {
            scanners |> push_clone_from(target.variants)
        }
    }
    return <- [for (target in all); Generated(path = path_join(dir, target.file), text = file_text(target, rules, scanners)); where !empty(rules)]
}

[export]
def main() : int {
    let here = dir_name(string(get_line_info().fileInfo.name))
    let dir = empty(here) ? "." : here
    let files <- generated_files(dir)
    if (empty(files)) {
        print("{dir}/c_lexer.das: no `def c_next(` found\n")
        return 1
    }
    for (f in files) {
        print("{f.path}: {fwrite_if_changed(f.path, f.text) ? "written" : "unchanged"}\n")
    }
    return 0
}
