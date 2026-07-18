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

# A statement whose REFERENCES are deferred to call time — a function/macro definition (long or
# short form). Its body may legitimately name globals defined LOWER in the document (resolved when
# called), so such references are excluded from `reads_now` and never trip the backref diagnostic.
# Struct definitions are NOT deferred: field types/supertypes evaluate at definition time.
_is_deferred_def(s) = s isa Expr && (
    s.head === :function || s.head === :macro ||
    (s.head === :(=) && s.args[1] isa Expr && s.args[1].head in (:call, :where)))

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

# Resolution state (`_USING_EXPORTS`, `_MACRO_BINDS`, and everything derived from them — the
# barrier→precise verdict, provenance graphics/theme classification) feeds cached inference, so a
# `_BIND_CACHE` entry is only valid for the state it was computed under. Rather than trusting
# every mutator to remember `rebuild_precise!` (a non-local invariant a future code path — a pool
# preload, a remote state sync — WILL eventually violate), every mutation bumps this GENERATION
# and every cache entry stamps the generation it was computed at; a mismatch is a cache miss.
# Self-healing regardless of who mutated what. Bumps are rare (once per module path / macro cell
# per session), and invalidation is LAZY — entries recompute one-by-one on next touch, never as a
# burst.
const _RESOLUTION_GEN = Threads.Atomic{Int}(0)
_bump_resolution!() = (Threads.atomic_add!(_RESOLUTION_GEN, 1); nothing)

# ── Durable `using`-export cache (across sessions) ───────────────────────────
# `_USING_EXPORTS` is session-scoped, so every cold open re-paid a kernel round-trip (import + a
# possible package load) per bare-`using` module before the graph/memo keys were precise. Persist
# resolved export sets keyed by "path@version" — a package's exports can genuinely change between
# versions, so the version IS the invalidation (an upgrade re-keys and re-resolves). Only
# registry-sourced deps persist: a path-dev'd package has no stable version, so it stays
# session-only. Best-effort throughout — a missing/corrupt file just means one more round-trip.
const _USING_DISK = Ref{Union{Nothing,Dict{String,Any}}}(nothing)   # lazy in-memory file image
const _USING_DISK_MAX = 500
const _USING_DISK_PATH = Ref(joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "kaimonslate", "usings.json"))

function _using_disk_load()
    lock(_USING_LOCK) do
        if _USING_DISK[] === nothing
            d = try
                p = _USING_DISK_PATH[]
                isfile(p) ? JSON.parse(read(p, String)) : nothing
            catch
                nothing
            end
            img = Dict{String,Any}()   # normalize — JSON.parse returns its own AbstractDict flavour
            d isa AbstractDict && for (k, v) in pairs(d)
                img[String(k)] = v
            end
            _USING_DISK[] = img
        end
        return _USING_DISK[]
    end
end

function _using_disk_store!(key::String, syms::Vector{Symbol})
    d = _using_disk_load()
    lock(_USING_LOCK) do
        d[key] = Dict{String,Any}("t" => round(Int, time()), "syms" => String[string(s) for s in syms])
        if length(d) > _USING_DISK_MAX   # bound the file: drop the oldest entries
            order = sort!(collect(d); by = kv -> (kv[2] isa AbstractDict ? get(kv[2], "t", 0) : 0))
            for (k, _) in Iterators.take(order, length(d) - _USING_DISK_MAX)
                delete!(d, k)
            end
        end
        try
            p = _USING_DISK_PATH[]
            mkpath(dirname(p))
            tmp = p * ".tmp.$(getpid())"
            write(tmp, JSON.json(d))
            mv(tmp, p; force = true)
        catch
        end
    end
    return nothing
end

