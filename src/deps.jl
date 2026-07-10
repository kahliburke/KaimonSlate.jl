# Dependency model (§6). Included into `module ReportEngine`.
#
# Reads come from ExpressionExplorer (free-variable analysis); writes are its
# definitions ∪ function-def names, augmented with mutation heuristics (`!`-calls,
# indexed/field/broadcast assignment). Edges use the most-recent-prior-writer
# rule in document order. Staleness never under-invalidates: an unanalyzable cell
# becomes an opaque barrier. The persistent module + cheap full rebuild are the
# ground-truth backstop.

import ExpressionExplorer as EE

export infer_bindings!, build_dependencies!, dependents_of, update_source!, eval_stale!,
       refine_usings!, prewarm_usings!, refine_macros!, prewarm_macros!

# ── Binding inference ────────────────────────────────────────────────────────

# `Meta.parseall` returns `:error` / `:incomplete` nodes (not a throw) on bad
# syntax — detect them so the cell can be flagged opaque.
function _has_parse_error(ex)
    ex isa Expr || return false
    (ex.head === :error || ex.head === :incomplete) && return true
    return any(_has_parse_error, ex.args)
end

# `include(...)` runs external code whose definitions aren't visible to static analysis,
# so a cell containing one is a barrier (downstream cells conservatively depend on it).
# (`using`/`import` are handled precisely in the statement loop — see `_import_names` — so
# a self-contained `import X` no longer chains every cell below it.)
function _is_barrier_expr(ex)
    ex isa Expr || return false
    ex.head === :call && !isempty(ex.args) && ex.args[1] === :include && return true
    return any(_is_barrier_expr, ex.args)
end

# Leaf name a dotted/`as` import path binds: `A.B.C` → :C, `M as L` → :L.
_leaf_name(s::Symbol) = s
_leaf_name(e::Expr) = e.head === :. ? (e.args[end] isa Symbol ? e.args[end] : nothing) :
                      e.head === :as ? _leaf_name(e.args[end]) : nothing
_leaf_name(::Any) = nothing

# Names a top-level `import`/`using` brings into scope (to record as WRITES), or `nothing`
# if it brings an UNKNOWABLE set — a plain `using X` pulls in X's exports, invisible to static
# analysis, so that stays a barrier. Returns `:notimport` for non-import statements.
#   import X            → [:X]          using X: a, b   → [:a, :b]
#   import X: a, b      → [:a, :b]      import X as L    → [:L]
#   using X             → nothing (barrier)
function _import_names(ex)
    (ex isa Expr && (ex.head === :import || ex.head === :using)) || return :notimport
    names = Symbol[]
    for a in ex.args
        if a isa Expr && a.head === :(:)              # `M: a, b` — bring the listed names
            for nm in a.args[2:end]
                s = _leaf_name(nm); s === nothing || push!(names, s)
            end
        elseif ex.head === :import                    # `import M` / `import A.B` / `import M as L`
            s = _leaf_name(a); s === nothing || push!(names, s)
        else
            return nothing                            # plain `using X` → unknowable exports → barrier
        end
    end
    return names
end

# Dotted module paths a BARE `using` names (no `: names` list): `using A, B.C` → ["A", "B.C"].
# Returns String[] for anything that isn't a bare using (so the `: names` form never lands here).
function _using_module_paths(ex)
    (ex isa Expr && ex.head === :using) || return String[]
    paths = String[]
    for a in ex.args
        a isa Expr && a.head === :(:) && return String[]         # `using M: a` — not bare, handled elsewhere
        a isa Expr && a.head === :. && push!(paths, join(string.(a.args), "."))
    end
    return paths
end

# ── Progressive `using` refinement (barrier → precise) ───────────────────────
# A bare `using X` splats X's exports into scope — statically unknowable, so inference
# conservatively treats the cell as an :opaque barrier (reads everything before it, everything
# after depends on it). But once the cell has RUN, X is loaded and we CAN enumerate its exports.
# `refine_usings!` (called post-eval) resolves them WHERE the cells run and records them here;
# re-inference then turns the barrier into a precise import — downstream depends on the cell only
# if it uses a name X actually brings in. Session-scoped (a package's exports don't change once
# loaded); `_USING_TRIED` remembers paths we've already resolved OR failed to, so we attempt each
# at most once (no ZMQ round-trip per drain for a module that's already settled).
const _USING_EXPORTS = Dict{String,Vector{Symbol}}()   # dotted module path → its exported names
const _USING_TRIED   = Set{String}()                   # paths already attempted (success or fail)
const _USING_LOCK    = ReentrantLock()

# The precise write-set for a bare `using` statement IF every module it names is already resolved;
# `nothing` otherwise (⇒ inference keeps the conservative :opaque barrier). Empty paths (a malformed
# using) also yield `nothing` so we never drop the barrier without a real export set to replace it.
function _resolved_using_writes(stmt)
    paths = _using_module_paths(stmt)
    isempty(paths) && return nothing
    lock(_USING_LOCK) do
        all(p -> haskey(_USING_EXPORTS, p), paths) || return nothing
        out = Symbol[]
        for p in paths; append!(out, _USING_EXPORTS[p]); end
        return out
    end
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

