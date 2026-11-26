options gen2
options indenting = 4

module _flex_test_helpers shared public

// What the dasFlex test files share: compiling a virtual module - a fixture that must fail, or rules
// stamped under several scanner shapes and run.

require daslib/rtti
require daslib/ast
require daslib/debugger
require daslib/stringify
require daslib/strings_boost
require strings
require daslib/utf8_utils
require flex/flex

//! whether the test file runs under the JIT
def tier_is_jit() : bool => is_jit_function(@@tier_is_jit)

//! the UTF-8 encoding of code point `cp` as a string
def utf8_of(cp : int) : string {
    let bytes <- utf8_encode(uint(cp))
    return string(bytes)
}

//! opens `lx` on `src` as the file `t.txt` and returns every token `scan` takes, each through
//! `project`
def lex_tokens(var lx : FlexLexer; src : string; scan : block<(var lx : FlexLexer) : bool>;
               project : block<(var lx : FlexLexer) : auto(TT)>) : array<TT -const -&> {
    flex_open(lx, src, "t.txt")
    var out : array<TT -const -&>
    while (invoke(scan, lx)) {
        out |> push(invoke(project, lx))
    }
    return <- out
}

//! a token's flags, of any token type with `has_space` and `at_bol`: `s` for the one, `b` for the other
def flags_of(tok) : string => "{tok.has_space ? "s" : ""}{tok.at_bol ? "b" : ""}"

//! compiles `text` as the virtual file `name` - for the JIT tier's choices when `jit_policy`,
//! JIT-compiled when `jit` - and hands a program that compiled to `blk`: "" when it compiled and
//! `blk` returned "", else the compile issues or what `blk` returned
def private compile_virtual(name, text : string; jit_policy, jit : bool;
                            blk : block<(program : ProgramPtr) : string>) : string {
    var out = ""
    var inscope access <- make_file_access("")
    set_file_source(access, name, text)
    if (jit) {
        access |> add_extra_module("just_in_time", "{get_das_root()}/daslib/just_in_time.das")
    }
    using() $(var mg : ModuleGroup) {
        using() $(var cop : CodeOfPolicies) {
            cop.threadlock_context = true
            cop.jit_enabled = jit_policy || jit
            compile_file(name, access, unsafe(addr(mg)), cop) $(ok; program; issues) {
                out = ok ? invoke(blk, program) : string(issues)
            }
        }
    }
    return out
}

//! compiles `text` as the virtual file `name`, for the JIT tier's choices when `jit_policy`: "" when
//! it compiled clean, the issue text otherwise
def compile_issues(name, text : string; jit_policy : bool = false) : string =>
    compile_virtual(name, text, jit_policy, false) $(_program) => ""

//! the scanner driver of a stamped module: `run(shape, src, out)` lexes `src` with lexer `lex<shape>`
//! and writes `kind@line:col:text` per token - `kind@line:col/flags:text` when a flag is set, `flags` as
//! `flags_of` writes them - the error text, then what the rule bodies pushed to `rule_log`, joined
//! by `\x1F`
let private STAMP_RUN = %stringify~
var private rule_log : array<string>
[export]
def run(shape : int; src : string; var out : string?) {
    rule_log |> clear()
    var lx : FlexLexer
    flex_open(lx, src, "t.txt")
    var toks : array<string>
    while (lex_by(shape, lx)) {
        let flags = "{lx.tok.has_space ? "s" : ""}{lx.tok.at_bol ? "b" : ""}"
        let mark = empty(flags) ? "" : "/" + flags
        toks |> push("{lx.tok.kind}@{lx.tok.line}:{lx.tok.col}{mark}:{text(lx)}")
    }
    toks |> push(lx.err)
    toks |> push_from(rule_log)
    *out = join(toks, "\x1F")
}
%%

//! a module stamping the `[flex]` body `rules` once per entry of `shapes` as `lex0`, `lex1`, ...,
//! and the `run` of `STAMP_RUN` over them; an empty shape is `[flex]` with no arguments
def stamped_module(rules : string; shapes : array<string>) : string {
    return build_string() $(var w) {
        w |> write("options gen2\nrequire flex/flex_macro\nrequire daslib/strings_boost\n")
        for (i, shape in count(), shapes) {
            let args = empty(shape) ? "" : "({shape})"
            w |> write("[flex{args}]\ndef lex{i}(var lx : FlexLexer) : bool \{\n{rules}\n\}\n")
        }
        w |> write("def lex_by(shape : int; var lx : FlexLexer) : bool \{\n    return ")
        for (i in range(length(shapes))) {
            w |> write("shape == {i} ? lex{i}(lx) : ")
        }
        w |> write("false\n\}\n{STAMP_RUN}")
    }
}

//! `describe` of the body `[flex(shape)]` generates for `rules`, compiled as the virtual file `name`;
//! the compile issues when it does not compile
def scanner_text(name, rules, shape : string) : string {
    return compile_virtual(name, stamped_module(rules, [shape]), false, false) $(program) {
        var text = ""
        program.getThisModule |> for_each_function("lex0") $(fn) {
            text = describe(fn.body)
        }
        return text
    }
}

//! compiles `rules` stamped once per shape as the virtual file `name`, JIT-compiled when `jit`, and
//! lexes `src` with each lexer: the issues, or "" and the stream of every shape in the order of
//! `shapes`
def shape_streams(name, rules : string; shapes : array<string>; src : string;
                  jit : bool = false) : tuple<issues : string; streams : array<array<string>>> {
    var res : tuple<issues : string; streams : array<array<string>>>
    res.issues = compile_virtual(name, stamped_module(rules, shapes), jit, jit) $(program) {
        var serr = ""
        simulate(program) $(sok; context; serrors) {
            serr = sok ? "" : string(serrors)
            return if (!sok)
            for (shape in range(length(shapes))) {
                var out = ""
                unsafe {
                    *context |> invoke_in_context("run", shape, src, addr(out))
                }
                res.streams |> emplace(split(out, "\x1F"))
            }
        }
        return serr
    }
    return <- res
}