# ── Provenance-based graphics detection ──────────────────────────────────────
# The lexical `_GRAPHICS_RE` (graphics_detect.jl) misses an ALIASED or RE-EXPORTED plot verb —
# `const draw = lines!` in a helper package, a wrapper that plots — and a miss there risks a
# `ConcurrencyViolationError` crash (two plot cells co-scheduled). Once a Makie-family module's
# exports are RESOLVED (`_USING_EXPORTS` — prewarm/refine/disk seed), derive "touches graphics"
# from dependency facts instead: a cell reading (or providing) ANY name a Makie-family module
# exports is graphics. Name-based, so a user package re-exporting `lines!` is caught the moment
# its own exports resolve. The regex stays as the resolution-free pre-filter and first-drain
# backstop (before anything is resolved, bare-`using` barriers serialize conservatively anyway).
const _GRAPHICS_MODULES = Set{String}(("Makie", "GLMakie", "CairoMakie", "WGLMakie", "RPRMakie"))

"Union of exports of every RESOLVED Makie-family module (empty until one resolves).
Compute once per pass and reuse — don't call per cell."
function _graphics_export_names()
    lock(_USING_LOCK) do
        out = Set{Symbol}()
        for (path, syms) in _USING_EXPORTS
            String(first(split(path, '.'))) in _GRAPHICS_MODULES && union!(out, syms)
        end
        return out
    end
end

"True when `c` touches Makie's shared global state: lexical match, or provenance — any of its
reads/provides is an export of a resolved Makie-family module."
_is_graphics_cell(c::Cell, gnames::Set{Symbol}) =
    _uses_shared_graphics(c.source) ||
    (!isempty(gnames) && (!isdisjoint(c.reads, gnames) || !isdisjoint(c.provides, gnames)))

# name → (version, source) for the notebook env's direct deps, via the kernel's project listing
# (one cheap tool call once the worker is up; in-process kernels return none → session-only).
function _dep_versions(kernel::Kernel, report::Report)
    out = Dict{String,Tuple{String,String}}()
    for d in (try; project_deps(kernel, report); catch; Dict{String,Any}[]; end)
        d isa AbstractDict || continue
        g(k) = (v = haskey(d, k) ? d[k] : get(d, Symbol(k), nothing); v === nothing ? "" : String(v))
        n = g("name")
        isempty(n) || (out[n] = (g("version"), g("source")))
    end
    return out
end

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

# ExpressionExplorer swallows an UNKNOWN macro's arguments whole: `@chain df begin … end`
# yields only `@chain` as a reference — the `df` dataflow edge (and every function the block
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
const _BIND_CACHE = Dict{String,Tuple{UInt64,Set{Symbol},Set{Symbol},Bool,Vector{String},Set{Symbol},Set{Symbol},Bool,Set{Symbol},Int}}()
const _BIND_CACHE_LOCK = ReentrantLock()
# Bounded LRU: entries carry a recency tick (`_BIND_TICKS`, bumped on every hit/store) and overflow
# evicts the least-recently-used ~10% — the old clear-on-full wholesale `empty!` made a long-lived
# multi-notebook server periodically re-infer EVERY open cell at once (a latency cliff on the next
# structural edit). Deleted cells also get targeted eviction in `update_source!`.
const _BIND_CACHE_MAX = 5000
const _BIND_TICK = Ref{UInt64}(0)
const _BIND_TICKS = Dict{String,UInt64}()

# Caller holds _BIND_CACHE_LOCK. Evicts the oldest tenth so evictions amortize (one O(n log n)
# sweep per ~500 misses at the cap, instead of a 5000-cell re-inference burst).
function _bind_cache_evict!()
    order = sort!(collect(_BIND_TICKS); by = last)
    for (id, _) in Iterators.take(order, max(1, _BIND_CACHE_MAX ÷ 10))
        delete!(_BIND_CACHE, id)
        delete!(_BIND_TICKS, id)
    end
    return nothing