# In-place mutations, recorded as writes — but ONLY of GLOBAL names. `_collect_mutations!` is
# scope-blind (it walks the whole AST), so a mutated LOCAL — a `let`-block, comprehension, or loop
# local like `acc[i] = …` / `push!(acc, …)` — would masquerade as a global write. That produced
# phantom write-write conflicts in the scheduler AND false "defined in more than one cell" warnings
# when two cells each mutate their own same-named local. `globals` is EE's `references` set — exactly
# the block's free (global) variables — so we keep only mutations whose base name is genuinely global.
# (A name the cell itself defines is already a write via `node.definitions`, so dropping its mutation
# entry here loses nothing.)
function _record_global_mutations!(cell::Cell, ex, globals)
    mw = Set{Symbol}(); mr = Set{Symbol}()
    _collect_mutations!(mw, mr, ex)
    for s in mw
        s in globals || continue
        # A purely-mutated global (`prog[] = …`, `push!(v, …)`) is NOT a definition: mark it in `mutates`
        # so the multi-def check + "defines" label skip it. But if the cell ALSO rebinds it (`x = []; push!(x,1)`)
        # it's already in `writes` as a real def — leave it a def. Either way keep it in `writes`, which drives
        # ordering / write-conflicts / the reactive self-trigger exclusion (a mutator must still be a "writer" there).
        s in cell.writes || push!(cell.mutates, s)
        push!(cell.writes, s)
    end
    for s in mr; s in globals && push!(cell.reads, s); end
    return nothing
end

# Statically collect the file paths a cell references via `@asset "path"` (or `@asset bytes
# "path"`) — a STRING-LITERAL arg to an `@asset` macrocall, anywhere in the AST. Because the
# path is a literal in the source, this is known WITHOUT running the cell, so the file becomes
# a first-class reactive/memo input (the watcher arms on open; the memo key folds its hash).
# A computed path (`readfile(x)`) is invisible here — that's the documented dynamic caveat.
function _collect_asset_paths!(paths::Vector{String}, ex)
    if ex isa Expr
        if ex.head === :macrocall && !isempty(ex.args) && ex.args[1] === Symbol("@asset")
            for a in ex.args[2:end]
                a isa AbstractString && push!(paths, String(a))
            end
        end
        for a in ex.args
            _collect_asset_paths!(paths, a)
        end
    end
    return paths
end

# Statically collect notebook-level ES-module import-map entries declared via
# `@use "name" => "url"` (or `@use "name" "url"`) — literal pairs anywhere in the AST, so they're
# known WITHOUT running the cell (mirrors `@asset`). The engine merges these into the page's single
# `<script type="importmap">` (shell head live + export head) so front-end JS can `import` them.
function _collect_use_imports!(dict::AbstractDict, ex)
    if ex isa Expr
        if ex.head === :macrocall && !isempty(ex.args) && ex.args[1] === Symbol("@use")
            args = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
            if length(args) == 1 && args[1] isa Expr && args[1].head === :call && length(args[1].args) == 3 &&
               args[1].args[1] === :(=>) && args[1].args[2] isa AbstractString && args[1].args[3] isa AbstractString
                dict[String(args[1].args[2])] = String(args[1].args[3])         # @use "name" => "url"
            elseif length(args) == 2 && args[1] isa AbstractString && args[2] isa AbstractString
                dict[String(args[1])] = String(args[2])                          # @use "name" "url"
            end
        end
        for a in ex.args
            _collect_use_imports!(dict, a)
        end
    end
    return dict
end

# ExpressionExplorer swallows an UNKNOWN macro's arguments whole: `@chain rotations begin … end`
# yields only `@chain` as a reference — the `rotations` dataflow edge (and every function the block
# calls) silently vanishes from the reactive graph, breaking recompute order, the deps viewer, and
# memo-key closures alike. Until the macro can be expanded for real (worker-side macroexpand, which
# also recovers WRITES — e.g. `@kwdef struct Foo`), over-approximate: scan every macrocall's
# arguments as ordinary expressions and take their REFERENCES as reads. Writes are deliberately NOT
# taken — fabricating producers from unexpanded macro args could steal an edge from a true definer.
# Slate's own handler macros are excluded: their bodies get bespoke analysis (`@onclick`'s control
# is intentionally NOT a read), and `@asset`/`@use` args are literals collected separately.
const _MACRO_SCAN_SKIP = Set{Symbol}((Symbol("@bind"), Symbol("@reactive"), Symbol("@onclick"),
    Symbol("@onchange"), Symbol("@asset"), Symbol("@use")))
