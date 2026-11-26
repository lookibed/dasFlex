options gen2
options indenting = 4
options strict_smart_pointers = true
options no_unused_block_arguments = false
options no_unused_function_arguments = false

module flex_macro shared public

require daslib/ast_boost
require daslib/templates_boost
require daslib/defer
require daslib/strings_boost
require daslib/regex
require math

require flex/flex_regex
require flex/flex_dfa
require flex/flex public
require flex/flex_reader public

// `[flex]` on `def name(var lx : FlexLexer) : bool { rule("re") { ... } condition("C", exclusive) { ... } }`
// builds the DFA of every rule at compile time, stores its tables as private module globals and
// rewrites the function into the scanner: it returns true with `lx.tok` set when a rule called `emit`,
// false at the end of input or on a byte no rule accepts (`lx.failed`, `lx.err`). Rule bodies run
// in the function's own scope, so `lx` is the function's parameter under whatever name it carries.
// `[flex(mode="goto")]` emits the DFA as labelled straight-line code instead of reading the tables;
// `matcher` picks the table-mode match (`inline` by default, `call`), `dispatch` the way the matched
// rule reaches its body (`goto` by default in table mode, `if` in goto mode, `tree`).

struct private FlexArm {
    rule : int
    site : Expression const?          //!< the rule call, for an error at its line
    body : array<ExpressionPtr>
    group_re : string                 //!< the global of the rule's group regex; "" when no `group` call
}

struct private FlexSpec {
    func_name : string
    rules : array<FlexRule>
    arms : array<FlexArm>
    cond_names : array<string>
    inclusive : array<bool>
    err : string
    err_site : Expression const?
    flag_read : string                //!< the first token flag a rule body reads
    flag_site : Expression const?
}

//! `begin(lx, "NAME")` in a rule body becomes `begin(lx, <index>)`; `emit(lx, kind)` becomes the two
//! field writes it stands for, so a rule body makes no call for its one-line action;
//! `group(lx, n)` and `group_span(lx, n)` become calls on the rule's group regex `group_re`. Only a
//! call whose first argument is the lexer parameter `lx` is rewritten. With `implicit_lexer` (the
//! `%flex~` reader), `emit(kind)`, `begin(NAME)` and `group(n)` name the lexer implicitly, and a
//! bare name in `emit` is a member of the enum `tokens`
[arch(at="../ARCHITECTURE.md#rule-bodies")]
class private ActionRewrite : AstVisitor {
    cond_names : array<string>
    lx : string
    implicit_lexer : bool
    tokens : string
    err : string
    err_site : Expression const?
    group_re : string
    uses_groups : bool
    group_max : int                 //!< the highest constant group index the rule asks for
    flag_read : string              //!< the first `lx.tok.has_space` or `lx.tok.at_bol` a rule body reads
    flag_site : Expression const?
    def override visitExprField(var expr : ExprField?) : ExpressionPtr {
        if (empty(flag_read) && (expr.name == "has_space" || expr.name == "at_bol") && expr.value is ExprField) {
            let tok = expr.value as ExprField
            if (tok.name == "tok" && is_lexer(tok.value)) {
                flag_read = string(expr.name)
                flag_site = expr
            }
        }
        return <- expr
    }
    def override visitExprCall(var expr : ExprCall?) : ExpressionPtr {
        let is_group = expr.name == "group" || expr.name == "group_span"
        if (implicit_lexer && length(expr.arguments) == 1) {
            if (expr.name == "emit" || expr.name == "begin") {
                add_implicit_lexer(expr)
            } elif (is_group) {
                var index = expr.arguments[0]
                var lexer : ExpressionPtr = new ExprVar(at = expr.at, name := lx)
                expr.arguments |> clear()
                expr.arguments |> emplace(lexer)
                expr.arguments |> emplace(index)
            }
        }
        return <- expr if (length(expr.arguments) != 2 || !is_lexer(expr.arguments[0]))
        if (is_group) {
            return group_call(expr)
        }
        if (expr.name == "emit") {
            var inlined = qmacro_block() {
                static_if (typeinfo stripped_typename($e(expr.arguments[1])) == "int") {
                    $e(expr.arguments[0]).tok.kind = $e(expr.arguments[1])
                } else {
                    $e(expr.arguments[0]).tok.kind = int($e(expr.arguments[1]))
                }
                $e(expr.arguments[0]).emitted = true
            }
            mark_generated(inlined)
            inlined |> force_at(expr.at)
            return inlined
        }
        if (expr.name == "begin" && expr.arguments[1] is ExprConstString) {
            let cname = string((expr.arguments[1] as ExprConstString).value)
            let idx = find_index(cond_names, cname)
            if (idx < 0) {
                if (empty(err)) {
                    err = "begin(\"{cname}\"): no such start condition"
                    err_site = expr
                }
            } else {
                expr.arguments[1] = new ExprConstInt(at = expr.at, value = idx)
            }
        }
        return <- expr
    }
    def is_lexer(e : ExpressionPtr) : bool => e is ExprVar && (e as ExprVar).name == lx

