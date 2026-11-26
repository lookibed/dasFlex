options gen2
options indenting = 4
options strict_smart_pointers = true

module flex_tier shared public

require daslib/ast_boost

//! `flex_jit_tier()`: true when the program being compiled runs under the JIT, a constant the
//! compile folds, so `static_if` and field defaults pick a shape per tier
[arch(at="../ARCHITECTURE_SYMBOLS.md#symbols"), call_macro(name="flex_jit_tier")]
class FlexJitTier : AstCallMacro {
    def override visit(prog : ProgramPtr; mod : Module?; var expr : ExprCallMacro?) : ExpressionPtr {
        if (length(expr.arguments) != 0) {
            prog |> macro_error(expr.at, "flex_jit_tier() takes no arguments")
            return <- default<ExpressionPtr>
        }
        return <- new ExprConstBool(at = expr.at, value = compiling_program().policies.jit_enabled)
    }
}