function _macrocall_arg_refs!(refs::Set{Symbol}, ex)
    ex isa Expr || return refs
    if ex.head === :macrocall && !isempty(ex.args)
        name = ex.args[1]
        (name isa Symbol && name in _MACRO_SCAN_SKIP) && return refs
        args = Any[a for a in ex.args[3:end] if !(a isa LineNumberNode)]
        try
            union!(refs, EE.compute_reactive_node(Expr(:block, args...)).references)
        catch e
            @debug "deps: macrocall arg-scan failed" exception = e
        end
        foreach(a -> _macrocall_arg_refs!(refs, a), args)   # nested macrocalls swallow again — recurse
    else
        foreach(a -> _macrocall_arg_refs!(refs, a), ex.args)
    end
    return refs
end

# Does the AST contain a macrocall the static pass can't see through (any macro outside
# `_MACRO_SCAN_SKIP` — a dotted `Base.@kwdef` name counts too)? Such a cell gets the runtime
# `:macrocall` flag so the macro-expansion refinement (`resolve_macros!`) knows to round-trip it.
function _has_unknown_macrocall(ex)
    ex isa Expr || return false
    if ex.head === :macrocall && !isempty(ex.args)
        name = ex.args[1]
        (name isa Symbol && name in _MACRO_SCAN_SKIP) || return true
    end
    return any(_has_unknown_macrocall, ex.args)
end

# Notebook-level import map: scan every code cell's source for `@use` declarations → an ordered
# name→url map on `report.meta["imports"]`. Refreshed on each structural pass (build_dependencies!),
# so adding/removing a `@use` updates what the shell/export head injects (a live change still needs a
# page reload — the browser fixes the import map at load).
function _scan_imports!(report::Report)
    d = Dict{String,String}()
    for c in report.cells
        c.kind == CODE || continue
        top = try; Meta.parseall(c.source); catch; continue; end
        _collect_use_imports!(d, top)
    end
    report.meta["imports"] = d
    return d
end

"""
    infer_bindings!(cell) -> cell

Populate `cell.reads` / `cell.writes` for a code cell. On parse/analysis failure
the cell is flagged `:opaque` (treated as a barrier in the graph).
"""
# Reads/writes/opaque depend ONLY on a cell's source (+ kind), so the (expensive) ExpressionExplorer
# pass is memoized by source hash. Without this, `build_dependencies!` re-analyzed every cell on each
# call — ≈1.5s on a 140-cell notebook, paid by EVERY structural edit. Keyed by cell id but validated
# on the source hash, so a stale or cross-notebook id can never return wrong bindings (hash mismatch
# → recompute).
const _BIND_CACHE = Dict{String,Tuple{UInt64,Set{Symbol},Set{Symbol},Bool,Vector{String},Set{Symbol},Set{Symbol},Bool}}()
const _BIND_CACHE_LOCK = ReentrantLock()
# No per-cell eviction (a deleted cell / closed notebook never removes its entry), so on a
# long-lived server this would otherwise grow forever. Entries are small, but cap it — once full,
# clear and start over rather than track real LRU bookkeeping for a cache this cheap to repopulate
# (a cleared entry just costs one more `_infer_bindings_uncached!` pass, same as a normal miss).
const _BIND_CACHE_MAX = 5000
function infer_bindings!(cell::Cell)
    h = hash(cell.source) ⊻ hash(cell.kind)
    hit = lock(_BIND_CACHE_LOCK) do; get(_BIND_CACHE, cell.id, nothing); end
    if hit !== nothing && hit[1] == h
        empty!(cell.reads);  union!(cell.reads,  hit[2])
        empty!(cell.writes); union!(cell.writes, hit[3])
        hit[4] ? push!(cell.flags, :opaque) : delete!(cell.flags, :opaque)
        empty!(cell.inputs); append!(cell.inputs, hit[5])   # `@asset` file deps (statically extracted)
        empty!(cell.provides); union!(cell.provides, hit[6])   # `using`/`import`-brought names (⊆ writes)
        empty!(cell.mutates); union!(cell.mutates, hit[7])   # in-place-mutated-only names (⊆ writes, ⊄ defines)
        hit[8] ? push!(cell.flags, :macrocall) : delete!(cell.flags, :macrocall)   # unknown-macro cell (expansion candidate)
        return cell
    end
    _infer_bindings_uncached!(cell)
    lock(_BIND_CACHE_LOCK) do
        length(_BIND_CACHE) >= _BIND_CACHE_MAX && empty!(_BIND_CACHE)
        _BIND_CACHE[cell.id] = (h, copy(cell.reads), copy(cell.writes), :opaque in cell.flags, copy(cell.inputs), copy(cell.provides), copy(cell.mutates), :macrocall in cell.flags)
    end
    return cell
end
# ExpressionExplorer names an anonymous function `__ExprExpl_anon__<rand(UInt64)>` and reports it
# among a cell's definitions. That name is synthetic — never a real global, and RANDOM on every
# re-analysis — so letting it into `writes` poisons everything keyed off the write-set (most visibly
# the memo store guard, which then never caches a cell containing `x -> …` or a do-block). Strip them.
_strip_anon(names) = Iterators.filter(n -> !startswith(String(n), "__ExprExpl_anon__"), names)

