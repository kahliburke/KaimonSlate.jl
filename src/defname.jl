# Extract the defined name from a top-level definition Expr — shared by the worker's hot-reload
# change detector (worker.jl) and its unit test (test/test_defname.jl). Pure, dependency-free.
#
# Best-effort across the forms Julia parsing AND Revise produce: short-form/`function`/`where`/
# return-typed defs, structs (incl. parametric / `<: Super`), abstract & primitive types, consts,
# macros, and — crucially — the wrappers Revise stores defs in: a `:macrocall` (docstrings,
# `@inline foo()=…`) and a `:block` (`begin <LineNumberNode> def end`, e.g. consecutive bare
# one-liners). Returns the name `String`, or `nothing` for non-definitions. Over/under-matching
# only affects which cells are flagged stale on a /src edit, never correctness.

# Name out of a "name position" expr: a Symbol, `Foo{T}` (curly), `Foo <: Bar` (<:), or a
# qualified `Mod.foo` (take the last component).
_name_str(x) = x isa Symbol ? string(x) :
    x isa QuoteNode ? _name_str(x.value) :                       # `Mod.foo` → .args[end] is QuoteNode(:foo)
    (x isa Expr ? (x.head === :curly ? _name_str(x.args[1]) :
                   x.head === :(<:) ? _name_str(x.args[1]) :
                   x.head === :(.)  ? _name_str(x.args[end]) : nothing) : nothing)

# Name out of a function signature: `f`, `f(args)` (call), `f(args) where T` (where),
# `f(args)::Ret` (return-typed), or a bare `x` (a plain `x = …` global assignment).
_sig_name(sig) = sig isa Symbol ? string(sig) :
    (sig isa Expr ? (sig.head === :call ? _name_str(sig.args[1]) :
                     sig.head === :where || sig.head === :(::) ? _sig_name(sig.args[1]) : nothing) : nothing)

function _def_name(ex)
    ex isa Expr || return nothing
    h = ex.head
    h === :function || h === :(=)            ? _sig_name(ex.args[1]) :
    h === :struct                            ? _name_str(ex.args[2]) :
    (h === :abstract || h === :primitive)    ? _name_str(ex.args[1]) :
    h === :macro                             ? (n = _sig_name(ex.args[1]); n === nothing ? nothing : "@" * n) :
    h === :const && !isempty(ex.args)        ? (a = ex.args[1]; _name_str(a isa Expr && a.head === :(=) ? a.args[1] : a)) :
    # Revise wraps some defs as `begin <LineNumberNode> def end` (:block) or with a docstring /
    # macro (:macrocall) — recurse into the children to find the inner def's name.
    (h === :macrocall || h === :block)       ? findfirst_def(ex.args) :
    nothing
end
# First non-nothing def name among a list of child exprs (skips LineNumberNodes / strings / etc.).
findfirst_def(args) = (for a in args; r = _def_name(a); r === nothing || return r; end; nothing)
