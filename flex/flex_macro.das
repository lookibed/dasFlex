options gen2
options indenting = 4
options strict_smart_pointers = true
options no_unused_block_arguments = false
options no_unused_function_arguments = false

module flex_macro shared public

require daslib/ast_boost
require daslib/templates_boost
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
    func_name : string
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
        if (expr.name == "begin" && length(expr.arguments) == 2
            && expr.arguments[1] is ExprConstString) {
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

def private collect_rule(var spec : FlexSpec; call : ExprCall?; conds : array<int>;
                         var rw : BeginRewrite?) {
    if (length(call.arguments) != 2 || !(call.arguments[0] is ExprConstString)
        || !(call.arguments[1] is ExprMakeBlock)) {
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
            if (length(call.arguments) != 3 || !(call.arguments[0] is ExprConstString)
                || !(call.arguments[1] is ExprVar) || !(call.arguments[2] is ExprMakeBlock)) {
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
    defer() {
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
            var inscope own : array<int>
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

//! the control flow the macro emits is marked generated, so a complexity lint counts the user's rule
//! bodies and not the scanner skeleton; a block from `qmacro_block` is walked one level down
def private mark_generated(var e : ExpressionPtr) {
    if (e is ExprBlock) {
        for (st in (e as ExprBlock).list) {
            mark_generated(st)
        }
    } elif (e is ExprIfThenElse || e is ExprWhile || e is ExprFor) {
        e.genFlags.generated = true
    }
}

def private int_table_global(name : string; vals : array<int>; at : LineInfo;
                             var errors : das_string) : bool {
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

//! the dispatch after a match, in one of three shapes: a chain of `if (rule == i)`, a computed
//! `goto` into a label per rule (labels `base .. base + nrules`), or a binary tree of `if (rule < m)`
def private make_arms(spec : FlexSpec; rule_var, dispatch : string; base : int;
                      at : LineInfo) : array<ExpressionPtr> {
    var arms : array<ExpressionPtr>
    if (dispatch == "goto") {
        arms |> reserve(length(spec.arms) * 3 + 2)
        arms |> push <| qmacro_block() {
            goto $i(rule_var) + $v(base)
        }
        let done = base + length(spec.arms)
        for (arm in spec.arms) {
            var lab : ExpressionPtr = new ExprLabel(at = at, labelName = base + arm.rule)
            arms |> emplace(lab)
            for (s in arm.body) {
                arms |> push(clone_expression(s))
            }
            var jump : ExpressionPtr = new ExprGoto(at = at, labelName = done)
            arms |> emplace(jump)
        }
        var lab_done : ExpressionPtr = new ExprLabel(at = at, labelName = done)
        arms |> emplace(lab_done)
        for (e in arms) {
            mark_generated(e)
        }
    } elif (dispatch == "tree") {
        arms |> push(make_arm_tree(spec, rule_var, 0, length(spec.arms)))
    } else {
        arms |> reserve(length(spec.arms))
        for (arm in spec.arms) {
            arms |> push(make_arm_if(spec, rule_var, arm.rule))
        }
    }
    return <- arms
}

def private make_arm_if(spec : FlexSpec; rule_var : string; rule : int) : ExpressionPtr {
    var wrapper = qmacro_block() {
        if ($i(rule_var) == $v(rule)) {
        }
    }
    mark_generated(wrapper)
    var ifte = (wrapper as ExprBlock).list[0] as ExprIfThenElse
    var then_blk = ifte.if_true as ExprBlock
    for (s in spec.arms[rule].body) {
        then_blk.list |> push(clone_expression(s))
    }
    return wrapper
}

//! rules `lo .. hi-1` as a balanced tree of `if (rule < mid)`; a leaf is the rule's body
def private make_arm_tree(spec : FlexSpec; rule_var : string; lo, hi : int) : ExpressionPtr {
    if (hi - lo == 1) {
        var leaf = qmacro_block() {
        }
        var blk = leaf as ExprBlock
        for (s in spec.arms[lo].body) {
            blk.list |> push(clone_expression(s))
        }
        return leaf
    }
    let mid = (lo + hi) / 2
    var node = qmacro_block() {
        if ($i(rule_var) < $v(mid)) {
        } else {
        }
    }
    mark_generated(node)
    var ifte = (node as ExprBlock).list[0] as ExprIfThenElse
    (ifte.if_true as ExprBlock).list |> push(make_arm_tree(spec, rule_var, lo, mid))
    (ifte.if_false as ExprBlock).list |> push(make_arm_tree(spec, rule_var, mid, hi))
    return node
}

//! the DFA as straight-line code: `label s:` reads a byte, picks the next state by class ranges, jumps
def private make_goto_matcher(t : FlexTables; lx : string; cond_start : string;
                              t_at : LineInfo) : array<ExpressionPtr> {
    var out : array<ExpressionPtr>
    out |> reserve(t.nstates * 3 + 2)
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
    var moves : array<ExpressionPtr>
    moves |> reserve(t.nclasses)
    for (s in range(t.nstates)) {
        moves |> clear()
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
                    if (flex`b >= $v(lo) && flex`b <= $v(hi)) {  // nolint:PERF014,LINT019 - any byte range, not digits
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
    for (e in out) {
        mark_generated(e)
    }
    return <- out
}

//! the generated function body: match (by tables or by straight-line code), consume, dispatch on the rule
def private make_scanner_body(spec : FlexSpec; t : FlexTables; lx, mode, dispatch : string;
                              at : LineInfo) : ExpressionPtr {
    let g_next = "{spec.func_name}`flex`next"
    let g_accept = "{spec.func_name}`flex`accept"
    let g_class = "{spec.func_name}`flex`class"
    let g_start = "{spec.func_name}`flex`start"
    let base = mode == "goto" ? t.nstates + 1 : 0
    var arms <- make_arms(spec, "flex`rule", dispatch, base, at)
    let nclasses = t.nclasses
    var newBody : ExpressionPtr
    if (mode == "table") {
        newBody = qmacro_block() {
            while (true) {
                return false if ($i(lx).pos >= $i(lx).len)
                var flex`len = 0
                let flex`rule = flex_match_table($i(lx), $i(g_next), $i(g_accept), $i(g_class),
                                                 $v(nclasses),
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
        var matcher <- make_goto_matcher(t, lx, "flex`start", at)
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
    // the loop and its guards are generated; the user's rule bodies inside the arms are not
    var top = (newBody as ExprBlock).list[0]
    top.genFlags.generated = true
    var loop_body = (top as ExprWhile).body as ExprBlock
    for (st in loop_body.list) {
        mark_generated(st)
    }
    return newBody
}

[function_macro(name="flex")]
class FlexMacro : AstFunctionAnnotation {
    def override apply(var func : FunctionPtr; var group : ModuleGroup;
                       var args : AnnotationArgumentList; var errors : das_string) : bool {
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
        var dispatch = "if"
        let argDispatch = find_arg(args, "dispatch")
        if (argDispatch is tString) {
            dispatch = argDispatch as tString
        }
        if (dispatch != "if" && dispatch != "goto" && dispatch != "tree") {
            errors := "[flex] dispatch is if, goto or tree, not {dispatch}"
            return false
        }
        var spec : FlexSpec
        spec.func_name = string(func.name)
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
            return false if (!int_table_global(g_next, t.next, func.at, errors)
                || !int_table_global(g_accept, t.accept, func.at, errors)
                || !int_table_global(g_class, t.class_of, func.at, errors))
        }
        func.body = make_scanner_body(spec, t, lx, mode, dispatch, func.at)
        return true
    }
}