function _infer_bindings_uncached!(cell::Cell)
    empty!(cell.reads); empty!(cell.writes); empty!(cell.mutates); empty!(cell.inputs); empty!(cell.provides)
    delete!(cell.flags, :opaque); delete!(cell.flags, :macrocall)
    if cell.kind == MARKDOWN
        # A markdown cell "reads" the free variables of its `{{ expr }}` blocks, so
        # it joins the reactive graph and re-renders when they change.
        for e in _md_interp_exprs(cell.source)
            ast = try; Meta.parse(e); catch; nothing; end
            ast === nothing && continue
            try
                union!(cell.reads, EE.compute_reactive_node(Expr(:block, ast)).references)
            catch e
                @debug "deps: markdown {{ }} reactive-node analysis failed" cell = cell.id exception = e
            end
        end
        return cell
    end
    cell.kind == CODE || return cell

    top = try
        Meta.parseall(cell.source)
    catch
        push!(cell.flags, :opaque); return cell
    end
    if _has_parse_error(top)
        push!(cell.flags, :opaque); return cell
    end
    # An unknown macro hides its true bindings from the static pass (see `_macrocall_arg_refs!`);
    # flag the cell so the expansion refinement can recover them once the macro is resolvable.
    _has_unknown_macrocall(top) && push!(cell.flags, :macrocall)
    # `@asset "path"` file deps — literal paths anywhere in the cell (sorted+unique for a stable key).
    let ap = _collect_asset_paths!(String[], top)
        isempty(ap) || append!(cell.inputs, sort!(unique!(ap)))
    end
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]

    # `@bind name W(…)` statements: the bound name is a WRITE, the widget call's free
    # vars are READS (so `Slider(1:step:hi)` makes the cell depend on `step`/`hi`). No
    # widget evaluation here — dynamic args are fine. Everything else is ordinary code,
    # analyzed normally, so a cell may freely mix binds and code. `cell.binds` (for the
    # UI) is populated by EVAL from what the run reports, not by this static pass.
    nonbind = Any[]
    for s in stmts
        s isa LineNumberNode && continue
        imp = _import_names(s)
        if imp !== :notimport                 # a top-level using/import
            if imp === nothing                # plain `using X` → barrier UNLESS X's exports are resolved
                w = _resolved_using_writes(s)
                # Bring the exports into scope (writes → downstream readers depend on this cell), but mark
                # them as PROVIDED (import, not definition) so re-`using X` in another cell isn't a collision.
                w === nothing ? push!(cell.flags, :opaque) : (union!(cell.writes, w); union!(cell.provides, w))
            else
                union!(cell.writes, imp); union!(cell.provides, imp)   # explicitly-named import → provided, not defined
            end
            continue
        end
        rm = _reactive_macrocall(s)
        bm = rm === nothing ? _bind_macrocall(s) : nothing
        om = (rm === nothing && bm === nothing) ? _onclick_macrocall(s) : nothing
        cm = (rm === nothing && bm === nothing && om === nothing) ? _onchange_macrocall(s) : nothing
        if rm !== nothing
            push!(cell.writes, rm[1])            # `@reactive x = init` DEFINES x (the reactive producer)
            try
                union!(cell.reads, EE.compute_reactive_node(Expr(:block, rm[2])).references)
                union!(cell.reads, _macrocall_arg_refs!(Set{Symbol}(), rm[2]))
            catch e
                @debug "deps: @reactive init analysis failed" cell = cell.id exception = e
            end
        elseif bm !== nothing
            push!(cell.writes, bm[1])
            try
                union!(cell.reads, EE.compute_reactive_node(Expr(:block, bm[2])).references)
                union!(cell.reads, _macrocall_arg_refs!(Set{Symbol}(), bm[2]))
            catch e
                @debug "deps: @bind widget-expr reactive-node analysis failed" cell = cell.id exception = e
            end
        elseif om !== nothing || cm !== nothing
            # `@onclick btn body` / `@onchange ctrl body` REGISTER a handler — they deliberately do
            # NOT read the control (a change dispatches to the handler directly, not by recomputing
            # this cell). Analyse the handler LAMBDA so the control (for @onchange) is the bound
            # parameter, not a read; the body's OTHER free vars are real deps (the handler
            # re-registers when a captured var changes) and `level[] = v` registers as a write.
            ctrl, body = om !== nothing ? (nothing, om[2]) : (cm[1], cm[2])
            lam = Expr(:(->), Expr(:tuple, ctrl === nothing ? Symbol("_") : ctrl), body)
            try
                node = EE.compute_reactive_node(lam)
                union!(cell.reads, node.references)
                union!(cell.writes, _strip_anon(node.definitions))
                _record_global_mutations!(cell, body, node.references)
            catch e
                @debug "deps: @onclick/@onchange handler reactive-node analysis failed" cell = cell.id exception = e
            end
        else
            push!(nonbind, s)
        end
    end
    if !isempty(nonbind)
        blk = Expr(:block, nonbind...)
        try
            node = EE.compute_reactive_node(blk)
            union!(cell.reads, node.references)
            union!(cell.reads, _macrocall_arg_refs!(Set{Symbol}(), blk))   # see through unknown macros (reads only)
            union!(cell.writes, _strip_anon(node.definitions))
            union!(cell.writes, _strip_anon(node.funcdefs_without_signatures))
            _record_global_mutations!(cell, blk, node.references)
        catch e
            @debug "deps: cell-body reactive-node analysis failed — falling back to :opaque" cell = cell.id exception = e
            push!(cell.flags, :opaque)
        end
    end
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
    mex = get(report.meta, "macroexpand", true) !== false   # per-notebook opt-out (Slate.config)
    for c in report.cells
        infer_bindings!(c)
        # Union in the reads/writes recovered by macro expansion (`resolve_macros!`) — union-only,
        # so a dependency can be ADDED but never dropped; without a cache entry the conservative
        # reads-only scan stands.
        if mex && :macrocall in c.flags
            rec = lock(_MACRO_LOCK) do
                nb = get(_MACRO_BINDS, report.id, nothing)
                nb === nothing ? nothing : get(nb, c.src_hash, nothing)
            end
            rec === nothing || (union!(c.reads, rec[1]); union!(c.writes, rec[2]))
        end
        empty!(c.deps)
    end
    _scan_imports!(report)                 # notebook-level `@use` import-map declarations → report.meta
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
            # Static markdown (no `{{ }}` interpolation reads) needs no computation — it renders
            # straight from its source — so it is FRESH, not STALE. Keeps prose from flashing "stale"
            # on open and from sitting stale behind code cells during a run (it never has to wait).
            isempty(c.reads) && c.state == STALE && (c.state = FRESH)
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
        # `seen` feeds ONLY the opaque-union above. A contentless cell (no reads, no writes, not a
        # barrier) contributes nothing to the namespace, so no opaque cell truly depends on it —
        # keeping it out means inserting a BLANK cell above an opaque cell doesn't perturb that
        # cell's deps and needlessly restale the whole downstream tail (a real code cell with a
        # bare side effect still `reads` its callees, so it stays in `seen` and keeps its order).
        (isempty(c.reads) && isempty(c.writes) && !(:opaque in c.flags)) || push!(seen, c.id)
    end
    # Names defined by 2+ code cells — a shared-namespace collision (last writer wins), a silent
    # footgun (an edit to one looks like dead reactivity). Count DISTINCT cells per name (each
    # cell's `writes` is a Set). Stashed on meta (runtime-only; never serialized) for the UI.
    wcells = Dict{Symbol,Vector{String}}()
    for c in report.cells, w in c.writes
        w in c.provides && continue          # brought in by `using`/`import` — availability, not a colliding def
        w in c.mutates && continue           # mutated here (`prog[] = …`, `push!(v, …)`), not defined — not a collision
        push!(get!(wcells, w, String[]), c.id)
    end
    report.meta["multidef"] = Set{String}(string(w) for (w, ids) in wcells if length(ids) >= 2)
    report.meta["multidef_cells"] =                       # name → the cells defining it (for the UI popup)
        Dict{String,Vector{String}}(string(w) => ids for (w, ids) in wcells if length(ids) >= 2)
    # Derived indexes: id → cell, and the transpose of `deps` (id → its direct dependents). Rebuilt
    # here — and ONLY here — so a single `build_dependencies!` call leaves every derived structure
    # consistent. `dependents_of` / `_upstream_closure` / `_memo_key` walk these instead of
    # re-scanning all cells per call (the old fixpoint was O(V·E) on every edit).
    empty!(report.byid)
    empty!(report.dependents)
    for c in report.cells
        report.byid[c.id] = c
    end
    for c in report.cells, p in c.deps
        push!(get!(Vector{String}, report.dependents, p), c.id)
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
    queue = collect(stale)
    while !isempty(queue)
        for d in get(report.dependents, pop!(queue), ())
            d in stale && continue
            push!(stale, d)
            push!(queue, d)
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
    # Carry over the footer-borne meta (env packages + the Slate.config per-notebook settings) parsed
    # from the new source, so an external edit to a footer — or its absence — is reflected.
    haskey(newr.meta, "env") ? (report.meta["env"] = newr.meta["env"]) : delete!(report.meta, "env")
    for k in ("parallel", "threads", "hotreload", "macroexpand")
        haskey(newr.meta, k) ? (report.meta[k] = newr.meta[k]) : delete!(report.meta, k)
    end
    build_dependencies!(report)
    for id in dependents_of(report, changed)
        c = get(report.byid, id, nothing)
        c === nothing || (c.state = STALE)
    end
    # A changed/removed MACRO DEFINER (a cell writing an `@name`, or a `using`/barrier cell that may
    # import macros) can alter what its callers expand to — their sources (and cache keys) are
    # unchanged, so clear the attempt-once set and let the next drain re-expand them. Cached
    # expansions stay until overwritten (stale-but-useful beats a dropped edge).
    definerish(c) = :opaque in c.flags || !isempty(c.provides) ||
                    any(w -> startswith(String(w), "@"), c.writes)
    if any(c -> c.id in changed && definerish(c), report.cells) ||
       any(id -> definerish(old_by_id[id]), removed)
        lock(_MACRO_LOCK) do; delete!(_MACRO_TRIED, report.id); end
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
    nbatch = count(c -> c.state == STALE, report.cells)   # cells about to run → UI shows a stable k/N
    nbatch > 0 && _emit_run_batch(report.id, nbatch)
    prepare!(kernel, report)
    prewarm_usings!(report, kernel)   # precise graph BEFORE keys are computed → stable memo keys
    prewarm_macros!(report, kernel)   # …and macro-recovered bindings (package macros expand pre-run)
    # Static markdown (no `{{ }}` interpolations ⇒ no reads) depends on nothing, so render it FIRST.
    # Otherwise it sits STALE behind slow code cells for the whole run — prose looks "unrun" until the
    # end, which reads as broken now that runs stream cell-by-cell.
    for c in report.cells
        c.kind == MARKDOWN && c.state == STALE && isempty(c.reads) && eval_cell!(report, c, kernel)
    end
    for c in report.cells
        if c.kind == MARKDOWN
            c.state == STALE && eval_cell!(report, c, kernel)   # interpolating md → after its deps ran
        elseif c.state == STALE
            eval_cell!(report, c, kernel)
        end
    end
    refine_usings!(report, kernel)   # barrier `using` cells just ran → resolve their exports, precise-ify deps
    refine_macros!(report, kernel)   # notebook-defined macros now exist → recover macro-hidden writes
    return report