end
function infer_bindings!(cell::Cell)
    h = hash(cell.source) ⊻ hash(cell.kind)
    gen = _RESOLUTION_GEN[]   # read BEFORE compute: a mid-inference bump stamps stale → next hit misses
    hit = lock(_BIND_CACHE_LOCK) do
        v = get(_BIND_CACHE, cell.id, nothing)
        v === nothing || (_BIND_TICKS[cell.id] = (_BIND_TICK[] += 1))   # LRU: a hit refreshes recency
        v
    end
    if hit !== nothing && hit[1] == h && hit[10] == gen   # gen mismatch ⇒ resolution state moved ⇒ recompute
        empty!(cell.reads);  union!(cell.reads,  hit[2])
        empty!(cell.writes); union!(cell.writes, hit[3])
        hit[4] ? push!(cell.flags, :opaque) : delete!(cell.flags, :opaque)
        empty!(cell.inputs); append!(cell.inputs, hit[5])   # `@asset` file deps (statically extracted)
        empty!(cell.provides); union!(cell.provides, hit[6])   # `using`/`import`-brought names (⊆ writes)
        empty!(cell.mutates); union!(cell.mutates, hit[7])   # in-place-mutated-only names (⊆ writes, ⊄ defines)
        hit[8] ? push!(cell.flags, :macrocall) : delete!(cell.flags, :macrocall)   # unknown-macro cell (expansion candidate)
        empty!(cell.reads_now); union!(cell.reads_now, hit[9])   # top-level reads (backref diagnostic)
        return cell
    end
    _infer_bindings_uncached!(cell)
    lock(_BIND_CACHE_LOCK) do
        length(_BIND_CACHE) >= _BIND_CACHE_MAX && _bind_cache_evict!()
        _BIND_CACHE[cell.id] = (h, copy(cell.reads), copy(cell.writes), :opaque in cell.flags, copy(cell.inputs), copy(cell.provides), copy(cell.mutates), :macrocall in cell.flags, copy(cell.reads_now), gen)
        _BIND_TICKS[cell.id] = (_BIND_TICK[] += 1)
    end
    return cell
end
# ExpressionExplorer names an anonymous function `__ExprExpl_anon__<rand(UInt64)>` and reports it
# among a cell's definitions. That name is synthetic — never a real global, and RANDOM on every
# re-analysis — so letting it into `writes` poisons everything keyed off the write-set (most visibly
# the memo store guard, which then never caches a cell containing `x -> …` or a do-block). Strip them.
_strip_anon(names) = Iterators.filter(n -> !startswith(String(n), "__ExprExpl_anon__"), names)

