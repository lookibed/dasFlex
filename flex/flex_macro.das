options gen2
options indenting = 4
options strict_smart_pointers = true
options no_unused_block_arguments = false
options no_unused_function_arguments = false

module flex_macro shared public

require daslib/ast_boost
require daslib/templates_boost
require daslib/strings_boost
require daslib/defer
require math

require flex/flex_regex
require flex/flex_dfa
require flex/flex public

// `[flex]` on `def name(var lx : FlexLexer) : bool { rule("re") { ... } condition("C", exclusive) { ... } }`
// builds the DFA of every rule at compile time, stores its tables as private module globals and
// rewrites the function into the scanner: it returns true with `lx.tok` set when a rule called `emit`,
// false at the end of input or on a byte no rule accepts (`lx.failed`, `lx.err`). Rule bodies run
// in the function's own scope, so `lx` is the function's parameter under whatever name it carries.
// `[flex(mode="goto")]` emits the DFA as labelled straight-line code instead of reading the tables.

struct private FlexArm {
    rule : int
    body : array<ExpressionPtr>
}

struct private FlexSpec {
    rules : array<FlexRule>
    arms : array<FlexArm>
    cond_names : array<string>
    inclusive : array<bool>
    err : string
}

//! `begin(lx, "NAME")` in a rule body becomes `begin(lx, <index>)`.
class private BeginRewrite : AstVisitor {
    cond_names : array<string>
    err : string
    def override visitExprCall(var expr : ExprCall?) : ExpressionPtr {
        if (expr.name == "begin" && length(expr.arguments) == 2 && expr.arguments[1] is ExprConstString) {
            let cname = string((expr.arguments[1] as ExprConstString).value)
            var idx = -1
            for (i, n in count(), cond_names) {
                if (n == cname) {
                    idx = i
                }
            }
            if (idx < 0) {
                if (empty(err)) {
                    err = "begin(\"{cname}\"): no such start condition"
                }
            } else {
                expr.arguments[1] = new ExprConstInt(at = expr.at, value = idx)
            }
        }
        return <- expr
    }
}

def private collect_rule(var spec : FlexSpec; call : ExprCall?; conds : array<int>; var rw : BeginRewrite?) {
    if (length(call.arguments) != 2 || !(call.arguments[0] is ExprConstString) || !(call.arguments[1] is ExprMakeBlock)) {
        spec.err = "rule(\"regex\") \{ ... \} expected"
        return
    }
    var r : FlexRule
    r.pattern = string((call.arguments[0] as ExprConstString).value)
    r.conditions := conds
    var arm : FlexArm
    arm.rule = length(spec.rules)
    let blk = call.arguments[1] |> unquote_block
    if (!empty(blk.arguments)) {
        spec.err = "a rule block takes no arguments: the lexer is the function's parameter"
        return
    }
    for (s in blk.list) {
        var copy = clone_expression(s)
        make_visitor(*rw) $(adapter) {
            visit_expression(copy, adapter)
        }
        arm.body |> emplace(copy)
    }
    if (!empty(rw.err) && empty(spec.err)) {
        spec.err = rw.err
    }
    spec.rules |> emplace(r)
    spec.arms |> emplace(arm)
}

//! first pass: the condition names, so a `begin` may name a condition declared below it
def private collect_conditions(var spec : FlexSpec; body : ExprBlock?) {
    spec.cond_names |> push("INITIAL")
    spec.inclusive |> push(false)
    for (st in body.list) {
        if (st is ExprCall && (st as ExprCall).name == "condition") {
            let call = st as ExprCall
            if (length(call.arguments) != 3 || !(call.arguments[0] is ExprConstString) || !(call.arguments[1] is ExprVar) || !(call.arguments[2] is ExprMakeBlock)) {
                spec.err = "condition(\"NAME\", exclusive|inclusive) \{ rules \} expected"
                return
            }
            let kind = string((call.arguments[1] as ExprVar).name)
            if (kind != "exclusive" && kind != "inclusive") {
                spec.err = "condition kind is exclusive or inclusive, not {kind}"
                return
            }
            spec.cond_names |> push(string((call.arguments[0] as ExprConstString).value))
            spec.inclusive |> push(kind == "inclusive")
        }
    }
}

