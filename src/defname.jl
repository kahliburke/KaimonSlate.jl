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
_name_str(x) =
    if x isa Symbol
        string(x)
    elseif x isa QuoteNode
        _name_str(x.value)                       # `Mod.foo` → .args[end] is QuoteNode(:foo)
    else
        (x isa Expr ? (
            if x.head === :curly
                _name_str(x.args[1])
            elseif x.head === :(<:)
                _name_str(x.args[1])
            elseif x.head === :(.)
                _name_str(x.args[end])
            else
                nothing
            end
        ) : nothing)
    end

# Name out of a function signature: `f`, `f(args)` (call), `f(args) where T` (where),
# `f(args)::Ret` (return-typed), or a bare `x` (a plain `x = …` global assignment).
function _sig_name(sig)
    return if sig isa Symbol
        string(sig)
    else
        (sig isa Expr ? (
            if sig.head === :call
                _name_str(sig.args[1])
            elseif sig.head === :where || sig.head === :(::)
                _sig_name(sig.args[1])
            else
                nothing
            end
        ) : nothing)
    end
end

function _def_name(ex)
    ex isa Expr || return nothing
    h = ex.head
    if h === :function || h === :(=)
        _sig_name(ex.args[1])
    elseif h === :struct
        _name_str(ex.args[2])
    elseif (h === :abstract || h === :primitive)
        _name_str(ex.args[1])
    elseif h === :macro
        (n=_sig_name(ex.args[1]); n === nothing ? nothing : "@" * n)
    elseif h === :const && !isempty(ex.args)
        (a=ex.args[1]; _name_str(a isa Expr && a.head === :(=) ? a.args[1] : a))
        # Revise wraps some defs as `begin <LineNumberNode> def end` (:block) or with a docstring /
        # macro (:macrocall) — recurse into the children to find the inner def's name.
    elseif (h === :macrocall || h === :block)
        findfirst_def(ex.args)
    else
        nothing
    end
end
# First non-nothing def name among a list of child exprs (skips LineNumberNodes / strings / etc.).
findfirst_def(args) = (
    for a in args
        r = _def_name(a)
        r === nothing || return r
    end;
    nothing
)

# LineNumberNode-free copy, so an edit that only shifts line numbers doesn't read as a change
# (used to body-hash a def for change-granular hot-reload — see worker.jl `_file_defs`).
_strip_lines(x) = x
function _strip_lines(ex::Expr)
    return Expr(ex.head, Any[_strip_lines(a) for a in ex.args if !(a isa LineNumberNode)]...)
end

# Walk a parsed file (a :toplevel Expr) into (def-name → body-hash), recursing into (sub)modules
# so a def INSIDE a submodule (e.g. `Sub.greet`) is captured under its leaf name — matching how
# cells read it (leaf-aware change matching, server side). `_def_name` already unwraps the
# :block / :macrocall / docstring wrappers Julia & Revise produce.
function _collect_defs!(d::Dict{String,UInt64}, ex)
    ex isa Expr || return d
    if ex.head === :toplevel || ex.head === :block
        for a in ex.args
            _collect_defs!(d, a)
        end
    elseif ex.head === :module
        _collect_defs!(d, ex.args[3])                       # module Name <block>
    else
        nm = _def_name(ex)
        nm === nothing || (d[nm] = hash(_strip_lines(ex)))
    end
    return d
end