function _infer_bindings_uncached!(cell::Cell)
    empty!(cell.reads); empty!(cell.reads_now); empty!(cell.writes); empty!(cell.mutates); empty!(cell.inputs); empty!(cell.provides)
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
        union!(cell.reads_now, cell.reads)   # interpolations render immediately → all top-level
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
                refs = EE.compute_reactive_node(Expr(:block, rm[2])).references
                union!(cell.reads, refs); union!(cell.reads_now, refs)   # init evaluates immediately
                union!(cell.reads, _macrocall_arg_refs!(Set{Symbol}(), rm[2]))
            catch e
                @debug "deps: @reactive init analysis failed" cell = cell.id exception = e
            end
        elseif bm !== nothing
            push!(cell.writes, bm[1])
            try
                refs = EE.compute_reactive_node(Expr(:block, bm[2])).references
                union!(cell.reads, refs); union!(cell.reads_now, refs)   # widget args evaluate immediately
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
            # Top-level reads (backref diagnostic): re-analyze only the NON-deferred statements —
            # a reference inside a function/macro body resolves at call time and must not count.
            imm = Any[s for s in nonbind if !_is_deferred_def(s)]
            if !isempty(imm)
                iblk = Expr(:block, imm...)
                union!(cell.reads_now, EE.compute_reactive_node(iblk).references)
                union!(cell.reads_now, _macrocall_arg_refs!(Set{Symbol}(), iblk))
            end
        catch e
            @debug "deps: cell-body reactive-node analysis failed — falling back to :opaque" cell = cell.id exception = e
            push!(cell.flags, :opaque)
        end
    end
    _is_barrier_expr(top) && push!(cell.flags, :opaque)
    # Makie's global theme is process state no notebook binding carries, so a theme-setting cell
    # writes nothing a plot cell reads — without help, editing the theme re-runs it ALONE and every
    # figure keeps the old theme (dead reactivity). Wire it through the ordinary dataflow: theme
    # setters write a synthetic `_THEME_SENTINEL` (as a MUTATION — consecutive theme cells chain
    # like `push!`ers, and it never reads as a definition/multidef), graphics cells read it. The
    # most-recent-prior-writer rule then gives real theme→plot edges: theme edits restale figures,
    # batch scheduling follows deps, and figure memo keys digest the theme cell's source (a cached
    # figure can't restore under a stale theme). No theme cell above a plot ⇒ read with no writer ⇒
    # no edge — harmless. See graphics_detect.jl.
    if _sets_global_theme(cell.source)
        push!(cell.reads, _THEME_SENTINEL)     # a later setter composes onto the earlier one's state
        push!(cell.writes, _THEME_SENTINEL)
        push!(cell.mutates, _THEME_SENTINEL)
    elseif _uses_shared_graphics(cell.source) ||
           (let g = _graphics_export_names()   # provenance: aliased/re-exported plot verbs (see above);
               !isempty(g) && !isdisjoint(cell.reads, g)   # cache-safe — resolution clears _BIND_CACHE
           end)
        push!(cell.reads, _THEME_SENTINEL)
    end
    return cell
end

# ── Dependency graph (most-recent-prior-writer) ──────────────────────────────

# Manual edges (`needs=id1,id2` header tag): user-asserted dependencies for effects no binding
# carries — a cell that reads a DuckDB TABLE another cell CREATEs shares no variable with it, so
# dataflow analysis sees no edge and staleness/scheduling/memo-keys all miss the coupling. The tag
# names the upstream cell directly; `build_dependencies!` folds it into `deps`, where the ordinary
# machinery takes over (restale propagation, parallel-batch ordering, and `_memo_key`'s transitive
# source digest — an edit to the upstream invalidates the reader's durable memo). Tags are the
# storage; the DAG view's link gesture is just an editor for them. Only an EARLIER CODE cell can
# be named (document order IS topological order — a forward/unknown id adds no edge; the UI flags
# it on the cell so a deleted upstream degrades loudly, not silently).
function _manual_needs(flags::AbstractSet{Symbol})
    out = String[]
    for f in flags
        s = String(f)
        startswith(s, "needs=") || continue
        for t in eachsplit(chopprefix(s, "needs="), ',')
            isempty(t) || push!(out, String(t))
        end
    end
    return out
end
_manual_needs(c::Cell) = _manual_needs(c.flags)

# Manual mutation declarations (`mutates=name1,name2` header tag): user-asserted in-place effects
# the static analysis can't see — `update!(df)` through a function call, mutation via an alias.
# Folded into `cell.mutates` by `build_dependencies!`, where the EXISTING machinery takes over:
# ordering + restale of readers, memo entries snapshotting the post-mutation value, zero-copy
# restore safety, and — at a region boundary — mutation-follows-data routing plus transfer-token
# invalidation (an undeclared hidden mutation there doesn't just go stale, it FORKS the replicas,
# which is why this tag exists). The sibling of `needs=`: that asserts an edge, this asserts what
# the edge means.
function _manual_mutates(flags::AbstractSet{Symbol})
    out = Symbol[]
    for f in flags
        s = String(f)
        startswith(s, "mutates=") || continue
        for t in eachsplit(chopprefix(s, "mutates="), ',')
            isempty(t) || push!(out, Symbol(t))
        end
    end
    return out
end
_manual_mutates(c::Cell) = _manual_mutates(c.flags)

