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
// `[flex(mode="goto")]` emits the DFA as labelled straight-line code instead of reading the tables;
// `matcher` picks the table-mode match (`inline` by default, `call`), `dispatch` the way the matched
// rule reaches its body (`goto` by default, `if`, `tree`).

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

//! `begin(lx, "NAME")` in a rule body becomes `begin(lx, <index>)`; `emit(lx, kind)` becomes the two
//! field writes it stands for, so a rule body makes no call for its one-line action
class private BeginRewrite : AstVisitor {
    cond_names : array<string>
    err : string
    def override visitExprCall(var expr : ExprCall?) : ExpressionPtr {
        if (expr.name == "emit" && length(expr.arguments) == 2) {
            var inlined = qmacro_block() {
                $e(expr.arguments[0]).tok.kind = int($e(expr.arguments[1]))  // nolint:PERF020,LINT019 - an enum or an int kind
                $e(expr.arguments[0]).emitted = true
            }
            mark_generated(inlined)
            return inlined
        }
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

//! the states some path from a start state reaches through a `\n` transition; only they can hold a
//! newline count other than zero when they accept
def private after_newline_states(t : FlexTables) : array<bool> {
    var seen : array<bool>
    seen |> resize(t.nstates)
    var work : array<int>
    let nl_class = t.class_of[10]
    for (s in range(t.nstates)) {
        let nx = t.next[s * t.nclasses + nl_class]
        if (nx >= 0 && !seen[nx]) {
            seen[nx] = true
            work |> push(nx)
        }
    }
    while (!empty(work)) {
        let s = work |> back()
        work |> pop()
        for (c in range(t.nclasses)) {
            let nx = t.next[s * t.nclasses + c]
            if (nx >= 0 && !seen[nx]) {
                seen[nx] = true
                work |> push(nx)
            }
        }
    }
    return <- seen
}

//! the moves out of state `s`, one byte-range test per class; the `\n` move also counts the newline
def private make_goto_moves(t : FlexTables; s : int;
                            lo_of, hi_of : array<int>) : array<ExpressionPtr> {
    var moves : array<ExpressionPtr>
    let nl_class = t.class_of[10]
    for (c in range(t.nclasses)) {
        let nx = t.next[s * t.nclasses + c]
        continue if (nx < 0)
        let lo = lo_of[c]
        let hi = hi_of[c]
        if (c == nl_class) {
            moves |> push <| qmacro_block() {
                if (flex`b == 10) {
                    flex`nl_run++
                    flex`nl_run_last = flex`i
                    goto $v(nx)
                }
            }
        } elif (lo == hi) {
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
    return <- moves
}

//! the DFA as straight-line code: `label s:` reads a byte, picks the next state by class ranges, jumps;
//! an accepting state records the rule, the length and the newlines read so far
def private make_goto_matcher(t : FlexTables; lx : string; cond_start : string;
                              t_at : LineInfo) : array<ExpressionPtr> {
    var out : array<ExpressionPtr>
    out |> reserve(t.nstates * 3 + 4)
    let done = t.nstates
    // a class is a run of bytes; its ends let the code test a byte without reading `class_of`
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
    let after_nl <- after_newline_states(t)
    out |> push <| qmacro_block() {
        goto $i(cond_start)
    }
    for (s in range(t.nstates)) {
        var moves <- make_goto_moves(t, s, lo_of, hi_of)
        let acc = t.accept[s]
        var lab_s : ExpressionPtr = new ExprLabel(at = t_at, labelName = s)
        out |> emplace(lab_s)
        if (acc >= 0) {
            out |> push <| qmacro_block() {
                flex`rule = $v(acc)
                flex`len = flex`i - $i(lx).pos
            }
            if (after_nl[s]) {
                out |> push <| qmacro_block() {
                    flex`nl = flex`nl_run
                    flex`nl_last = flex`nl_run_last
                }
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

//! one table in place of `next` and `accept`: `next * 256 + accept(next) + 1`, `-1` for no move
def private merged_table(t : FlexTables) : array<int> {
    var m : array<int>
    m |> resize(length(t.next))
    for (i, nx in count(), t.next) {
        m[i] = nx < 0 ? -1 : nx * 256 + t.accept[nx] + 1
    }
    return <- m
}

//! the inline matcher: the byte loop in the scanner's own module over one merged table and raw
//! pointers, newlines counted on the way (`\n` is a class of its own, one compare per byte)
def private make_inline_matcher(lx, g_merged, g_class, g_start : string;
                                nclasses, nl_class : int) : array<ExpressionPtr> {
    return <- qmacro_block_to_array() {
        unsafe {
            let flex`data = $i(lx).data
            let flex`tbl = addr($i(g_merged)[0])
            let flex`cls = addr($i(g_class)[0])
            var flex`state = $i(g_start)[$i(lx).cond]
            var flex`i = $i(lx).pos
            let flex`n = $i(lx).len
            var flex`nl_run = 0
            var flex`nl_run_last = 0
            while (flex`i < flex`n) {
                let flex`c = flex`cls[int(flex`data[flex`i])]
                let flex`e = flex`tbl[flex`state * $v(nclasses) + flex`c]
                break if (flex`e < 0)
                flex`i++
                if (flex`c == $v(nl_class)) {
                    flex`nl_run++
                    flex`nl_run_last = flex`i
                }
                flex`state = flex`e >> 8
                let flex`acc = (flex`e & 255) - 1
                if (flex`acc >= 0) {
                    flex`rule = flex`acc
                    flex`len = flex`i - $i(lx).pos
                    flex`nl = flex`nl_run
                    flex`nl_last = flex`nl_run_last
                }
            }
        }
    }
}

//! the token is the matched span; line and column move by the newlines the matcher counted on the way
//! (`nl` of them, the last one ending at `nl_last`), so no byte of the token is read twice
def private make_token_set(lx : string) : array<ExpressionPtr> {
    return <- qmacro_block_to_array() {
        $i(lx).tok.start = $i(lx).pos
        $i(lx).tok.len = flex`len
        $i(lx).tok.text = ""
        $i(lx).tok.line = $i(lx).line
        $i(lx).tok.col = $i(lx).col
        if (flex`nl > 0) {
            $i(lx).line += flex`nl
            $i(lx).col = $i(lx).pos + flex`len - flex`nl_last + 1
        } else {
            $i(lx).col += flex`len
        }
        $i(lx).pos += flex`len
    }
}

//! the match in one of three shapes: the inline byte loop, a call to `flex_match_table`, or the DFA
//! as labelled straight-line code; each leaves the rule and the length in `rule` and `len`
def private make_match(spec : FlexSpec; t : FlexTables; lx, mode, matcher : string;
                       at : LineInfo) : array<ExpressionPtr> {
    let g_class = "{spec.func_name}`flex`class"
    let g_start = "{spec.func_name}`flex`start"
    if (mode == "table" && matcher == "inline") {
        return <- make_inline_matcher(lx, "{spec.func_name}`flex`merged", g_class, g_start,
                                      t.nclasses, t.class_of[10])
    } elif (mode == "table") {
        let g_next = "{spec.func_name}`flex`next"
        let g_accept = "{spec.func_name}`flex`accept"
        let nclasses = t.nclasses
        return <- qmacro_block_to_array() {
            flex`rule = flex_match_table($i(lx), $i(g_next), $i(g_accept), $i(g_class),
                                         $v(nclasses),
                                         $i(g_start)[$i(lx).cond], flex`len)
        }
    }
    var states <- make_goto_matcher(t, lx, "flex`start", at)
    return <- qmacro_block_to_array() {
        var flex`i = $i(lx).pos
        var flex`b = 0
        var flex`nl_run = 0
        var flex`nl_run_last = 0
        let flex`start = $i(g_start)[$i(lx).cond]
        $b(states)
    }
}

//! taking the matched span as the token: from the newlines the inline and goto matchers counted, or
//! by `flex_consume` after a call to `flex_match_table`
def private make_take(lx, mode, matcher : string) : array<ExpressionPtr> {
    if (mode == "goto" || matcher == "inline") {
        return <- make_token_set(lx)
    }
    return <- qmacro_block_to_array() {
        flex_consume($i(lx), $i(lx).pos, flex`len)
    }
}

//! the generated function body: match, take the token, dispatch on the rule; the loop and its guards
//! are generated, the user's rule bodies inside the arms are not
def private make_scanner_body(spec : FlexSpec; t : FlexTables; lx, mode, dispatch, matcher : string;
                              at : LineInfo) : ExpressionPtr {
    let base = mode == "goto" ? t.nstates + 1 : 0
    var arms <- make_arms(spec, "flex`rule", dispatch, base, at)
    var match <- make_match(spec, t, lx, mode, matcher, at)
    var take <- make_take(lx, mode, matcher)
    var newBody = qmacro_block() {
        while (true) {
            return false if ($i(lx).pos >= $i(lx).len)
            var flex`len = 0
            var flex`rule = -1
            var flex`nl = 0
            var flex`nl_last = 0
            $b(match)
            if (flex`rule < 0 || flex`len == 0) {
                $i(lx).failed = true
                $i(lx).err = flex_error_text($i(lx))
                return false
            }
            $b(take)
            $i(lx).emitted = false
            $b(arms)
            return true if ($i(lx).emitted)
        }
    }
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
        var dispatch = "goto"
        let argDispatch = find_arg(args, "dispatch")
        if (argDispatch is tString) {
            dispatch = argDispatch as tString
        }
        if (dispatch != "if" && dispatch != "goto" && dispatch != "tree") {
            errors := "[flex] dispatch is if, goto or tree, not {dispatch}"
            return false
        }
        var matcher = "inline"
        let argMatcher = find_arg(args, "matcher")
        if (argMatcher is tString) {
            matcher = argMatcher as tString
        }
        if (matcher != "call" && matcher != "inline") {
            errors := "[flex] matcher is call or inline, not {matcher}"
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
        if (matcher == "inline" && length(spec.rules) > 254) {
            errors := "[flex] matcher = inline carries at most 254 rules in its merged table"
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
        let g_merged = "{func.name}`flex`merged"
        return false if (!int_table_global(g_start, t.start, func.at, errors))
        if (mode == "table" && matcher == "inline") {
            return false if (!int_table_global(g_merged, merged_table(t), func.at, errors)
                || !int_table_global(g_class, t.class_of, func.at, errors))
        } elif (mode == "table") {
            return false if (!int_table_global(g_next, t.next, func.at, errors)
                || !int_table_global(g_accept, t.accept, func.at, errors)
                || !int_table_global(g_class, t.class_of, func.at, errors))
        }
        func.body = make_scanner_body(spec, t, lx, mode, dispatch, matcher, func.at)
        return true
    }
}
