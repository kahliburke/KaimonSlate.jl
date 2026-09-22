# Shared macro-expansion + analysis (engine + worker). To recover the bindings an unknown macro
# hides (`@kwdef struct Foo` DEFINES `Foo`; static analysis of the unexpanded call can't see it —
# see deps.jl `_macrocall_arg_refs!`), a cell's statements are expanded in the namespace module
# where its macros actually live, and ExpressionExplorer runs ON THE RAW EXPANDED AST right there.
# Only plain name lists cross any boundary — never printed Exprs. (The first design shipped the
# expansion as a STRING and re-parsed it server-side; Julia's Expr printer doesn't guarantee
# re-parseable output — `Expr(:meta)` nodes, qualified-operator comparison chains — which forced a
# whack-a-mole sanitizer. Analyzing at the source deletes that entire failure class.) Each side
# imports its own ExpressionExplorer at the SAME pinned version: the engine via Project.toml, the
# worker via the slate-owned `worker_infra` env on its LOAD_PATH (after the notebook project, so a
# notebook's own EE wins — the same env that carries Revise and SlateExtensionsBase).
#
# Statements headed by a Slate handler macro are EXCLUDED from expansion: their bespoke static
# analysis (deps.jl) is already precise, and expanding one would fabricate bindings the analysis
# deliberately withholds (e.g. `@onclick`'s control is intentionally NOT a read). A statement
# whose expansion throws is skipped — failure only ever costs precision, never a real dependency.
const _EXPAND_SKIP = (Symbol("@bind"), Symbol("@reactive"), Symbol("@onclick"), Symbol("@onchange"),
                      Symbol("@asset"), Symbol("@use"))

"""The path of an `include("literal")` call, else `nothing`. Shared by the dependency analyzer — the
path is a tracked cell INPUT, exactly like `@asset` — and by the splice below. A COMPUTED path is
invisible to both, the same dynamic caveat `readfile` carries."""
_literal_include_path(ex) = (ex isa Expr && ex.head === :call && length(ex.args) == 2 &&
    ex.args[1] === :include && ex.args[2] isa AbstractString) ? String(ex.args[2]) : nothing

# `Meta.parseall` reports a syntax error as an `:error`/`:incomplete` NODE rather than throwing, and
# such a tree must not reach ExpressionExplorer (it throws, costing the whole cell's expansion).
_parse_failed(ex) = ex isa Expr &&
    (ex.head === :error || ex.head === :incomplete || any(_parse_failed, ex.args))

# Resolve an include path the way the RUN will. At cell level that's the namespace's own
# `__slate_include_path` (the notebook's project dir); inside an included file it's that file's
# directory, passed down as `dir` — the run gets it from its include stack, which this pass has no
# business pushing onto. A module without the helper (a bare probe module) gets no splice rather than
# a guessed path.
function _include_resolve(mod::Module, p::AbstractString, dir::Union{Nothing,String})
    ap = if isabspath(p)
        p
    elseif dir !== nothing
        joinpath(dir, p)
    elseif isdefined(mod, :__slate_include_path)
        try
            Base.invokelatest(getproperty(mod, :__slate_include_path), p)
        catch
            nothing
        end
    else
        nothing
    end
    return (ap isa AbstractString && isfile(ap)) ? String(ap) : nothing
end

const _INCLUDE_SPLICE_DEPTH = 3

"""`include("f.jl")` → the file's top-level statements, spliced in where the call stood (recursively,
for a helper that includes another). The file is PARSED, never evaluated; the point is that what it
DEFINES becomes the cell's writes, so cells using those names get real graph edges — the static pass
sees only a call to `include`. Depth-capped and cycle-guarded, and anything unresolvable (missing
file, syntax error, computed path) leaves the statement as it stands: a precision loss, never a
wrong edge."""
function _splice_includes(mod::Module, s, depth::Int = 0, seen::Set{String} = Set{String}(),
                          dir::Union{Nothing,String} = nothing)
    p = _literal_include_path(s)
    (p === nothing || depth >= _INCLUDE_SPLICE_DEPTH) && return Any[s]
    ap = _include_resolve(mod, p, dir)
    (ap === nothing || ap in seen) && return Any[s]
    top = try; Meta.parseall(read(ap, String)); catch; nothing; end
    (top === nothing || _parse_failed(top)) && return Any[s]
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
    inner = union(seen, Set{String}((ap,)))
    out = Any[]
    for s2 in stmts
        s2 isa LineNumberNode && continue
        append!(out, _splice_includes(mod, s2, depth + 1, inner, dirname(ap)))
    end
    return out
end

"Expand `src`'s top-level statements in `mod` (recursively, NEVER evaluating) → the expanded
exprs. A macro may return `Expr(:toplevel, …)` (`@enum` does) whose sub-statements still carry
unresolved `hygienic-scope` nodes — re-expanding each one resolves them. A top-level literal
`include` is replaced by the included file's own statements first (`_splice_includes`)."
function _expand_cell_statements(mod::Module, src::AbstractString)
    top = try; Meta.parseall(String(src)); catch; return Any[]; end
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
    out = Any[]
    for s0 in stmts, s in _splice_includes(mod, s0)
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
