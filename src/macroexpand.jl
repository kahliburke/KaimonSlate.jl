# Shared macro-expansion + analysis (engine + worker). To recover the bindings an unknown macro
# hides (`@kwdef struct Foo` DEFINES `Foo`; static analysis of the unexpanded call can't see it —
# see deps.jl `_macrocall_arg_refs!`), a cell's statements are expanded in the namespace module
# where its macros actually live, and ExpressionExplorer runs ON THE RAW EXPANDED AST right there.
# Only plain name lists cross any boundary — never printed Exprs. (The first design shipped the
# expansion as a STRING and re-parsed it server-side; Julia's Expr printer doesn't guarantee
# re-parseable output — `Expr(:meta)` nodes, qualified-operator comparison chains — which forced a
# whack-a-mole sanitizer. Analyzing at the source deletes that entire failure class.) Each side
# imports its own ExpressionExplorer at the SAME pinned version: the engine via Project.toml, the
# worker via the slate-owned `worker_ee` env on its LOAD_PATH (after the notebook project, so a
# notebook's own EE wins — the same delivery as the Revise env).
#
# Statements headed by a Slate handler macro are EXCLUDED from expansion: their bespoke static
# analysis (deps.jl) is already precise, and expanding one would fabricate bindings the analysis
# deliberately withholds (e.g. `@onclick`'s control is intentionally NOT a read). A statement
# whose expansion throws is skipped — failure only ever costs precision, never a real dependency.
const _EXPAND_SKIP = (Symbol("@bind"), Symbol("@reactive"), Symbol("@onclick"), Symbol("@onchange"),
                      Symbol("@asset"), Symbol("@use"))

"Expand `src`'s top-level statements in `mod` (recursively, NEVER evaluating) → the expanded
exprs. A macro may return `Expr(:toplevel, …)` (`@enum` does) whose sub-statements still carry
unresolved `hygienic-scope` nodes — re-expanding each one resolves them."
function _expand_cell_statements(mod::Module, src::AbstractString)
    top = try; Meta.parseall(String(src)); catch; return Any[]; end
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
    out = Any[]
    for s in stmts
        s isa LineNumberNode && continue
        s isa Expr && s.head === :macrocall && !isempty(s.args) && s.args[1] in _EXPAND_SKIP && continue
        e = try; macroexpand(mod, s; recursive = true); catch; nothing; end
        e === nothing && continue
        if e isa Expr && e.head === :toplevel
            for a in e.args
                a isa LineNumberNode && continue
                a2 = try; macroexpand(mod, a; recursive = true); catch; nothing; end
                a2 === nothing || push!(out, a2)
            end
        else
            push!(out, e)
        end
    end
    return out
end

"ExpressionExplorer analysis of expanded statements → `(reads, writes)::Tuple{Set{Symbol},Set{Symbol}}`,
or `nothing` (nothing expanded / analysis threw → the caller keeps its conservative scan). `ee` is
the ExpressionExplorer module — each side passes its own import, same pinned version. Hygiene:
gensyms ('#' anywhere) and EE's synthetic anonymous-fn names are never notebook bindings and are
dropped; a qualified ref on the raw AST surfaces as its ROOT symbol (`:Base`) — a harmless extra
read (no cell ever writes `Base`), so it passes through."
function _expanded_bindings_of(ee::Module, exprs::Vector{Any})
    isempty(exprs) && return nothing
    node = try
        ee.compute_reactive_node(Expr(:block, exprs...))
    catch
        return nothing
    end
    keep(n) = (s = String(n); !occursin('#', s) && !startswith(s, "__ExprExpl_anon__"))
    reads = Set{Symbol}(n for n in node.references if keep(n))
    writes = Set{Symbol}(n for n in node.definitions if keep(n))
    union!(writes, Set{Symbol}(n for n in node.funcdefs_without_signatures if keep(n)))
    return (reads, writes)
end