    //! `group(lx, n)` becomes `flex_group(lx, <the rule's regex>, n)`, `group_span` likewise
    def group_call(var expr : ExprCall?) : ExpressionPtr {
        uses_groups = true
        if (expr.arguments[1] is ExprConstInt) {
            group_max = max(group_max, (expr.arguments[1] as ExprConstInt).value)
        }
        let fname = expr.name == "group" ? "flex_group" : "flex_group_span"
        var call = qmacro($c(fname)($e(expr.arguments[0]), $i(group_re), $e(expr.arguments[1])))
        call |> force_at(expr.at)
        return call
    }
    //! `emit(kind)` becomes `emit(lx, kind)`, `emit(NAME)` `emit(lx, tokens.NAME)`, `begin(NAME)`
    //! `begin(lx, "NAME")`
    def add_implicit_lexer(var expr : ExprCall?) {
        var arg = expr.arguments[0]
        if (arg is ExprVar) {
            let name = string((arg as ExprVar).name)
            if (expr.name == "begin") {
                arg = new ExprConstString(at = arg.at, value := name)
            } elif (!empty(tokens)) {
                arg = new ExprField(at = arg.at, name := name,
                                    value = new ExprVar(at = arg.at, name := tokens))
            }
        }
        var lexer : ExpressionPtr = new ExprVar(at = expr.at, name := lx)
        expr.arguments |> clear()
        expr.arguments |> emplace(lexer)
        expr.arguments |> emplace(arg)
    }
}

//! a failure the compile reports at the rule (or the call) it belongs to; the first one wins
def private fail_at(var spec : FlexSpec; msg : string; site : Expression const?) {
    if (empty(spec.err)) {
        spec.err = msg
        spec.err_site = site
    }
}

//! a rule whose body calls `group` needs a capture group in its regex, and every constant index
//! asked for; a regex that does not parse is left to `flex_tables`, which names it
def private check_groups(var spec : FlexSpec; pattern : string; group_max : int;
                         site : Expression const?) {
    var re : Regex
    return if (!regex_compile(re, flex_group_pattern(flex_codepoints(pattern).text)))
    let ngroups = length(re.groups) - 1
    if (ngroups == 0) {
        fail_at(spec, "rule(\"{pattern}\"): group() asks for a capture group, the regex has none",
                site)
    } elif (group_max > ngroups) {
        fail_at(spec, "rule(\"{pattern}\"): group({group_max}) asks for a group the regex does not have ({ngroups})", site)
    }
}

//! `rule("regex", ...) { body }` with `nargs` arguments, the block last: the rule active in `conds`
def private collect_rule(var spec : FlexSpec; call : ExprCall?; nargs : int; conds : array<int>;
                         var rw : ActionRewrite?) {
    if (length(call.arguments) != nargs || !(call.arguments[0] is ExprConstString)
        || !(call.arguments[nargs - 1] is ExprMakeBlock)) {
        fail_at(spec, "rule(\"regex\") \{ ... \} expected", call)
        return
    }
    var r : FlexRule
    r.pattern = string((call.arguments[0] as ExprConstString).value)
    r.conditions := conds
    var arm = FlexArm(rule = length(spec.rules), site = call)
    let blk = call.arguments[nargs - 1] |> unquote_block
    if (!empty(blk.arguments)) {
        fail_at(spec, "a rule block takes no arguments: the lexer is the function's parameter",
                call)
        return
    }
    rw.group_re = "{spec.func_name}`flex`re`{arm.rule}"
    rw.uses_groups = false
    rw.group_max = 0
    for (s in blk.list) {
        var copy = clone_expression(s)
        make_visitor(*rw) $(adapter) {
            visit_expression(copy, adapter)
        }
        arm.body |> emplace(copy)
    }
    if (!empty(rw.err)) {
        fail_at(spec, rw.err, rw.err_site)
    }
    if (empty(spec.flag_read) && !empty(rw.flag_read)) {
        spec.flag_read = rw.flag_read
        spec.flag_site = rw.flag_site
    }
    if (rw.uses_groups) {
        check_groups(spec, r.pattern, rw.group_max, call)
        arm.group_re = rw.group_re
    }
    spec.rules |> emplace(r)
    spec.arms |> emplace(arm)
}

