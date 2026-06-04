# Dependency model (§6). Included into `module ReportEngine`.
#
# Reads come from ExpressionExplorer (free-variable analysis); writes are its
# definitions ∪ function-def names, augmented with mutation heuristics (`!`-calls,
# indexed/field/broadcast assignment). Edges use the most-recent-prior-writer
# rule in document order. Staleness never under-invalidates: an unanalyzable cell
# becomes an opaque barrier. The persistent module + cheap full rebuild are the
# ground-truth backstop.

import ExpressionExplorer as EE

export infer_bindings!, build_dependencies!, dependents_of, update_source!, eval_stale!

# ── Binding inference ────────────────────────────────────────────────────────

# `Meta.parseall` returns `:error` / `:incomplete` nodes (not a throw) on bad
# syntax — detect them so the cell can be flagged opaque.
function _has_parse_error(ex)
    ex isa Expr || return false
    (ex.head === :error || ex.head === :incomplete) && return true
    return any(_has_parse_error, ex.args)
end

# Cells that change the namespace or run external code (`using` / `import` /
# `include`) are treated as barriers (§6.7): the imported names, global config
# (e.g. Makie themes via `set_theme!`), and side effects aren't fully visible to
# binding analysis, so downstream cells must conservatively depend on them.
function _is_barrier_expr(ex)
    ex isa Expr || return false
    (ex.head === :using || ex.head === :import) && return true
    ex.head === :call && !isempty(ex.args) && ex.args[1] === :include && return true
    return any(_is_barrier_expr, ex.args)
end

# Base name of an assignment/index/field target (`data[i]` → :data, `a.b.c` → :a).
_base_symbol(s::Symbol) = s
_base_symbol(e::Expr) = (e.head === :ref || e.head === :.) ? _base_symbol(e.args[1]) : nothing
_base_symbol(::Any) = nothing

const _BROADCAST_ASSIGN = Symbol(".=")

# Walk the AST collecting in-place mutation as writes (also reads — you read the
# object to mutate it). Covers `f!(x, …)`, `x[i] = …`, `x.f = …`, `x .= …`.
function _collect_mutations!(writes::Set{Symbol}, reads::Set{Symbol}, ex)
    if ex isa Expr
        if ex.head === :call && length(ex.args) >= 2 &&
           ex.args[1] isa Symbol && endswith(string(ex.args[1]), "!")
            b = _base_symbol(ex.args[2])
            b === nothing || (push!(writes, b); push!(reads, b))
        elseif (ex.head === :(=) || ex.head === _BROADCAST_ASSIGN) && !isempty(ex.args)
            lhs = ex.args[1]
            if ex.head === _BROADCAST_ASSIGN || (lhs isa Expr && (lhs.head === :ref || lhs.head === :.))
                b = _base_symbol(lhs)
                b === nothing || (push!(writes, b); push!(reads, b))
            end
        end
        for a in ex.args
            _collect_mutations!(writes, reads, a)
        end
    end
    return nothing
end

"""
    infer_bindings!(cell) -> cell

Populate `cell.reads` / `cell.writes` for a code cell. On parse/analysis failure
the cell is flagged `:opaque` (treated as a barrier in the graph).
"""
function infer_bindings!(cell::Cell)
    empty!(cell.reads); empty!(cell.writes)
    delete!(cell.flags, :opaque)
    if cell.kind == MARKDOWN
        # A markdown cell "reads" the free variables of its `{{ expr }}` blocks, so
        # it joins the reactive graph and re-renders when they change.
        for e in _md_interp_exprs(cell.source)
            ast = try; Meta.parse(e); catch; nothing; end
            ast === nothing && continue
            try
                union!(cell.reads, EE.compute_reactive_node(Expr(:block, ast)).references)
            catch
            end
        end
        return cell
    end
    cell.kind == CODE || return cell

    specs = parse_binds(cell.source)          # @bind widget / control-group cell?
    if !isempty(specs)
        prev = Dict(b.name => b.value for b in cell.binds)
        for s in specs
            haskey(prev, s.name) && (s.value = prev[s.name])  # preserve live widget values
            push!(cell.writes, s.name)        # each bind writes its variable
        end
        cell.binds = specs
        return cell
    end
    cell.binds = BindSpec[]

    top = try
        Meta.parseall(cell.source)
    catch
        push!(cell.flags, :opaque); return cell
    end
    if _has_parse_error(top)
        push!(cell.flags, :opaque); return cell
    end
    blk = Expr(:block, top.args...)
    try
        node = EE.compute_reactive_node(blk)
        union!(cell.reads, node.references)
        union!(cell.writes, node.definitions)
        union!(cell.writes, node.funcdefs_without_signatures)
    catch
        push!(cell.flags, :opaque)
    end
    _collect_mutations!(cell.writes, cell.reads, blk)
    _is_barrier_expr(top) && push!(cell.flags, :opaque)
    return cell