def private collect_rules(var spec : FlexSpec; body : ExprBlock?) {
    var rw = new BeginRewrite(cond_names := spec.cond_names)
    defer <| $() {
        unsafe {
            delete rw
        }
    }
    var top_conds : array<int>
    top_conds |> push(0)
    for (i, inc in count(), spec.inclusive) {
        if (inc) {
            top_conds |> push(i)
        }
    }
    var cond_no = 0
    for (st in body.list) {
        return if (!empty(spec.err))
        if (!(st is ExprCall)) {
            spec.err = "only rule(...) and condition(...) calls belong in a [flex] body"
            return
        }
        let call = st as ExprCall
        if (call.name == "rule") {
            collect_rule(spec, call, top_conds, rw)
        } elif (call.name == "condition") {
            cond_no++
            var own : array<int>
            own |> push(cond_no)
            let cblk = call.arguments[2] |> unquote_block
            for (cs in cblk.list) {
                return if (!empty(spec.err))
                if (!(cs is ExprCall) || (cs as ExprCall).name != "rule") {
                    spec.err = "only rule(...) calls belong in a condition block"
                    return
                }
                collect_rule(spec, cs as ExprCall, own, rw)
            }
        } else {
            spec.err = "only rule(...) and condition(...) calls belong in a [flex] body, not {call.name}"
            return
        }
    }
}

def private int_table_global(name : string; vals : array<int>; at : LineInfo; var errors : das_string) : bool {
    var mkArr = new ExprMakeArray(at = at, makeType <- typeinfo ast_typedecl(type<int>))
    for (v in vals) {
        mkArr.values |> emplace_new <| new ExprConstInt(at = at, value = v)
    }
    mkArr.makeType = make_fixed_array_type(length(vals), mkArr.makeType)
    var mkMove = new ExprCall(at = at, name := "to_array_move")
    mkMove.arguments |> emplace(mkArr)
    if (!(compiling_module() |> add_global_private_var(name, at, mkMove))) {
        errors := "can't add the global {name}"
        return false
    }
    return true
}

//! `if (rule == i) { body }` per rule, the dispatch after a match
def private make_arms(spec : FlexSpec; rule_var : string) : array<ExpressionPtr> {
    var arms : array<ExpressionPtr>
    for (arm in spec.arms) {
        var body : array<ExpressionPtr>
        for (s in arm.body) {
            body |> push(clone_expression(s))
        }
        arms |> push <| qmacro_block() {
            if ($i(rule_var) == $v(arm.rule)) {
                $b(body)
            }
        }
    }
    return <- arms
}