//! first pass: the condition names, so a `begin` may name a condition declared below it; a name
//! declared twice, `INITIAL` included, fails at the second declaration
def private collect_conditions(var spec : FlexSpec; body : ExprBlock?) {
    spec.cond_names |> push("INITIAL")
    spec.inclusive |> push(false)
    for (st in body.list) {
        if (st is ExprCall && (st as ExprCall).name == "condition") {
            let call = st as ExprCall
            if (length(call.arguments) != 3 || !(call.arguments[0] is ExprConstString)
                || !(call.arguments[1] is ExprVar) || !(call.arguments[2] is ExprMakeBlock)) {
                fail_at(spec, "condition(\"NAME\", exclusive|inclusive) \{ rules \} expected", call)
                return
            }
            let kind = string((call.arguments[1] as ExprVar).name)
            if (kind != "exclusive" && kind != "inclusive") {
                fail_at(spec, "condition kind is exclusive or inclusive, not {kind}", call)
                return
            }
            let name = string((call.arguments[0] as ExprConstString).value)
            if (find_index(spec.cond_names, name) >= 0) {
                fail_at(spec, "condition(\"{name}\"): {duplicate_condition(name)}", call)
                return
            }
            spec.cond_names |> push(name)
            spec.inclusive |> push(kind == "inclusive")
        }
    }
}

//! the conditions a rule with no condition of its own is active in: INITIAL and every inclusive one
def private top_conditions(spec : FlexSpec) : array<int> {
    var top_conds : array<int>
    top_conds |> push(0)
    for (i, inc in count(), spec.inclusive) {
        if (inc) {
            top_conds |> push(i)
        }
    }
    return <- top_conds
}

//! every statement of `body` to `each` as a call, with the rewriter of the rule bodies (`lx` named
//! implicitly when `implicit_lexer`), until a failure; a statement that is not a call fails with
//! `not_call`
def private collect_calls(var spec : FlexSpec; body : ExprBlock?; lx, tokens : string;
                          implicit_lexer : bool; not_call : string;
                          each : block<(var rw : ActionRewrite?; call : ExprCall?) : void>) {
    var rw = new ActionRewrite(cond_names := spec.cond_names, lx = lx,
                               implicit_lexer = implicit_lexer,
                               tokens = tokens)
    defer() {
        unsafe {
            delete rw
        }
    }
    for (st in body.list) {
        return if (!empty(spec.err))
        if (!(st is ExprCall)) {
            fail_at(spec, not_call, st)
            return
        }
        invoke(each, rw, st as ExprCall)
    }
}