# The `lockedkey=<key>` header tag: a `locked` cell's memo key AS OF the run it froze on — set
# by `set_cell_tags!` (locking, or a forced re-run of an already-locked cell), read at eval time
# (`_prepare_region_for_cell!`'s sibling in server.jl) to restore/pin BY THIS FIXED KEY instead of
# the freshly-computed one, so a locked cell survives upstream drift across a process restart (not
# just the live in-memory FRESH state `update_source!`'s restale-skip protects). Single-valued —
# unlike `needs=`/`mutates=`, a cell has at most one locked key at a time.
function _locked_key(flags::AbstractSet{Symbol})
    for f in flags
        s = String(f)
        startswith(s, "lockedkey=") && return chopprefix(s, "lockedkey=")
    end
    return ""
end
_locked_key(c::Cell) = _locked_key(c.flags)
function _set_locked_key!(c::Cell, key::AbstractString)
    filter!(f -> !startswith(String(f), "lockedkey="), c.flags)
    isempty(key) || push!(c.flags, Symbol("lockedkey=" * key))
    return c
end

# Shared guard for every upstream-change cascade (source edit, bind push, asset watcher, force-run,
# reorder): a locked cell holding a FRESH frozen result stays put — only its OWN ▶ may restale it.
# Returns whether the cell was actually restaled, so callers can track which cells changed.
function restale!(c::Cell)
    (:locked in c.flags && c.state == FRESH) && return false
    c.state = STALE
    return true
end

# Unconditional wipe — a fresh/replaced process has NOTHING established, so every code cell
# (including locked ones) must go STALE with its in-memory output dropped. Bypasses `restale!`'s
# locked guard on purpose: the caller (a full kernel reset) is responsible for reconciling locked
# cells back to FRESH afterward (`_self_heal_locked!`), same as `restart_kernel!` already does.
function reset_all!(report::Report)
    for c in report.cells
        c.state = STALE
        c.output = nothing
    end
    return report
end

# A cell caught mid-run when something invalidated it (an orphaned worker eval, a source edit
# racing its own in-flight run, a bring-up failure) snaps back to STALE so it gets picked up again —
# but only if it's genuinely still RUNNING; a cell that already finished (FRESH/ERRORED) or was never
# started (STALE) is left alone. Returns whether it actually reverted.
function revert_running!(c::Cell)
    c.state == RUNNING || return false
    c.state = STALE
    return true
end

mark_running!(c::Cell) = (c.state = RUNNING; c)

# A state flip with no output involved (markdown render, `@bind` value change, a fresh empty
# cell) — nothing to compute, so no exception to check.
mark_fresh!(c::Cell) = (c.state = FRESH; c)

# ANY→FRESH/ERRORED from a genuine computed output (possibly `nothing` — a scratch eval that
# never ran). Callers that also mirror bind specs (`c.binds = out.binds`) do so themselves;
# whether binds surface differs by site (a scratch eval never does, a real cell always does).
mark_result!(c::Cell, out) = (c.output = out;
    c.state = (out === nothing || out.exception === nothing) ? FRESH : ERRORED; c)

# A failure that never reached the worker (region prime/presync) — synthesize the error output.
mark_errored!(c::Cell, msg::AbstractString) = (
    c.output = CellOutput("", MimeChunk[], Any[], Any[], BindSpec[], "", msg, nothing, 0.0);
    c.state = ERRORED; c)

# Which memo key a cell's next run should target: its pinned `lockedkey=` (a locked cell, not
# forced, already froze on a run) or a freshly computed one (everyone else, or an explicit ▶
# force — the one thing allowed to move the lock). Single source of truth for the locked-vs-
# computed key choice `_eval_one!` makes on every run.
function target_key(cell::Cell, report::Report; forced::Bool = false)::String
    computed_key = _memo_key(report, cell)
    locked = :locked in cell.flags
    lockedkey = locked ? _locked_key(cell) : ""
    return (locked && !forced && !isempty(lockedkey)) ? lockedkey : computed_key