end

# Exported names of a module `path`, resolved WHERE the notebook's cells run (the gate worker for a
# project notebook, in-process otherwise) — reusing `module_help`'s cross-kernel resolution. Empty on
# any failure (module not loaded / not a Module) so the caller keeps the safe barrier.
function _module_exports(kernel::Kernel, report::Report, path::AbstractString)
    rec = try; module_help(kernel, report, path); catch; return Symbol[]; end
    rec isa AbstractDict || return Symbol[]
    # Over the gate the wire is deserialized with SYMBOL keys (in-process keeps String keys), so read
    # both — `module_help`'s own gate wrapper re-keys only the OUTER dict, not the `exports` elements.
    _k(d, k) = haskey(d, k) ? d[k] : get(d, Symbol(k), nothing)
    String(something(_k(rec, "kind"), "")) == "module" || return Symbol[]
    exps = _k(rec, "exports")
    exps isa AbstractVector || return Symbol[]
    out = Symbol[]
    for e in exps
        e isa AbstractDict || continue
        nm = _k(e, "name"); nm === nothing || push!(out, Symbol(String(nm)))
    end
    return out
end

"""
    refine_usings!(report, kernel=InProcessKernel()) -> Bool

Post-eval progressive precision: for each code cell still an :opaque barrier because of a bare
`using X` that has now SUCCESSFULLY run, resolve X's exports and cache them, then rebuild the
dependency graph so the barrier becomes a precise import. No cell is restaled — this runs after a
drain, and narrowing a cell's dependents can only shrink the blast radius (see
[`build_dependencies!`]). Idempotent: each module path is attempted at most once per session.
Returns `true` iff a module was newly resolved (and deps were rebuilt).
"""
function refine_usings!(report::Report, kernel::Kernel = InProcessKernel())
    pending = String[]
    for c in report.cells
        # Only cells that ran cleanly — an errored `using` (package didn't load) can't be resolved,
        # and leaving it un-tried lets a later successful run refine it.
        (c.kind == CODE && c.state == FRESH && :opaque in c.flags) || continue
        top = try; Meta.parseall(c.source); catch; continue; end
        stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
        for s in stmts
            s isa LineNumberNode && continue
            _import_names(s) === nothing && append!(pending, _using_module_paths(s))
        end
    end
    isempty(pending) && return false
    newly = false
    for p in unique!(pending)
        skip = lock(_USING_LOCK) do; p in _USING_TRIED; end
        skip && continue
        syms = _module_exports(kernel, report, p)
        lock(_USING_LOCK) do
            push!(_USING_TRIED, p)
            isempty(syms) || (_USING_EXPORTS[p] = syms; newly = true)   # cache only a real export set
        end
    end
    newly && rebuild_precise!(report)
    return newly