def private collect_rules(var spec : FlexSpec; body : ExprBlock?; lx : string) {
    let top_conds <- top_conditions(spec)
    var cond_no = 0
    let not_call = "only rule(...) and condition(...) calls belong in a [flex] body"
    collect_calls(spec, body, lx, "", false, not_call) $(var rw; call) {
        if (call.name == "rule") {
            collect_rule(spec, call, 2, top_conds, rw)
        } elif (call.name == "condition") {
            cond_no++
            var inscope own : array<int>
            own |> push(cond_no)
            let cblk = call.arguments[2] |> unquote_block
            for (cs in cblk.list) {
                return if (!empty(spec.err))
                if (!(cs is ExprCall) || (cs as ExprCall).name != "rule") {
                    fail_at(spec, "only rule(...) calls belong in a condition block", cs)
                    return
                }
                collect_rule(spec, cs as ExprCall, 2, own, rw)
            }
        } else {
            fail_at(spec, "only rule(...) and condition(...) calls belong in a [flex] body, not {call.name}", call)
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

//! the private global `name` initialized as `to_array_move([vals...])`
def private int_table_global(name : string; vals : array<int>; at : LineInfo;
                             var errors : das_string) : bool {
    var init = convert_to_expression(vals, at)
    if (!(compiling_module() |> add_global_private_var(name, at, init))) {
        errors := "can't add the global {name}"
        return false
    }
    return true
}

//! the private global holding a rule's group regex, compiled when the module's globals initialize
def private regex_global(name, pattern : string; at : LineInfo; var errors : das_string) : bool {
    var init = new ExprCall(at = at, name := "flex_group_regex")
    init.arguments |> emplace_new <| new ExprConstString(at = at, value := pattern)
    var vvar <- new Variable(at = at, name := name, init = init,
                             _type = new TypeDecl(at = at, baseType = Type.autoinfer,
                                                  flags = TypeDeclFlags.removeConstant))
    vvar.flags.generated = true
    vvar.flags.private_variable = true
    vvar.flags.init_via_move = true
    if (!(compiling_module() |> add_variable(vvar))) {
        errors := "can't add the global {name}"
        return false
    }
    return true
}

//! the dispatch after a match, in one of three shapes: a chain of `if (rule == i)`, a computed
//! `goto` into a label per rule (labels `base .. base + nrules`), or a binary tree of `if (rule < m)`
[arch(at="../ARCHITECTURE.md#rule-bodies")]
def private make_arms(spec : FlexSpec; rule_var, dispatch : string; base : int;
                      at : LineInfo) : array<ExpressionPtr> {
    var arms : array<ExpressionPtr>
    if (dispatch == "goto") {
        arms |> reserve(length(spec.arms) * 3 + 2)
        arms |> push <| qmacro_block() {
            goto $i(rule_var) + $v(base)
        }
        mark_generated(arms[0])
        let done = base + length(spec.arms)
        for (arm in spec.arms) {
            var lab : ExpressionPtr = new ExprLabel(at = at, labelName = base + arm.rule)
            arms |> emplace(lab)
            arms |> push(arm_block(spec, arm.rule))
            var jump : ExpressionPtr = new ExprGoto(at = at, labelName = done)
            arms |> emplace(jump)
        }
        var lab_done : ExpressionPtr = new ExprLabel(at = at, labelName = done)
        arms |> emplace(lab_done)
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

//! the body of rule `rule` as a block of its own
def private arm_block(spec : FlexSpec; rule : int) : ExpressionPtr {
    var blk = qmacro_block() {
    }
    for (s in spec.arms[rule].body) {
        (blk as ExprBlock).list |> push(clone_expression(s))
    }
    return blk
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
    return arm_block(spec, lo) if (hi - lo == 1)
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
def private make_goto_moves(t : FlexTables; s : int; bounds : ClassBounds) : array<ExpressionPtr> {
    var moves : array<ExpressionPtr>
    let nl_class = t.class_of[10]
    for (c in range(t.nclasses)) {
        let nx = t.next[s * t.nclasses + c]
        continue if (nx < 0)
        let lo = bounds.lo[c]
        let hi = bounds.hi[c]
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
    let bounds <- class_bounds(t)
    let after_nl <- after_newline_states(t)
    out |> push <| qmacro_block() {
        goto $i(cond_start)
    }
    for (s in range(t.nstates)) {
        var moves <- make_goto_moves(t, s, bounds)
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
        $i(lx).tok.sym = -1
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

//! the names of the private globals that hold one scanner's tables
struct private TableGlobals {
    next : string
    accept : string
    class_of : string
    start : string
    merged : string
}

def private table_globals(func_name : string) : TableGlobals {
    return TableGlobals(next = "{func_name}`flex`next", accept = "{func_name}`flex`accept",
                        class_of = "{func_name}`flex`class", start = "{func_name}`flex`start",
                        merged = "{func_name}`flex`merged")
}

//! the match in one of three shapes: the inline byte loop, a call to `flex_match_table`, or the DFA
//! as labelled straight-line code; each leaves the rule and the length in `rule` and `len`
def private make_match(g : TableGlobals; t : FlexTables; lx, mode, matcher : string;
                       at : LineInfo) : array<ExpressionPtr> {
    let g_class = g.class_of
    let g_start = g.start
    if (mode == "table" && matcher == "inline") {
        return <- make_inline_matcher(lx, g.merged, g_class, g_start, t.nclasses, t.class_of[10])
    } elif (mode == "table") {
        let g_next = g.next
        let g_accept = g.accept
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

//! where the token handed out ended, kept by a `flags` lexer: the offset, and the line of its last
//! byte, the one before the cursor's when that byte is a newline
[arch(at="../ARCHITECTURE_TOKENS.md#pp-flags")]
def private make_end_store(lx : string) : array<ExpressionPtr> {
    return <- qmacro_block_to_array() {
        $i(lx).prev_end = $i(lx).pos
        $i(lx).prev_end_line = $i(lx).col == 1 ? $i(lx).line - 1 : $i(lx).line
    }
}

//! the end of a rule that emitted: the token is handed out, a `flags` lexer keeping where it ended
def private make_done(lx : string; flags : bool) : array<ExpressionPtr> {
    if (!flags) {
        return <- qmacro_block_to_array() {
            return true if ($i(lx).emitted)
        }
    }
    var stores <- make_end_store(lx)
    return <- qmacro_block_to_array() {
        if ($i(lx).emitted) {
            $b(stores)
            return true
        }
    }
}

//! a rule body's own `return` of a `flags` lexer: one that may return true hands the token out, so it
//! keeps where the token ended first, as `make_done` does; a return inside a block or lambda of the
//! body is that block's
[arch(at="../ARCHITECTURE_TOKENS.md#pp-flags")]
class private ReturnStore : AstVisitor {
    lx : string
    in_block : int
    def override preVisitExprMakeBlock(expr : ExprMakeBlock?) {
        in_block++
    }
    def override visitExprMakeBlock(var expr : ExprMakeBlock?) : ExpressionPtr {
        in_block--
        return <- expr
    }
    def override visitExprReturn(var expr : ExprReturn?) : ExpressionPtr {
        return <- expr if (in_block > 0 || expr.subexpr == null)
        var stores <- make_end_store(lx)
        var handed = qmacro_block() {
            if ($e(expr.subexpr)) {
                $b(stores)
                return true
            }
            return false
        }
        mark_generated(handed)
        handed |> force_at(expr.at)
        return handed
    }
}

//! a `flags` lexer's token flags, written at the head of every rule body that is not empty, so the
//! body reads them; an empty body can neither read them nor emit, and pays nothing
[arch(at="../ARCHITECTURE_TOKENS.md#pp-flags")]
def private add_flag_reads(var spec : FlexSpec; lx : string) {
    for (arm in spec.arms) {
        continue if (empty(arm.body))
        var reads <- qmacro_block_to_array() {
            $i(lx).tok.has_space = $i(lx).tok.start != $i(lx).prev_end
            $i(lx).tok.at_bol = $i(lx).tok.line != $i(lx).prev_end_line
        }
        for (i in range(length(reads))) {
            mark_generated(reads[i])
            arm.body |> emplace(reads[i], i)
        }
    }
}

//! every `return` a `flags` lexer's rule bodies make through `ReturnStore`
def private store_on_return(var spec : FlexSpec; lx : string) {
    var rs = new ReturnStore(lx = lx)
    defer() {
        unsafe {
            delete rs
        }
    }
    make_visitor(*rs) $(adapter) {
        for (arm in spec.arms) {
            for (st in arm.body) {
                visit_expression(st, adapter)
            }
        }
    }
}

//! the generated function body: match, take the token, dispatch on the rule; the loop and its guards
//! are generated, the user's rule bodies inside the arms are not
def private make_scanner_body(spec : FlexSpec; g : TableGlobals; t : FlexTables;
                              lx : string; shape : FlexShape; at : LineInfo) : ExpressionPtr {
    let base = shape.mode == "goto" ? t.nstates + 1 : 0
    var arms <- make_arms(spec, "flex`rule", shape.dispatch, base, at)
    var match <- make_match(g, t, lx, shape.mode, shape.matcher, at)
    var take <- make_take(lx, shape.mode, shape.matcher)
    var done <- make_done(lx, shape.flags)
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
            $b(done)
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

//! the annotation's string argument `name`, or `absent` when the annotation omits it
def private string_arg(args : AnnotationArgumentList; name, absent : string) : string {
    let arg = find_arg(args, name)
    return arg is tString ? arg as tString : absent
}

//! the scanner shape the annotation asks for, the defaults following the tier; `err` names a bad value
struct private FlexShape {
    mode : string
    dispatch : string
    matcher : string
    flags : bool        //!< the tokens carry `has_space` and `at_bol`
    err : string
}

//! an argument `[tag]` does not take, or one given twice: either would leave a choice unmade unseen
def private argument_error(args : AnnotationArgumentList; tag : string) : string {
    var known <- ["mode", "dispatch", "matcher", "flags"]
    if (tag == "flex_text") {
        known |> push_from(["tokens", "conditions"])
    }
    var seen : array<string>
    for (a in args) {
        let name = string(a.name)
        if (!has_value(known, name)) {
            return "[{tag}] unknown argument `{name}`; the arguments are {join(known, ", ")}"
        }
        return "[{tag}] argument `{name}` given twice" if (has_value(seen, name))
        seen |> push(name)
    }
    return ""
}

[arch(at="../ARCHITECTURE.md#two-shapes")]
def private flex_shape(args : AnnotationArgumentList; tag : string) : FlexShape {
    let bad_arg = argument_error(args, tag)
    return FlexShape(err = bad_arg) if (!empty(bad_arg))
    let mode = string_arg(args, "mode", compiling_program().policies.jit_enabled ? "goto" : "table")
    var shape = FlexShape(mode = mode,
                          dispatch = string_arg(args, "dispatch", mode == "table" ? "goto" : "if"),
                          matcher = string_arg(args, "matcher", "inline"))
    let flags = find_arg(args, "flags")
    shape.flags = flags is tBool && flags as tBool
    if (shape.mode != "table" && shape.mode != "goto") {
        shape.err = "[flex] mode is table or goto, not {shape.mode}"
    } elif (shape.dispatch != "if" && shape.dispatch != "goto" && shape.dispatch != "tree") {
        shape.err = "[flex] dispatch is if, goto or tree, not {shape.dispatch}"
    } elif (shape.matcher != "call" && shape.matcher != "inline") {
        shape.err = "[flex] matcher is call or inline, not {shape.matcher}"
    } elif (!(flags is tBool) && !(flags is nothing)) {
        shape.err = "[flex] flags is true or false"
    }
    return shape
}

//! a failure that belongs to one rule is reported at that rule's line; the annotation fails with a
//! pointer to it
def private fail_rule(msg : string; site : Expression const?; var errors : das_string) : bool {
    compiling_program() |> macro_error(site.at, msg)
    errors := "see the error at line {int(site.at.line)}"
    return false
}

//! the one back end of both front ends: the tables of `spec` through `flex_tables`, the private
//! globals, and the scanner body in place of `func`'s
def private flex_generate(var func : FunctionPtr; spec : FlexSpec; shape : FlexShape;
                          var errors : das_string) : bool {
    return fail_rule(spec.err, spec.err_site, errors) if (!empty(spec.err))
    if (empty(spec.rules)) {
        errors := "[flex] body has no rules"
        return false
    }
    if (shape.mode == "table" && shape.matcher == "inline" && length(spec.rules) > 254) {
        errors := "[flex] matcher = inline carries at most 254 rules in its merged table"
        return false
    }
    let t <- flex_tables(spec.rules, length(spec.cond_names))
    return fail_rule(t.err, spec.arms[t.err_rule].site, errors) if (!empty(t.err))
    let lx = string(func.arguments[0].name)
    to_log(LOG_INFO, "[flex] {func.name}: mode {shape.mode} dispatch {shape.dispatch}\n")
    let g = table_globals(spec.func_name)
    return false if (!int_table_global(g.start, t.start, func.at, errors))
    if (shape.mode == "table" && shape.matcher == "inline") {
        return false if (!int_table_global(g.merged, merged_table(t), func.at, errors)
            || !int_table_global(g.class_of, t.class_of, func.at, errors))
    } elif (shape.mode == "table") {
        return false if (!int_table_global(g.next, t.next, func.at, errors)
            || !int_table_global(g.accept, t.accept, func.at, errors)
            || !int_table_global(g.class_of, t.class_of, func.at, errors))
    }
    for (arm in spec.arms) {
        continue if (empty(arm.group_re))
        let pattern = flex_codepoints(spec.rules[arm.rule].pattern).text
        return false if (!regex_global(arm.group_re, pattern, arm.site.at, errors))
    }
    func.body = make_scanner_body(spec, g, t, lx, shape, func.at)
    return true
}

//! what both annotations do around their front end: one lexer argument, a known shape, the spec of
//! `func` filled by `collect` from the lexer parameter's name, then `flex_generate`
def private flex_apply(var func : FunctionPtr; args : AnnotationArgumentList; tag : string;
                       var errors : das_string;
                       collect : block<(var spec : FlexSpec; lx : string) : void>) : bool {
    if (length(func.arguments) != 1) {
        errors := "[{tag}] takes one argument: var lx : FlexLexer"
        return false
    }
    let shape = flex_shape(args, tag)
    if (!empty(shape.err)) {
        errors := shape.err
        return false
    }
    var spec = FlexSpec(func_name = string(func.name))
    let lx = string(func.arguments[0].name)
    invoke(collect, spec, lx)
    if (shape.flags) {
        add_flag_reads(spec, lx)
        store_on_return(spec, lx)
    } elif (!empty(spec.flag_read)) {
        let ask = tag == "flex_text" ? "%option flags" : "flags = true"
        fail_at(spec, "[{tag}] the rule body reads {lx}.tok.{spec.flag_read} but the lexer does not ask for the flags: add {ask}", spec.flag_site)
    }
    return flex_generate(func, spec, shape, errors)
}

[function_macro(name="flex")]
class FlexMacro : AstFunctionAnnotation {
    def override apply(var func : FunctionPtr; var group : ModuleGroup;
                       var args : AnnotationArgumentList; var errors : das_string) : bool {
        let body = func.body as ExprBlock
        return flex_apply(func, args, "flex", errors) $(var spec; lx) {
            collect_conditions(spec, body)
            if (empty(spec.err)) {
                collect_rules(spec, body, lx)
            }
        }
    }
}

//! the start conditions of a `%flex~` reader: `conditions` is `NAME:x NAME:s ...`, exclusive or inclusive
def private text_conditions(var spec : FlexSpec; conditions : string) {
    spec.cond_names |> push("INITIAL")
    spec.inclusive |> push(false)
    for (item in split(conditions, " ")) {
        continue if (empty(item))
        var inscope parts <- split(item, ":")
        spec.cond_names |> push(parts[0])
        spec.inclusive |> push(length(parts) > 1 && parts[1] == "s")
    }
}

//! a reader rule's condition list as indices: "" is INITIAL and the inclusive conditions, `*` all
//! of them, else the names it lists
def private text_rule_conditions(var spec : FlexSpec; names : string;
                                 site : Expression const?) : array<int> {
    if (empty(names)) {
        return <- top_conditions(spec)
    }
    if (names == "*") {
        return <- [for (i in range(length(spec.cond_names))); i]
    }
    var conds : array<int>
    for (name in split(names, ",")) {
        let idx = find_index(spec.cond_names, name)
        if (idx < 0) {
            fail_at(spec, "<{name}>: no such start condition", site)
        } else {
            conds |> push(idx)
        }
    }
    return <- conds
}

def private collect_text_rules(var spec : FlexSpec; body : ExprBlock?; lx, tokens : string) {
    let not_call = "only rule(...) calls belong in a [flex_text] body"
    collect_calls(spec, body, lx, tokens, true, not_call) $(var rw; call) {
        if (call.name != "rule" || length(call.arguments) != 3
            || !(call.arguments[1] is ExprConstString)) {
            fail_at(spec, "rule(\"regex\", \"conditions\") \{ ... \} expected", call)
            return
        }
        let names = string((call.arguments[1] as ExprConstString).value)
        var inscope conds <- text_rule_conditions(spec, names, call)
        collect_rule(spec, call, 3, conds, rw)
    }
}

//! the function the `%flex~` reader writes: `rule("regex", "conditions") { action }` per rule line,
//! the start conditions and the token enum as annotation arguments; it feeds the same `FlexSpec`
//! and the same `flex_generate` as `[flex]`
[function_macro(name="flex_text")]
class FlexTextMacro : AstFunctionAnnotation {
    def override apply(var func : FunctionPtr; var group : ModuleGroup;
                       var args : AnnotationArgumentList; var errors : das_string) : bool {
        let body = func.body as ExprBlock
        return flex_apply(func, args, "flex_text", errors) $(var spec; lx) {
            text_conditions(spec, string_arg(args, "conditions", ""))
            collect_text_rules(spec, body, lx, string_arg(args, "tokens", ""))
        }
    }
}