end

# ── Cell effect classification ─────────────────────────────────────────────────────────────────
# ONE source of truth for "what kind of thing does this cell PRODUCE", so the subsystems that decide
# transfer-vs-rerun (regions) and cache-vs-recompute (memo) can't drift. That drift is a real bug
# class: the memo layer knew `set_theme!` was an everywhere effect (it replays it on restore), but the region
# prime list didn't — so remote figures silently lost the theme until both were taught it separately.
# Two orthogonal policies read off this one category:
#   PURE      a deterministic function of source + inputs   → region: TRANSFER the value; memo: cache it.
#   EVERYWHERE a process-local EFFECT with no data deps — pure `using`/`import`, the import scaffold, a
#             `set_theme!`/`update_theme!` setter — self-sufficient, so it RE-RUNS on every side
#             (never shipped) and primes at connect (`_prime_namespace!`); memo replays its source.
#   RESOURCE  a live handle (DB/socket/file) opened FROM data deps → re-run per side but only once its
#             inputs are staged, so it REPLAYS at read (`_ensure_resource_on!`); never cached.
#   VOLATILE  non-deterministic (`rand`/`now`) → region: TRANSFER (so both sides agree); never cached.
#   IMPURE    marked mutating external/shared state → run where its state lives; not cacheable.
# Order matters: an explicit tag (`resource`/`volatile`) wins over the inferred using/scaffold/theme
# shape. This is the classifier; each consumer maps a category to its own policy (region ≠ memo axis:
# VOLATILE transfers but isn't cached, RESOURCE re-runs but isn't cached — hence a taxonomy, not a flag).
@enum CellEffect PURE EVERYWHERE RESOURCE VOLATILE IMPURE
function _cell_effect(cell)::CellEffect
    cell.kind == CODE || return PURE
    :resource in cell.flags && return RESOURCE
    :volatile in cell.flags && return VOLATILE
    # `:everywhere` — a RUNTIME-DECLARED everywhere effect (`slate_effect(:everywhere)` harvested from the
    # run, recorded on the cell by `_apply_cell_effects!`). Generalizes the static `import_scaffold`/theme
    # cases: a cell that registers process-global state (a custom op, a global config) declares it and is
    # established on every region worker — no colocated `using` or hardcoded sentinel needed. Conceptually
    # the notebook/region analogue of `Distributed.@everywhere` (run this on every worker).
    (_is_pure_using(cell.source) || :import_scaffold in cell.flags || :everywhere in cell.flags ||
        _THEME_SENTINEL in cell.writes) && return EVERYWHERE
    return PURE
end