end

# Drop memoized :opaque verdicts and rebuild the graph so newly-resolved exports take effect.
function rebuild_precise!(report::Report)
    lock(_BIND_CACHE_LOCK) do; empty!(_BIND_CACHE); end
    build_dependencies!(report)
    return report
end

# ── Pre-eval `using` resolution (stable memo keys) ────────────────────────────
# The bare-`using` module paths in barrier cells whose exports aren't resolved (nor attempted) yet.
# Pure read — callers that share `report` with a live server take their lock around it.
function unresolved_using_paths(report::Report)
    pending = String[]
    for c in report.cells
        (c.kind == CODE && :opaque in c.flags) || continue
        top = try; Meta.parseall(c.source); catch; continue; end
        stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
        for s in stmts
            s isa LineNumberNode && continue
            _import_names(s) === nothing && append!(pending, _using_module_paths(s))
        end
    end
    return lock(_USING_LOCK) do
        [p for p in unique!(pending) if !haskey(_USING_EXPORTS, p) && !(p in _USING_TRIED)]
    end
end

# Load each module WHERE the cells run and cache its export set — `refine_usings!`'s resolution step
# made available BEFORE the run. The barrier `using` cell is about to load the package anyway, so the
# `import` here is front-loaded work, not new work. A failed import (package not installed) leaves the
# path unresolved AND un-TRIED, so a later drain retries once the package exists. Round-trips to the
# kernel (including a possible worker spawn + package load) — call it OUTSIDE any lock a UI state
# request needs. Returns `true` iff a module was newly resolved.
function resolve_usings!(report::Report, kernel::Kernel, paths::Vector{String})
    newly = false
    for p in paths
        out = try; eval_capture(kernel, report, "import " * p, "prewarm:" * p); catch; nothing; end
        (out === nothing || out.exception !== nothing) && continue
        syms = _module_exports(kernel, report, p)
        isempty(syms) && continue
        lock(_USING_LOCK) do
            push!(_USING_TRIED, p); _USING_EXPORTS[p] = syms
        end
        newly = true
    end
    return newly