end

# ── Dependency graph (most-recent-prior-writer) ──────────────────────────────

"""
    build_dependencies!(report) -> report

Re-infer bindings and compute each code cell's upstream `deps` (ids). A cell
depends on the most recent prior writer of each name it reads. An `:opaque` cell
depends on all prior code cells, and all later code cells depend on it (barrier).
"""
function build_dependencies!(report::Report)
    for c in report.cells
        infer_bindings!(c)
        empty!(c.deps)
    end
    writer = Dict{Symbol,String}()        # name → id of most-recent prior writer
    barrier::Union{String,Nothing} = nothing
    seen = String[]
    for c in report.cells
        if c.kind == MARKDOWN
            # md cells depend on the writers of their interpolation vars (+ barrier),
            # but never write, become a barrier, or enter `seen`.
            for r in c.reads
                haskey(writer, r) && push!(c.deps, writer[r])
            end
            barrier === nothing || push!(c.deps, barrier)
            delete!(c.deps, c.id)
            continue
        end
        c.kind == CODE || continue
        for r in c.reads
            haskey(writer, r) && push!(c.deps, writer[r])
        end
        barrier === nothing || push!(c.deps, barrier)
        if :opaque in c.flags
            union!(c.deps, seen)          # depends on everything before it
        end
        delete!(c.deps, c.id)             # never self-depend
        for w in c.writes
            writer[w] = c.id
        end
        :opaque in c.flags && (barrier = c.id)
        push!(seen, c.id)
    end
    return report
end

"""
    dependents_of(report, ids) -> Set{String}

Transitive closure: `ids` plus every cell that (transitively) depends on one of
them. This is the staleness blast radius of changing `ids`.
"""
function dependents_of(report::Report, ids)
    stale = Set{String}(ids)
    changed = true
    while changed
        changed = false
        for c in report.cells
            if c.id ∉ stale && !isdisjoint(c.deps, stale)
                push!(stale, c.id)
                changed = true
            end
        end
    end
    return stale
end

# ── Incremental update ───────────────────────────────────────────────────────

"""
    update_source!(report, new_source) -> report

Reparse `new_source`, reconcile cells by id (carrying over cached output for
cells whose source is unchanged), rebuild the graph, and mark changed cells +
their transitive dependents `STALE`. Removed cells invalidate their former
readers. Does not evaluate — call `eval_stale!` next.
"""
function update_source!(report::Report, new_source::AbstractString)
    newr = parse_report(new_source; id = report.id, title = report.title)
    old_by_id = Dict(c.id => c for c in report.cells)

    changed = Set{String}()
    for nc in newr.cells
        oc = get(old_by_id, nc.id, nothing)
        if oc !== nothing && oc.src_hash == nc.src_hash
            nc.output = oc.output         # carry cached result forward
            nc.state = oc.state
            nc.deps = oc.deps
            nc.binds = oc.binds           # preserve live widget values
            nc.interp = oc.interp         # carry resolved md interpolations forward
        else
            nc.state = STALE
            push!(changed, nc.id)         # new or edited
        end
    end
    # A removed cell's writes vanish → anything that read them is now invalid.
    removed = setdiff(keys(old_by_id), Set(c.id for c in newr.cells))
    if !isempty(removed)
        for nc in newr.cells
            isempty(intersect(nc.deps, removed)) || push!(changed, nc.id)
        end
    end

    report.cells = newr.cells
    build_dependencies!(report)
    for id in dependents_of(report, changed)
        for c in report.cells
            c.id == id && (c.state = STALE)
        end
    end
    return report
end

# ── Pruned recompute ─────────────────────────────────────────────────────────

"""
    eval_stale!(report, kernel=InProcessKernel()) -> report

Evaluate only `STALE` code cells, in document order, through `kernel`. Unchanged
(`FRESH`) cells keep their cached output — their effects already live in the
kernel's namespace from the prior eval. (First run: all cells stale ⇒ full eval.)
"""
function eval_stale!(report::Report, kernel::Kernel = InProcessKernel())
    prepare!(kernel, report)
    for c in report.cells
        if c.kind == MARKDOWN
            c.state == STALE && eval_cell!(report, c, kernel)   # re-resolve {{ }} interpolations
        elseif c.state == STALE
            eval_cell!(report, c, kernel)
        end
    end
    return report
end
