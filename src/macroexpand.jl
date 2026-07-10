# Shared macro-expansion helper (engine + worker). Expands a cell's top-level statements in the
# namespace module where its macros live — recursively, and NEVER evaluating — returning the
# expanded form as a parseable source string. The server re-runs ExpressionExplorer on that string
# to recover the true reads/writes an unknown macro produces (`@kwdef struct Foo` defines `Foo`;
# static analysis of the unexpanded call can't see it — see deps.jl `_macrocall_arg_refs!`).
#
# Statements headed by a Slate handler macro are EXCLUDED from the expansion: their bespoke static
# analysis (deps.jl) is already precise, and expanding one would fabricate bindings the analysis
# deliberately withholds (e.g. `@onclick`'s control is intentionally NOT a read). A statement whose
# expansion throws is skipped — the caller keeps the conservative reads-only scan for it, so a
# failure only ever costs precision, never a real dependency.
const _EXPAND_SKIP = (Symbol("@bind"), Symbol("@reactive"), Symbol("@onclick"), Symbol("@onchange"),
                      Symbol("@asset"), Symbol("@use"))

# Expanded ASTs contain nodes whose printed form does not re-parse (`Expr(:meta, :doc)` prints as
# `$(Expr(:meta, :doc))`; a `:comparison` chain with module-qualified operators — `@enum`'s bounds
# check — prints them infix, a syntax error). Normalize to an ANALYSIS-EQUIVALENT form instead of
# chasing printer fidelity: a module-qualified name can never be a notebook binding, so it (and any
# `GlobalRef`) collapses to the inert `nothing`; a comparison chain keeps only its operands; pure
# compiler annotations vanish. Definitions always survive — they are plain (escaped) symbols — and
# the caller filters the placeholder out of the recovered sets.
_sanitize_expansion(x) = x isa GlobalRef ? :nothing : x
function _sanitize_expansion(e::Expr)
    e.head in (:meta, :inbounds, :loopinfo) && return nothing
    e.head === :comparison && return Expr(:tuple, Any[_sanitize_expansion(a) for a in e.args[1:2:end]]...)
    (e.head === :. && length(e.args) == 2 && e.args[2] isa QuoteNode) && return :nothing
    return Expr(e.head, Any[_sanitize_expansion(a) for a in e.args]...)
end

# Expand one statement into `out`. A macro may return `Expr(:toplevel, …)` (`@enum` does), whose
# sub-statements still carry unresolved `hygienic-scope` nodes — re-expanding each one resolves
# them (plain statements re-expand as a no-op).
function _expand_stmt!(out::Vector{Any}, mod::Module, s)
    e = try; macroexpand(mod, s; recursive = true); catch; nothing; end
    e === nothing && return nothing
    if e isa Expr && e.head === :toplevel
        for a in e.args
            a isa LineNumberNode && continue
            a2 = try; macroexpand(mod, a; recursive = true); catch; nothing; end
            a2 === nothing || push!(out, _sanitize_expansion(a2))
        end
    else
        push!(out, _sanitize_expansion(e))
    end
    return nothing
end

"Expand `src`'s top-level statements in `mod` → parseable expanded source, or `nothing` when
nothing expanded (parse failure, all statements skipped, or every expansion threw)."
function _expand_cell_source(mod::Module, src::AbstractString)
    top = try; Meta.parseall(String(src)); catch; return nothing; end
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
    expanded = Any[]
    for s in stmts
        s isa LineNumberNode && continue
        s isa Expr && s.head === :macrocall && !isempty(s.args) && s.args[1] in _EXPAND_SKIP && continue
        _expand_stmt!(expanded, mod, s)
    end
    isempty(expanded) && return nothing
    return string(Expr(:block, expanded...))
end