end

"""
    prewarm_usings!(report, kernel=InProcessKernel()) -> Bool

Pre-eval counterpart of [`refine_usings!`](@ref): resolve bare-`using` exports BEFORE a run, so the
dependency graph — and every memo key derived from its upstream closures — is computed in precise
form from the very first eval of a session. Without this, a fresh session analysed `using X` as an
:opaque barrier, keyed the first run's memo entries against that conservative graph, then flipped to
the precise graph post-drain (`refine_usings!`) — so every cell below a `using` changed memo keys
between the first and second run of each session and MISSED the durable cache exactly when it
mattered most (cold open). Returns `true` iff a module was newly resolved (deps rebuilt).
"""
function prewarm_usings!(report::Report, kernel::Kernel = InProcessKernel())
    paths = unresolved_using_paths(report)
    isempty(paths) && return false
    resolve_usings!(report, kernel, paths) || return false
    rebuild_precise!(report)
    return true
end

# ── Macro-expansion refinement (unknown macro → precise reads/writes) ─────────────────────────
# An unknown macro hides its true bindings: `@kwdef struct Foo … end` DEFINES `Foo`, but static
# analysis sees only the unexpanded call, so the write edge is missing and editing the struct cell
# never restales its readers — a silent reactivity hole (`_macrocall_arg_refs!` recovers reads
# only). The fix mirrors the `using`-refinement round-trip: expand flagged cells in the kernel
# (where the macros are actually defined — NEVER evaluating, expansion only), re-run EE on the
# expanded form, and UNION the recovered bindings in at graph-build time. Union-only, so precision
# can only add edges, never drop one ("staleness never under-invalidates"). Caches are keyed
# report-id → src-hash; a cell edit re-keys naturally, and `update_source!` clears the tried-set
# when a macro DEFINER changes so its callers get re-expanded.
const _MACRO_BINDS = Dict{String,Dict{UInt64,Tuple{Set{Symbol},Set{Symbol}}}}()  # report.id → src_hash → (reads, writes)
const _MACRO_TRIED = Dict{String,Set{UInt64}}()   # report.id → src_hashes attempted post-drain (failed)
const _MACRO_LOCK  = ReentrantLock()

# EE analysis of an expanded source string → (reads, writes), or `nothing` on parse/EE failure.
# Hygiene: expansion manufactures gensyms (`var"#12#self#"`) — any name containing '#' is
# synthetic, never a notebook binding — and the sanitizer collapses qualified names to `nothing`
# (see `_sanitize_expansion`); both are dropped from both sets.
function _expanded_bindings(src::AbstractString)
    top = try; Meta.parseall(String(src)); catch; return nothing; end
    _has_parse_error(top) && return nothing
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
    blk = Expr(:block, Any[s for s in stmts if !(s isa LineNumberNode)]...)
    node = try; EE.compute_reactive_node(blk); catch; return nothing; end
    clean(names) = Set{Symbol}(n for n in names if n !== :nothing && !occursin('#', String(n)))
    reads = clean(node.references)
    writes = clean(_strip_anon(node.definitions))
    union!(writes, clean(_strip_anon(node.funcdefs_without_signatures)))
    return (reads, writes)
end