"""
    build_dependencies!(report) -> report

Re-infer bindings and compute each code cell's upstream `deps` (ids). A cell
depends on the most recent prior writer of each name it reads, plus any earlier
cells its `needs=` tag names (user-asserted effect edges). An `:opaque` cell
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
        # `mutates=` declarations: assert the in-place effects analysis can't see (f!(x) through a
        # call, aliases). Mirrors the native analysis invariant `mutates ⊆ writes`: a mutator IS a
        # writer, so later readers chain off it (ordering + restale), and it's also a READ (ordered
        # after the original writer).
        for m in _manual_mutates(c)
            push!(c.mutates, m); push!(c.writes, m); push!(c.reads, m)
        end
        empty!(c.deps)
    end
    _scan_imports!(report)                 # notebook-level `@use` import-map declarations → report.meta
    writer = Dict{Symbol,String}()        # name → id of most-recent prior writer
    barrier::Union{String,Nothing} = nothing
    seen = String[]
    pending_reads = Dict{Symbol,String}() # name → FIRST cell to read it top-level with no prior writer
    priorcode = Set{String}()             # ids of earlier CODE cells — the only legal `needs=` targets
    for c in report.cells
        if c.kind == MARKDOWN
            # md cells depend on the writers of their interpolation vars (+ barrier),
            # but never write, become a barrier, or enter `seen`.
            for r in c.reads
                haskey(writer, r) && push!(c.deps, writer[r])
            end
            for r in c.reads_now
                haskey(writer, r) || get!(pending_reads, r, c.id)
            end
            for t in _manual_needs(c)
                t in priorcode && push!(c.deps, t)
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
        for r in c.reads_now
            haskey(writer, r) || get!(pending_reads, r, c.id)
        end
        for t in _manual_needs(c)
            t in priorcode && push!(c.deps, t)
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
        push!(priorcode, c.id)
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
    # Import-scaffold ⇒ a `using`/`import` cell is memoizable. A cell that mixes a `using X` with
    # real compute normally can't be memoized: it PROVIDES X's names, and a plain restore would skip
    # the `using` (its method-table / name-in-scope effect), so `_memoizable` bails on any provider.
    # But `provides` holds ONLY import-brought names (function/struct DEFS land in `writes`, never
    # here — see the statement loop), and an import's effect is a pure function of (its source, the
    # resolved environment). So we can cache the cell's genuinely-defined values (`writes ∖ provides`)
    # and, on restore, REPLAY just the cell's `using`/`import` statements (cheap — the package is
    # already loaded) to re-establish scope. That makes every NON-OPAQUE provider memoizable:
    #   • `:import_scaffold` — memoizable; the worker replays the usings on restore so a NOVEL
    #     `using X` (the sole importer of X) keeps X's names in scope for any downstream cell that
    #     later RE-RUNS. Unlocks e.g. `using SolverPkg, HelperPkg; result = solve(...)`.
    #   • `:using_redundant` — the stricter subset where EVERY provided name is already in scope from
    #     an upstream cell, so the replay is a proven no-op (kept as a hint; not required for safety).
    # A cell reaching here with non-empty `provides` is non-opaque by construction (an UNRESOLVED
    # `using` pushes `:opaque` and leaves `provides` empty), so its import names are known and its
    # `using` source is safe to replay. Doc-order sweep (sibling of the multidef sweep above).
    provided_upstream = Set{Symbol}()
    for c in report.cells
        c.kind == CODE || continue
        delete!(c.flags, :using_redundant); delete!(c.flags, :import_scaffold)
        if !isempty(c.provides)
            push!(c.flags, :import_scaffold)
            all(n -> n in provided_upstream, c.provides) && push!(c.flags, :using_redundant)
        end
        union!(provided_upstream, c.provides)
    end
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
    # Ordering footgun (`backref`, peer of `multidef`): a name read at TOP LEVEL above its only
    # definer. Edges only point backward, so document order silently swallows that dependency —
    # the first run errors (or a re-run consumes the PREVIOUS run's value) and editing the definer
    # never restales the reader. Informational only, no DAG change; deferred (function-body) reads
    # were excluded at inference (`reads_now`), so `f() = g()` with `g` below never trips it.
    backref = Dict{String,Vector{String}}()   # name → [reader_id, definer_id] (first reader; final definer)
    for (name, rid) in pending_reads
        wid = get(writer, name, nothing)
        (wid === nothing || wid == rid) && continue          # never written, or self — not an ordering issue
        wc = report.byid[wid]
        (name in wc.provides || name in wc.mutates) && continue   # imported/mutated below, not DEFINED below
        backref[string(name)] = String[rid, wid]
    end
    report.meta["backref"] = backref
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
        lock(_BIND_CACHE_LOCK) do   # targeted LRU eviction — a deleted cell's entry is dead weight
            for id in removed
                delete!(_BIND_CACHE, id)
                delete!(_BIND_TICKS, id)
            end
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
        c === nothing && continue
        # `locked`: freeze a cell that already has a result against upstream churn — it only
        # re-runs on an explicit ▶ (force) or an edit to ITS OWN source (already marked STALE
        # above, before this loop, so `c.state` is no longer FRESH and restale! lets it through).
        restale!(c)
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
    vers = Dict{String,Tuple{String,String}}()   # fetched lazily — only if something is un-tried
    for p in unique!(pending)
        skip = lock(_USING_LOCK) do; p in _USING_TRIED; end
        skip && continue
        syms = _module_exports(kernel, report, p)
        lock(_USING_LOCK) do
            push!(_USING_TRIED, p)
            isempty(syms) || (_USING_EXPORTS[p] = syms; newly = true)   # cache only a real export set
        end
        isempty(syms) || _bump_resolution!()
        if !isempty(syms)   # persist for the next session's cold open (registry versions only)
            isempty(vers) && (vers = _dep_versions(kernel, report))
            v, src = get(vers, String(first(split(p, '.'))), ("", ""))
            !isempty(v) && src == "registry" && _using_disk_store!("$p@$v", syms)
        end
    end
    newly && rebuild_precise!(report)
    return newly
end

# Drop memoized inference verdicts for THIS report's cells and rebuild the graph so
# newly-resolved exports / macro expansions take effect. Scoped eviction: the bind cache is
# shared across every open notebook, so a wholesale `empty!` here made one notebook's refinement
# re-infer every OTHER notebook's cells on their next edit (the same latency cliff the LRU
# eviction exists to avoid). Cross-notebook id collisions (two notebooks both naming a cell
# `theme`) evict a stranger's entry — the src-hash validation makes that cost one re-inference,
# never a wrong result.
function rebuild_precise!(report::Report)
    lock(_BIND_CACHE_LOCK) do
        for c in report.cells
            delete!(_BIND_CACHE, c.id)
            delete!(_BIND_TICKS, c.id)
        end
    end
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
    vers = _dep_versions(kernel, report)
    disk = _using_disk_load()
    remaining = String[]
    for p in paths
        # Disk hit for the env's EXACT version → seed without the import round-trip. The `using`
        # cell itself still loads the package when it runs; only the resolution is front-loaded.
        v, src = get(vers, String(first(split(p, '.'))), ("", ""))
        rec = (!isempty(v) && src == "registry") ? get(disk, "$p@$v", nothing) : nothing
        syms = rec isa AbstractDict ? Symbol[Symbol(String(s)) for s in get(rec, "syms", Any[])] : Symbol[]
        if !isempty(syms)
            lock(_USING_LOCK) do
                push!(_USING_TRIED, p); _USING_EXPORTS[p] = syms
            end
            _bump_resolution!()
            newly = true
        else
            push!(remaining, p)
        end
    end
    for p in remaining
        out = try; eval_capture(kernel, report, "import " * p, "prewarm:" * p); catch; nothing; end
        (out === nothing || out.exception !== nothing) && continue
        syms = _module_exports(kernel, report, p)
        isempty(syms) && continue
        lock(_USING_LOCK) do
            push!(_USING_TRIED, p); _USING_EXPORTS[p] = syms
        end
        _bump_resolution!()
        v, src = get(vers, String(first(split(p, '.'))), ("", ""))
        !isempty(v) && src == "registry" && _using_disk_store!("$p@$v", syms)
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
        Dict{String,Tuple{Set{Symbol},Set{Symbol}}}()
    end
    newly = false
    for c in cells
        binds = get(expanded, c.id, nothing)   # already analyzed WHERE the macros live (macroexpand.jl)
        lock(_MACRO_LOCK) do
            if binds === nothing
                mark_tried && push!(get!(Set{UInt64}, _MACRO_TRIED, report.id), c.src_hash)
            else
                get!(Dict{UInt64,Tuple{Set{Symbol},Set{Symbol}}}, _MACRO_BINDS, report.id)[c.src_hash] = binds
                newly = true
            end
        end
        binds === nothing || _bump_resolution!()
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
            c === nothing || restale!(c)
        end
    end
    return true
end