//! the DFA as straight-line code: `label s:` reads a byte, picks the next state by class ranges, jumps
def private make_goto_matcher(t : FlexTables; lx : string; cond_start : string; t_at : LineInfo) : array<ExpressionPtr> {
    var out : array<ExpressionPtr>
    let done = t.nstates
    // class -> representative byte ranges, to test bytes directly instead of through class_of
    var lo_of, hi_of : array<int>
    lo_of |> resize(t.nclasses)
    hi_of |> resize(t.nclasses)
    for (c in range(t.nclasses)) {
        lo_of[c] = 256
        hi_of[c] = -1
    }
    for (b, c in count(), t.class_of) {
        lo_of[c] = min(lo_of[c], b)
        hi_of[c] = max(hi_of[c], b)
    }
    out |> push <| qmacro_block() {
        goto $i(cond_start)
    }
    for (s in range(t.nstates)) {
        var moves : array<ExpressionPtr>
        for (c in range(t.nclasses)) {
            let nx = t.next[s * t.nclasses + c]
            continue if (nx < 0)
            let lo = lo_of[c]
            let hi = hi_of[c]
            if (lo == hi) {
                moves |> push <| qmacro_block() {
                    if (flex`b == $v(lo)) {
                        goto $v(nx)
                    }
                }
            } else {
                moves |> push <| qmacro_block() {
                    if (flex`b >= $v(lo) && flex`b <= $v(hi)) {
                        goto $v(nx)
                    }
                }
            }
        }
        let acc = t.accept[s]
        var lab_s : ExpressionPtr = new ExprLabel(at = t_at, labelName = s)
        out |> emplace(lab_s)
        if (acc >= 0) {
            out |> push <| qmacro_block() {
                flex`rule = $v(acc)
                flex`len = flex`i - $i(lx).pos
            }
        }
        out |> push <| qmacro_block() {
            if (flex`i >= $i(lx).len) {
                goto $v(done)
            }
            flex`b = int(unsafe($i(lx).data[flex`i]))
            flex`i++
            $b(moves)
            goto $v(done)
        }
    }
    var lab_done : ExpressionPtr = new ExprLabel(at = t_at, labelName = done)
    out |> emplace(lab_done)
    return <- out
}

[function_macro(name="flex")]
class FlexMacro : AstFunctionAnnotation {
    def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool {
        if (length(func.arguments) != 1) {
            errors := "[flex] takes one argument: var lx : FlexLexer"
            return false
        }
        let lx = string(func.arguments[0].name)
        var mode = "table"
        let argMode = find_arg(args, "mode")
        if (argMode is tString) {
            mode = argMode as tString
        }
        if (mode != "table" && mode != "goto") {
            errors := "[flex] mode is table or goto, not {mode}"
            return false
        }
        var spec : FlexSpec
        var body = func.body as ExprBlock
        collect_conditions(spec, body)
        if (empty(spec.err)) {
            collect_rules(spec, body)
        }
        if (!empty(spec.err)) {
            errors := spec.err
            return false
        }
        if (empty(spec.rules)) {
            errors := "[flex] body has no rules"
            return false
        }
        let t <- flex_tables(spec.rules, length(spec.cond_names))
        if (!empty(t.err)) {
            errors := t.err
            return false
        }
        let g_next = "{func.name}`flex`next"
        let g_accept = "{func.name}`flex`accept"
        let g_class = "{func.name}`flex`class"
        let g_start = "{func.name}`flex`start"
        return false if (!int_table_global(g_start, t.start, func.at, errors))
        if (mode == "table") {
            return false if (!int_table_global(g_next, t.next, func.at, errors))
            return false if (!int_table_global(g_accept, t.accept, func.at, errors))
            return false if (!int_table_global(g_class, t.class_of, func.at, errors))
        }
        var arms <- make_arms(spec, "flex`rule")
        let nclasses = t.nclasses
        var newBody : ExpressionPtr
        if (mode == "table") {
            newBody = qmacro_block() {
                while (true) {
                    return false if ($i(lx).pos >= $i(lx).len)
                    var flex`len = 0
                    let flex`rule = flex_match_table($i(lx), $i(g_next), $i(g_accept), $i(g_class), $v(nclasses),
                                                      $i(g_start)[$i(lx).cond], flex`len)
                    if (flex`rule < 0 || flex`len == 0) {
                        $i(lx).failed = true
                        $i(lx).err = flex_error_text($i(lx))
                        return false
                    }
                    flex_consume($i(lx), $i(lx).pos, flex`len)
                    $i(lx).emitted = false
                    $b(arms)
                    return true if ($i(lx).emitted)
                }
            }
        } else {
            var matcher <- make_goto_matcher(t, lx, "flex`start", func.at)
            newBody = qmacro_block() {
                while (true) {
                    return false if ($i(lx).pos >= $i(lx).len)
                    var flex`len = 0
                    var flex`rule = -1
                    var flex`i = $i(lx).pos
                    var flex`b = 0
                    let flex`start = $i(g_start)[$i(lx).cond]
                    $b(matcher)
                    if (flex`rule < 0 || flex`len == 0) {
                        $i(lx).failed = true
                        $i(lx).err = flex_error_text($i(lx))
                        return false
                    }
                    flex_consume($i(lx), $i(lx).pos, flex`len)
                    $i(lx).emitted = false
                    $b(arms)
                    return true if ($i(lx).emitted)
                }
            }
        }
        func.body = newBody
        return true
    }
}