"Flagged cells whose macro bindings are still unrecovered (no cache entry, not marked tried)."
function pending_macro_cells(report::Report)
    get(report.meta, "macroexpand", true) === false && return Cell[]   # per-notebook opt-out
    out = Cell[]
    lock(_MACRO_LOCK) do
        binds = get(_MACRO_BINDS, report.id, nothing)
        tried = get(_MACRO_TRIED, report.id, nothing)
        for c in report.cells
            (c.kind == CODE && :macrocall in c.flags) || continue
            binds !== nothing && haskey(binds, c.src_hash) && continue
            tried !== nothing && c.src_hash in tried && continue
            push!(out, c)
        end
    end
    return out
end

"""
    resolve_macros!(report, kernel, cells; mark_tried=false) -> Bool

Round-trip `cells`' sources to the kernel for macro expansion (ONE batched call), re-analyze each
expanded form, and cache the recovered `(reads, writes)`. Returns `true` iff anything newly
resolved (the caller rebuilds the graph). With `mark_tried`, a cell whose expansion failed is
recorded so it isn't round-tripped again (post-drain semantics — its macros had their chance to be
defined); the pre-run pass leaves failures unmarked so the post-drain pass can retry them.
"""
function resolve_macros!(report::Report, kernel::Kernel, cells::Vector{Cell}; mark_tried::Bool = false)
    isempty(cells) && return false
    srcs = Dict{String,String}(c.id => c.source for c in cells)
    expanded = try
        macroexpand_cells(kernel, report, srcs)
    catch e
        # A wire/kernel failure must be VISIBLE (a silent empty result reads as "nothing to
        # recover" and, post-drain, permanently tried-marks every pending cell).
        @warn "deps: macroexpand round-trip failed — keeping conservative analysis" report = report.id exception = e
        Dict{String,String}()
    end
    newly = false
    for c in cells
        ex = get(expanded, c.id, nothing)
        binds = ex === nothing ? nothing : _expanded_bindings(ex)
        lock(_MACRO_LOCK) do
            if binds === nothing
                mark_tried && push!(get!(Set{UInt64}, _MACRO_TRIED, report.id), c.src_hash)
            else
                get!(Dict{UInt64,Tuple{Set{Symbol},Set{Symbol}}}, _MACRO_BINDS, report.id)[c.src_hash] = binds
                newly = true
            end
        end
    end
    return newly
end

"""
    prewarm_macros!(report, kernel=InProcessKernel()) -> Bool

Pre-eval macro expansion (peer of [`prewarm_usings!`](@ref)): recover unknown-macro bindings
BEFORE a run so the graph — and the memo keys derived from it — is precise from the first eval.
Package macros (`Base.@kwdef`, `@enum`, DataFrames' `@chain`, …) expand here because
`prewarm_usings!` already imported their modules; notebook-defined macros resolve post-drain in
[`refine_macros!`](@ref). Failures are NOT marked tried — the macro may get defined during the
run. Returns `true` iff something newly resolved (deps rebuilt).
"""
function prewarm_macros!(report::Report, kernel::Kernel = InProcessKernel())
    cells = pending_macro_cells(report)
    isempty(cells) && return false
    resolve_macros!(report, kernel, cells) || return false
    rebuild_precise!(report)
    return true
end

"""
    refine_macros!(report, kernel=InProcessKernel()) -> Bool

Post-drain macro expansion (peer of [`refine_usings!`](@ref)): by now every macro a cell could
define or import has had its chance to exist, so expand the still-pending cells and mark failures
tried (attempt-once per source; an edit to the cell — or to a macro-defining cell, see
`update_source!` — clears the way for a retry).

Unlike `refine_usings!` (which only NARROWS), recovering a macro-hidden WRITE **adds** an edge.
A PARALLEL drain was scheduled without it, so a reader may have raced its producer (errored on
the not-yet-defined name, or silently consumed the previous run's value) — with
`restale_racers = true` (the parallel server path) everything downstream of a newly-recovered
writer is restaled once ("staleness never under-invalidates") and the caller's runner re-arms.
A serial drain executes in document order — a valid topological order even without the edge —
so the default skips the restale. Returns `true` iff something newly resolved (deps rebuilt).
"""
function refine_macros!(report::Report, kernel::Kernel = InProcessKernel(); restale_racers::Bool = false)
    cells = pending_macro_cells(report)
    isempty(cells) && return false
    resolve_macros!(report, kernel, cells; mark_tried = true) || return false
    rebuild_precise!(report)
    restale_racers || return true
    recovered = Set{String}()   # attempted cells whose recovery included a WRITE (new downstream edges)
    lock(_MACRO_LOCK) do
        nb = get(_MACRO_BINDS, report.id, nothing)
        nb === nothing && return
        for c in cells
            rec = get(nb, c.src_hash, nothing)
            rec !== nothing && !isempty(rec[2]) && push!(recovered, c.id)
        end
    end
    if !isempty(recovered)
        for id in dependents_of(report, recovered)
            id in recovered && continue
            c = get(report.byid, id, nothing)
            c === nothing || (c.state = STALE)
        end
    end
    return true
end
