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

# `include(...)` runs external code whose definitions aren't visible to static analysis, so a cell
# containing one is a barrier (downstream cells conservatively depend on it).
#
# `eval` is the same problem arriving by a different road. `@eval x = 1`, `eval(:(x = 1))` and
# `Core.eval(m, ex)` all bind a global that no amount of macro expansion can reveal, because the
# expression is assembled at RUN time — the notebook's macro-aware pass (macroexpand.jl) resolves
# `@enum` and `Base.@kwdef` precisely, and can say nothing at all about these. Left unmarked, the
# reader of such a global keeps a stale value with no error and no stale marker.
#
# (`using`/`import` are handled precisely in the statement loop — see `_import_names` — so
# a self-contained `import X` no longer chains every cell below it.)
_is_barrier_callee(f) =
    f === :include || f === :eval ||
    (f isa Expr && f.head === :. && length(f.args) == 2 && f.args[2] isa QuoteNode &&
     f.args[2].value in (:include, :eval))          # Core.eval / Base.eval / M.include
function _is_barrier_expr(ex)
    ex isa Expr || return false
    ex.head === :call && !isempty(ex.args) && _is_barrier_callee(ex.args[1]) && return true
    ex.head === :macrocall && !isempty(ex.args) && ex.args[1] === Symbol("@eval") && return true
    return any(_is_barrier_expr, ex.args)
end

# A statement whose REFERENCES are deferred to call time — a function/macro definition (long or
# short form). Its body may legitimately name globals defined LOWER in the document (resolved when
# called), so such references are excluded from `reads_now` and never trip the backref diagnostic.
# Struct definitions are NOT deferred: field types/supertypes evaluate at definition time.
# A docstring or `@inline` around the definition doesn't change that, and neither does binding an
# anonymous function to a global (`h = () -> a`).
function _is_deferred_def(s)
    s = _unwrap_definition(s)
    s isa Expr || return false
    (s.head === :function || s.head === :macro) && return true
    s.head === :(=) && length(s.args) == 2 || return false
    s.args[1] isa Expr && s.args[1].head in (:call, :where, :(::)) && return _def_signature(s) !== nothing
    return s.args[1] isa Symbol && s.args[2] isa Expr && s.args[2].head === :(->)
end

# Calls in `ex` by a plain name, with the base name of each positional argument (`nothing` when the
# argument isn't a name or a field/index path off one): what lets a mutated parameter be traced back
# to the global the caller passed.
function _named_calls!(out::Vector{Tuple{Symbol,Vector{Union{Symbol,Nothing}}}}, ex)
    ex isa Expr || return out
    if ex.head === :call && !isempty(ex.args) && ex.args[1] isa Symbol
        args = Union{Symbol,Nothing}[_base_symbol(a) for a in ex.args[2:end]
                                     if !(a isa Expr && a.head in (:parameters, :kw))]
        push!(out, (ex.args[1], args))
    end
    for a in ex.args
        _named_calls!(out, a)
    end
    return out
end

# (name, positional parameter names, body) of a deferred definition, or nothing for one that isn't a
# plainly named function (a macro, a qualified `Base.show` extension).
function _function_parts(s)
    d = _unwrap_definition(s)
    d isa Expr || return nothing
    if d.head === :(=) && d.args[1] isa Symbol && d.args[2] isa Expr && d.args[2].head === :(->)
        a = d.args[2].args[1]
        ps = a isa Expr && a.head === :tuple ? a.args : Any[a]
        return (d.args[1], Union{Symbol,Nothing}[_param_name(p) for p in ps if !(p isa Expr && p.head === :parameters)],
                d.args[2].args[2])
    end
    d.head === :macro && return nothing
    sig = _def_signature(d)
    (sig === nothing || !(sig.args[1] isa Symbol)) && return nothing
    ps = Union{Symbol,Nothing}[_param_name(p) for p in sig.args[2:end] if !(p isa Expr && p.head === :parameters)]
    return (sig.args[1], ps, d.args[2])
end
_param_name(p::Symbol) = p
_param_name(p::Expr) = p.head in (:(::), :kw, :(=), :(...)) && !isempty(p.args) ? _param_name(p.args[1]) : nothing
_param_name(::Any) = nothing

# Names assigned inside the soft scopes of a cell's top level: the body of a `for`, `while` or `try`
# outside any function, `let` or comprehension. Notebook cells evaluate with the REPL's soft-scope
# rule, so such an assignment updates the global when one exists; the dataflow pass reads it as a
# local of the loop. Loop variables and `local` declarations are left out.
function _soft_assigns!(out::Set{Symbol}, ex, insoft::Bool = false, locals::Set{Symbol} = Set{Symbol}())
    ex isa Expr || return out
    h = ex.head
    (_is_deferred_def(ex) || h in (:let, :comprehension, :generator, :(->), :function, :macro, :struct, :module, :quote)) && return out
    if h === :for || h === :while
        loc = copy(locals)
        if h === :for
            specs = ex.args[1]
            for sp in (specs isa Expr && specs.head === :block ? specs.args : Any[specs])
                sp isa Expr && sp.head === :(=) && _loopvars!(loc, sp.args[1])
            end
        end
        for a in ex.args[2:end]; _soft_assigns!(out, a, true, loc); end
        return out
    elseif h === :try
        for a in ex.args; _soft_assigns!(out, a, true, copy(locals)); end
        return out
    elseif h === :local
        for a in ex.args; _loopvars!(locals, a isa Expr && a.head === :(=) ? a.args[1] : a); end
        return out
    elseif insoft && (h === :(=) || (_is_update_head(h) && !startswith(string(h), "."))) && ex.args[1] isa Symbol
        n = ex.args[1]
        n in locals || push!(out, n)
    end
    for a in ex.args; _soft_assigns!(out, a, insoft, locals); end
    return out
end
_loopvars!(s::Set{Symbol}, x::Symbol) = push!(s, x)
_loopvars!(s::Set{Symbol}, x::Expr) = (for a in x.args; _loopvars!(s, a); end; s)
_loopvars!(s::Set{Symbol}, ::Any) = s

# The summaries of the functions a cell's deferred definitions define (see `FuncSummary`).
function _summarize_functions!(cell::Cell, stmts)
    for s in stmts
        _is_deferred_def(s) || continue
        parts = _function_parts(s)
        parts === nothing && continue
        name, params, body = parts
        refs = try
            Set{Symbol}(EE.compute_reactive_node(_unwrap_definition(s)).references)
        catch
            Set{Symbol}()
        end
        delete!(refs, name)
        sm = get!(() -> FuncSummary(params), cell.funcs, name)
        union!(sm.refs, refs)
        union!(sm.writes, _collect_global_decls!(Set{Symbol}(), body))
        mw = Set{Symbol}(); mr = Set{Symbol}(); _collect_mutations!(mw, mr, body)
        for n in mw
            k = findfirst(==(n), params)
            k === nothing ? (n in refs && push!(sm.mut_g, n)) : push!(sm.mut_p, k)
        end
        _named_calls!(sm.calls, body)
    end
    return cell
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

# Base name of an assignment/index/field target (`data[i]` → :data, `a.b.c` → :a). A dotted CALL
# (`f.(x)`) shares the `:.` head with field access but names a FUNCTION, not a target, so it has no
# base symbol — otherwise `sort!(f.(v))` reads as mutating `f`. Field access carries a QuoteNode
# second argument; a broadcast carries an argument tuple.
_base_symbol(s::Symbol) = s
function _base_symbol(e::Expr)
    e.head === :ref && return _base_symbol(e.args[1])
    e.head === :. || return nothing
    (length(e.args) >= 2 && e.args[2] isa Expr && e.args[2].head === :tuple) && return nothing
    return _base_symbol(e.args[1])
end
_base_symbol(::Any) = nothing

# The `f!(x, …)` mutation convention needs a real function NAME before the bang. `!` and `.!` are
# the NEGATION operators and also "end with !", but `!x` reads x, it does not mutate it — without
# this, every cell that negated a value claimed to write it, chaining unrelated cells together and
# raising phantom "defined in more than one cell" conflicts.
function _is_bang_name(f::Symbol)
    s = string(f)
    (length(s) > 1 && endswith(s, "!")) || return false
    return Base.isidentifier(rstrip(s, '!'))
end

const _BROADCAST_ASSIGN = Symbol(".=")

# Updating assignment heads: `+=`, `.*=`, `|=`, … — every `op=` the parser produces, minus the
# comparisons that merely end in `=`.
function _is_update_head(h::Symbol)
    s = string(h)
    length(s) >= 2 && endswith(s, "=") || return false
    return !(s in ("==", "===", "!=", "!==", "<=", ">=", ".==", ".!=", ".<=", ".>=", ".===", ".!==", ":="))
end

# A bang callee, bare (`push!`) or qualified (`Base.setindex!`).
_bang_callee(f::Symbol) = _is_bang_name(f)
_bang_callee(f::Expr) = f.head === :. && length(f.args) == 2 && f.args[2] isa QuoteNode &&
                        f.args[2].value isa Symbol && _is_bang_name(f.args[2].value)
_bang_callee(::Any) = false

# Walk the AST collecting in-place mutation as writes (also reads — you read the object to mutate
# it). Covers `f!(x, …)` and `Mod.f!(x, …)`, `x[i] = …`, `x.f = …`, `x .= …`, and the updating forms
# of each: `x[i] += 1`, `c[] -= 1`, `x.f *= 2`, `v .*= 2`. A plain `s += 1` rebinds `s` rather than
# mutating it, which the dataflow pass already records as a read and a write.
function _collect_mutations!(writes::Set{Symbol}, reads::Set{Symbol}, ex)
    if ex isa Expr
        if ex.head === :call && length(ex.args) >= 2 && _bang_callee(ex.args[1])
            b = _base_symbol(ex.args[2])
            b === nothing || (push!(writes, b); push!(reads, b))
        elseif (ex.head === :(=) || ex.head === _BROADCAST_ASSIGN || _is_update_head(ex.head)) && !isempty(ex.args)
            lhs = ex.args[1]
            dotted = startswith(string(ex.head), ".")
            if dotted || (lhs isa Expr && (lhs.head === :ref || lhs.head === :.))
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

# `global x` declarations, recorded as writes.
#
# ExpressionExplorer reads `let v = 1; global v = 2; end` as introducing a LOCAL `v` and reports no
# definition at all. Julia disagrees: one `global v` anywhere in a scope makes EVERY `v` in that
# scope the global, so both lines assign it. The cell genuinely binds `v` while the analysis says it
# binds nothing — which costs the reactive edge, and a missing edge is not a missing optimisation.
# Its reader keeps showing a stale value with no error, or on a first run reaches a binding that has
# not been created yet and fails on world age.
#
# Unlike the mutation scan above this is EXACT, not a heuristic: `global x` is a declaration of
# intent to bind the global, so there is no `globals` set to filter against and no false positive to
# guard. Scope-blind for the same reason — the declaration means the same thing wherever it sits.
#
# Deferred definitions are skipped: a `global` in a function BODY binds when the function is called,
# not when the cell defining it runs, and counting it would wire an edge from every helper.
function _collect_global_decls!(names::Set{Symbol}, ex)
    ex isa Expr || return names
    _is_deferred_def(ex) && return names
    if ex.head === :global
        for a in ex.args
            _global_decl_name!(names, a)
        end
    end
    for a in ex.args
        _collect_global_decls!(names, a)
    end
    return names
end
# The bound name(s) in one `global` argument: `x`, `x = v`, `x::T = v`, `x, y = f()`.
function _global_decl_name!(names::Set{Symbol}, a)
    if a isa Symbol
        a === :_ || push!(names, a)          # `_` is a discard, never a binding
    elseif a isa Expr
        if a.head === :(=) || a.head === :(::)
            _global_decl_name!(names, a.args[1])
        elseif a.head === :tuple
            for x in a.args; _global_decl_name!(names, x); end
        end
    end
    return names
end

# Statically collect the file paths a cell references via `@asset "path"` (or `@asset bytes
# "path"`) — a STRING-LITERAL arg to an `@asset` macrocall, anywhere in the AST — and via
# `include("path")`, which the notebook namespace resolves the same way (widgets.jl). Because the
# path is a literal in the source, this is known WITHOUT running the cell, so the file becomes
# a first-class reactive/memo input (the watcher arms on open; the memo key folds its hash).
# A computed path (`readfile(x)`, `include(f)`) is invisible here — the documented dynamic caveat.
# Only paths written IN THE CELL are collected: a file included by an included file is analyzed for
# what it defines (`_splice_includes`) but is not itself a watched input.
function _collect_asset_paths!(paths::Vector{String}, ex)
    if ex isa Expr
        if ex.head === :macrocall && !isempty(ex.args) && ex.args[1] === Symbol("@asset")
            for a in ex.args[2:end]
                a isa AbstractString && push!(paths, String(a))
            end
        end
        let ip = _literal_include_path(ex)
            ip === nothing || push!(paths, ip)
        end
        for a in ex.args
            _collect_asset_paths!(paths, a)
        end
    end
    return paths
end

# Statically collect the controls a cell names in `bind_observable(:name)`, anywhere in the AST. Only
# a literal symbol counts: a computed name (`bind_observable(s)`) is unknown until the cell runs.
function _collect_observed_binds!(names::Set{Symbol}, ex)
    if ex isa Expr
        if ex.head === :call && length(ex.args) == 2 && ex.args[1] === :bind_observable &&
           ex.args[2] isa QuoteNode && ex.args[2].value isa Symbol
            push!(names, ex.args[2].value)
        end
        for a in ex.args
            _collect_observed_binds!(names, a)
        end
    end
    return names
end

# Does the cell include a file by literal path? Such a cell gets the same expansion round-trip as an
# unknown-macro cell: the statements of what it includes are spliced in worker-side and re-analyzed,
# which is the only way the names the FILE defines can become this cell's writes (`_splice_includes`).
function _has_literal_include(ex)
    ex isa Expr || return false
    _literal_include_path(ex) === nothing || return true
    return any(_has_literal_include, ex.args)
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
const _BIND_CACHE = Dict{String,Tuple{UInt64,Set{Symbol},Set{Symbol},Bool,Vector{String},Set{Symbol},Set{Symbol},Bool,Set{Symbol},Int,Set{Symbol},
                                     Dict{Symbol,FuncSummary},Vector{Tuple{Symbol,Vector{Union{Symbol,Nothing}}}},Set{Symbol}}}()
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
        empty!(cell.observes); union!(cell.observes, hit[11])   # `bind_observable(:name)` controls
        empty!(cell.funcs); for (k, v) in hit[12]; cell.funcs[k] = copy(v); end   # function summaries
        empty!(cell.topcalls); append!(cell.topcalls, hit[13])
        empty!(cell.soft_assigns); union!(cell.soft_assigns, hit[14])
        return cell
    end
    _infer_bindings_uncached!(cell)
    lock(_BIND_CACHE_LOCK) do
        length(_BIND_CACHE) >= _BIND_CACHE_MAX && _bind_cache_evict!()
        _BIND_CACHE[cell.id] = (h, copy(cell.reads), copy(cell.writes), :opaque in cell.flags, copy(cell.inputs), copy(cell.provides), copy(cell.mutates), :macrocall in cell.flags, copy(cell.reads_now), gen, copy(cell.observes),
                                Dict{Symbol,FuncSummary}(k => copy(v) for (k, v) in cell.funcs), copy(cell.topcalls),
                                copy(cell.soft_assigns))
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
    empty!(cell.reads); empty!(cell.reads_now); empty!(cell.writes); empty!(cell.mutates); empty!(cell.inputs); empty!(cell.provides); empty!(cell.observes)
    empty!(cell.funcs); empty!(cell.topcalls); empty!(cell.soft_assigns)
    delete!(cell.flags, :opaque); delete!(cell.flags, :macrocall)
    if cell.kind == MARKDOWN || cell.kind == WEB
        # A markdown or web cell "reads" the free variables of its `{{ expr }}` blocks, so it joins the
        # reactive graph and re-renders when they change. (A web cell's source is a `@web(...)` macrocall;
        # its interpolations live inside string sections, so harvest them here rather than via the CODE
        # path, which would only see an opaque unknown macro.) Web cells define nothing → no writes.
        exprs = cell.kind == MARKDOWN ? _md_interp_exprs(cell.source) : _web_interp_exprs(cell.source)
        for e in exprs
            ast = try; Meta.parse(e); catch; nothing; end
            ast === nothing && continue
            try
                union!(cell.reads, EE.compute_reactive_node(Expr(:block, ast)).references)
            catch e
                @debug "deps: {{ }} reactive-node analysis failed" cell = cell.id kind = cell.kind exception = e
            end
        end
        # A ```lang fence desugars to a `slate_render_fence(…)` call of string literals (see
        # `_desugar_fences`). The helper is injected into every notebook namespace, never defined by a
        # cell, so it can carry no edge — but left in `reads` it would show up in the cell's "reads"
        # diagnostics as a phantom dependency on a name the author never wrote.
        delete!(cell.reads, :slate_render_fence)
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
    # An unknown macro hides its true bindings from the static pass (see `_macrocall_arg_refs!`), and
    # so does `include("file.jl")` (the definitions are in the FILE); flag the cell so the expansion
    # refinement recovers them — for a macro, once it's resolvable; for an include, from the file.
    (_has_unknown_macrocall(top) || _has_literal_include(top)) && push!(cell.flags, :macrocall)
    # `@asset "path"` / `include "path"` file deps — literal paths anywhere in the cell (sorted+unique
    # for a stable key).
    let ap = _collect_asset_paths!(String[], top)
        isempty(ap) || append!(cell.inputs, sort!(unique!(ap)))
    end
    _collect_observed_binds!(cell.observes, top)
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
            union!(cell.writes, _collect_global_decls!(Set{Symbol}(), blk))
            # A function body mutates when the function is called, so only the cell's immediate code
            # counts here; the bodies go into the cell's function summaries, which its callers take on.
            # The same split gives the top-level reads (backref diagnostic): a reference inside a
            # function/macro body resolves at call time and must not count.
            imm = Any[s for s in nonbind if !_is_deferred_def(s)]
            if !isempty(imm)
                iblk = Expr(:block, imm...)
                _record_global_mutations!(cell, iblk, node.references)
                union!(cell.reads_now, EE.compute_reactive_node(iblk).references)
                union!(cell.reads_now, _macrocall_arg_refs!(Set{Symbol}(), iblk))
                _named_calls!(cell.topcalls, iblk)
                _soft_assigns!(cell.soft_assigns, iblk)
            end
            _summarize_functions!(cell, nonbind)
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

# Header-tag readers/writers share three shapes. `_tag_list` collects a comma-split multi-value tag
# (`prefix=a,b`) into strings; `_tag_value` reads a single-valued tag (`prefix=x`); `_set_tag_value!`
# replaces a single-valued tag in-place (dropping any prior copy, omitting an empty value).
_tag_list(flags::AbstractSet{Symbol}, prefix::AbstractString) = begin
    out = String[]
    for f in flags
        s = String(f)
        startswith(s, prefix) || continue
        for t in eachsplit(chopprefix(s, prefix), ',')
            isempty(t) || push!(out, String(t))
        end
    end
    out
end
_tag_value(flags::AbstractSet{Symbol}, prefix::AbstractString) = begin
    for f in flags
        s = String(f)
        startswith(s, prefix) && return chopprefix(s, prefix)
    end
    return ""
end
function _set_tag_value!(flags::AbstractSet{Symbol}, prefix::AbstractString, value::AbstractString)
    filter!(f -> !startswith(String(f), prefix), flags)
    isempty(value) || push!(flags, Symbol(prefix * value))
    return flags
end

# Manual edges (`needs=id1,id2` header tag): user-asserted dependencies for effects no binding
# carries — a cell that reads a DuckDB TABLE another cell CREATEs shares no variable with it, so
# dataflow analysis sees no edge and staleness/scheduling/memo-keys all miss the coupling. The tag
# names the upstream cell directly; `build_dependencies!` folds it into `deps`, where the ordinary
# machinery takes over (restale propagation, parallel-batch ordering, and `_memo_key`'s transitive
# source digest — an edit to the upstream invalidates the reader's durable memo). Tags are the
# storage; the DAG view's link gesture is just an editor for them. Only an EARLIER CODE cell can
# be named (document order IS topological order — a forward/unknown id adds no edge; the UI flags
# it on the cell so a deleted upstream degrades loudly, not silently).
_manual_needs(flags::AbstractSet{Symbol}) = _tag_list(flags, "needs=")
_manual_needs(c::Cell) = _manual_needs(c.flags)

# Manual mutation declarations (`mutates=name1,name2` header tag): user-asserted in-place effects
# the static analysis can't see — `update!(df)` through a function call, mutation via an alias.
# Folded into `cell.mutates` by `build_dependencies!`, where the EXISTING machinery takes over:
# ordering + restale of readers, memo entries snapshotting the post-mutation value, zero-copy
# restore safety, and — at a region boundary — mutation-follows-data routing plus transfer-token
# invalidation (an undeclared hidden mutation there doesn't just go stale, it FORKS the replicas,
# which is why this tag exists). The sibling of `needs=`: that asserts an edge, this asserts what
# the edge means.
_manual_mutates(flags::AbstractSet{Symbol}) = Symbol[Symbol(t) for t in _tag_list(flags, "mutates=")]
_manual_mutates(c::Cell) = _manual_mutates(c.flags)

# The `lockedkey=<key>` header tag: a `locked` cell's memo key AS OF the run it froze on — set
# by `set_cell_tags!` (locking, or a forced re-run of an already-locked cell), read at eval time
# (`_prepare_region_for_cell!`'s sibling in server.jl) to restore/pin BY THIS FIXED KEY instead of
# the freshly-computed one, so a locked cell survives upstream drift across a process restart (not
# just the live in-memory FRESH state `update_source!`'s restale-skip protects). Single-valued —
# unlike `needs=`/`mutates=`, a cell has at most one locked key at a time.
_locked_key(flags::AbstractSet{Symbol}) = _tag_value(flags, "lockedkey=")
_locked_key(c::Cell) = _locked_key(c.flags)
function _set_locked_key!(c::Cell, key::AbstractString)
    _set_tag_value!(c.flags, "lockedkey=", key)
    return c
end

# The `frozenat=<stamp>` header tag: a `locked` cell's FREEZE IDENTITY — bumped (from code-key + run
# time) every time the cell establishes a NEW frozen value (a lock, or a forced re-run), never on a
# plain restore. Locking exists for outputs that ISN'T reproducible from code (a benchmark, an ML
# training run, sampled data), so a locked cell's identity for DOWNSTREAM memoization can't be its
# source alone — two runs of identical code yield different frozen values. Downstream `_memo_key` folds
# this stamp in, so a dependent re-keys (and re-stores) when the frozen value is refreshed and restores
# consistently on reopen, instead of pulling a result computed against a stale frozen value. Persisted
# in the `.jl` header so it's stable across a restart. Single-valued, like `lockedkey=`.
_frozen_stamp(flags::AbstractSet{Symbol}) = _tag_value(flags, "frozenat=")
_frozen_stamp(c::Cell) = _frozen_stamp(c.flags)
function _set_frozen_stamp!(c::Cell, stamp::AbstractString)
    _set_tag_value!(c.flags, "frozenat=", stamp)
    return c
end

# Shared guard for every upstream-change cascade (source edit, bind push, asset watcher, force-run,
# reorder): a locked cell holding a FRESH frozen result stays put — only its OWN ▶ may restale it.
# Returns whether the cell was actually restaled, so callers can track which cells changed.
function restale!(c::Cell)
    (:locked in c.flags && c.state == FRESH) && return false
    c.state = STALE
    bump_rev!(c)
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

# Every change worth pushing gets a new stamp, from ONE process-wide counter.
#
# The browser is told about a cell over two transports — the live `celldone:`/`refresh:` push and the
# full state that every mutating request answers with — and neither payload says how old it is, so the
# client applies whichever arrives last. Usually they agree and the redelivery is merely wasted work
# (and a second chart animation); when they don't, the older one wins by arriving second.
#
# Monotonic per PROCESS rather than per cell: a cell can be replaced wholesale (reorder, re-parse,
# restore) and a per-cell counter would restart underneath the client. A global one is never reused,
# so "not newer than what I hold" is always the right test.
const _REV = Threads.Atomic{Int}(0)
bump_rev!(c::Cell) = (c.rev = Threads.atomic_add!(_REV, 1) + 1; c)

mark_running!(c::Cell) = (c.state = RUNNING; bump_rev!(c))

# A state flip with no output involved (markdown render, `@bind` value change, a fresh empty
# cell) — nothing to compute, so no exception to check.
mark_fresh!(c::Cell) = (c.state = FRESH; bump_rev!(c))

# ANY→FRESH/ERRORED from a genuine computed output (possibly `nothing` — a scratch eval that
# never ran). Callers that also mirror bind specs (`c.binds = out.binds`) do so themselves;
# whether binds surface differs by site (a scratch eval never does, a real cell always does).
mark_result!(c::Cell, out) = (c.output = out;
    c.state = (out === nothing || out.exception === nothing) ? FRESH : ERRORED; bump_rev!(c))

# A failure that never reached the worker (region prime/presync) — synthesize the error output.
"""
    bind_owner(report, name) -> String

The id of the cell that DECLARES `@bind name`, or `""` if none does.

Cell code driving a control (`set_bind(:name, value)`) names only the VARIABLE — a notebook
shouldn't have to know which of its own cells happens to hold a control in order to move it. The
browser and the agent both already carry the cell id; this is how the third caller finds it.
"""
function bind_owner(report::Report, name::AbstractString)
    nsym = Symbol(name)
    for c in report.cells, b in c.binds
        b.name == nsym && return c.id
    end
    return ""
end

mark_errored!(c::Cell, msg::AbstractString) = (
    c.output = CellOutput("", MimeChunk[], Any[], Any[], BindSpec[], "", msg, nothing, 0.0);
    c.state = ERRORED; bump_rev!(c))

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
    # Three routes to EVERYWHERE, in increasing explicitness:
    #  • INFERRED — pure `using`, an import scaffold, a theme setter. The cell's shape says so.
    #  • DECLARED (`:everywhere_declared`) — a RUNTIME declaration (`slate_effect(:everywhere)` harvested
    #    from the run by `_apply_cell_effects!`, or restored from the durable EffectStore). For a cell that
    #    registers process-global state (a custom op, a global config) with no colocated `using` to
    #    piggyback on — a package's registrar can self-declare at zero cost to the notebook author.
    #  • TAGGED (`:everywhere`) — the AUTHOR's explicit override, for the cell whose compute genuinely
    #    belongs on every side and which neither of the above can recognise. It replays WHOLE
    #    (`_everywhere_replay_source`), because tagging it is a statement that the whole cell is safe.
    # All three are the notebook/region analogue of `Distributed.@everywhere` (run this on every worker).
    (_is_pure_using(cell.source) || :import_scaffold in cell.flags || :everywhere in cell.flags ||
        :everywhere_declared in cell.flags || _THEME_SENTINEL in cell.writes) && return EVERYWHERE
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
        # Writes seen at run time that the analysis missed (`note_defines!`): a global bound by a
        # function that evals into the notebook, a macro that couldn't be expanded.
        union!(c.writes, c.observed)
        # `mutates=` declarations: assert the in-place effects analysis can't see (f!(x) through a
        # call, aliases). Mirrors the native analysis invariant `mutates ⊆ writes`: a mutator IS a
        # writer, so later readers chain off it (ordering + restale), and it's also a READ (ordered
        # after the original writer).
        for m in _manual_mutates(c)
            push!(c.mutates, m); push!(c.writes, m); push!(c.reads, m)
        end
        empty!(c.deps)
    end
    _apply_soft_scope!(report)             # a loop's assignment to an existing global updates it
    _apply_function_effects!(report)       # callers take on what the notebook functions they reach do
    _scan_imports!(report)                 # notebook-level `@use` import-map declarations → report.meta
    writer = Dict{Symbol,String}()        # name → id of most-recent prior writer
    barrier::Union{String,Nothing} = nothing
    seen = String[]
    pending_reads = Dict{Symbol,String}() # name → FIRST cell to read it top-level with no prior writer
    priorcode = Set{String}()             # ids of earlier CODE cells — the only legal `needs=` targets
    for c in report.cells
        if c.kind == MARKDOWN || c.kind == WEB
            # md/web cells depend on the writers of their interpolation vars (+ barrier), but never
            # write, become a barrier, or enter `seen`.
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
            # A web cell is exempt: even with no interpolations it must EVALUATE its `@web(...)` to
            # produce the `WebPage`, so it stays STALE until run (like code).
            c.kind == MARKDOWN && isempty(c.reads) && c.state == STALE && (c.state = FRESH)
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
    _track_definitions!(report)
    close_staleness!(report)
    return report
end

# What changed in the notebook's definitions since the last build, by cell: which cells are gone,
# and which names some cell used to define and none does now. Kept on `report.meta` for the run
# alone (none of these keys is serialized).
#
# A removed cell's methods and a lost name's binding are queued for the kernel (`take_forget!`,
# applied by `flush_forget!` before the next cell runs), and everything that read or also defined
# them is restaled. A cell whose id changed but whose source didn't is a rename, so its methods stay.
# A cell that appears (an undone delete) runs again, since the definitions it brings were taken back
# when it went.
function _track_definitions!(report::Report)
    now = Dict{String,Tuple{UInt64,Set{Symbol}}}(c.id => (c.src_hash, copy(c.writes))
                                                 for c in report.cells if c.kind == CODE)
    prev = get(report.meta, "_defs_lastbuild", nothing)
    report.meta["_defs_lastbuild"] = now
    prev isa AbstractDict || return report
    gone = setdiff(Set(keys(prev)), keys(now))
    appeared = setdiff(Set(keys(now)), keys(prev))
    for g in collect(gone)
        r = findfirst(id -> now[id][1] == prev[g][1], collect(appeared))
        r === nothing && continue
        delete!(gone, g); delete!(appeared, collect(appeared)[r])
    end
    edited = [id for id in keys(now) if haskey(prev, id) && prev[id][1] != now[id][1]]
    written = Set{Symbol}()
    for (_, w) in values(now); union!(written, w); end
    gone_names = Set{Symbol}()
    for id in gone; union!(gone_names, prev[id][2]); end
    lost = Set{Symbol}()
    for id in Iterators.flatten((gone, edited)); union!(lost, prev[id][2]); end
    setdiff!(lost, written)
    isempty(gone) || union!(get!(Set{String}, report.meta, "_pending_forget"), gone)
    pending = get!(Set{Symbol}, report.meta, "_pending_unbind")
    union!(pending, lost); setdiff!(pending, written)
    touched = union(lost, gone_names)
    for c in report.cells
        c.kind == CODE || continue
        if c.id in appeared
            # Its definitions were taken back when it went, so it runs again even if `locked`.
            c.state = STALE; bump_rev!(c)
        elseif !isdisjoint(c.reads, touched) || !isdisjoint(c.writes, gone_names)
            restale!(c)
        end
    end
    isempty(gone) || _do_cleanup_cells(report.id, collect(gone))
    return report
end

"""
    take_forget!(report) -> (cells, names)

The removed cells and lost global names queued since the last call, cleared as they are returned.
The caller hands them to [`forget!`](@ref) on every kernel the notebook runs cells in.
"""
function take_forget!(report::Report)
    cells = pop!(report.meta, "_pending_forget", Set{String}())
    names = Symbol[]
    pending = get(report.meta, "_pending_unbind", nothing)
    if pending isa AbstractSet && !isempty(pending)
        # A name some cell writes again is no longer lost.
        for c in report.cells
            c.kind == CODE && setdiff!(pending, c.writes)
        end
        # While an `include`/`eval` barrier or a macro not yet expanded is in the notebook, it may be
        # what defines a name now; keep the name queued until the analysis can see.
        if !any(c -> :opaque in c.flags, report.cells) && isempty(pending_macro_cells(report))
            names = sort!(collect(Symbol, pending)); empty!(pending)
        end
    end
    return (sort!(collect(String, cells)), names)
end

# A name a cell assigns inside a top-level loop (`soft_assigns`) that an earlier cell defines is an
# update of that global: a read and a write, so the cell orders after the definer and its value comes
# from it.
function _apply_soft_scope!(report::Report)
    above = Set{Symbol}()
    for c in report.cells
        c.kind == CODE || continue
        for n in c.soft_assigns
            (n in above && !(n in c.writes)) || continue
            push!(c.reads, n); push!(c.reads_now, n); push!(c.writes, n); push!(c.mutates, n)
        end
        union!(above, c.writes)
    end
    return report
end

# The notebook's function summaries merged by name (every cell that adds a method contributes) and
# closed over the calls between them: a function reaches what the notebook functions it calls reach,
# and a parameter it passes to a callee that mutates that position is mutated too.
function _notebook_function_effects(report::Report)
    S = Dict{Symbol,FuncSummary}()
    for c in report.cells
        c.kind == CODE || continue
        for (f, sm) in c.funcs
            acc = get(S, f, nothing)
            if acc === nothing
                S[f] = copy(sm)
            else
                union!(acc.refs, sm.refs); union!(acc.writes, sm.writes); union!(acc.mut_g, sm.mut_g)
                union!(acc.mut_p, sm.mut_p); append!(acc.calls, sm.calls)
            end
        end
    end
    changed = !isempty(S)
    while changed
        changed = false
        for (f, sm) in S
            n0 = (length(sm.refs), length(sm.writes), length(sm.mut_g), length(sm.mut_p))
            for g in collect(sm.refs)
                (g === f || !haskey(S, g)) && continue
                gs = S[g]
                union!(sm.refs, gs.refs); union!(sm.writes, gs.writes); union!(sm.mut_g, gs.mut_g)
            end
            for (g, args) in sm.calls
                gs = get(S, g, nothing); gs === nothing && continue
                for j in gs.mut_p
                    j <= length(args) || continue
                    b = args[j]; b === nothing && continue
                    k = findfirst(==(b), sm.params)
                    k === nothing ? (b in sm.refs && push!(sm.mut_g, b)) : push!(sm.mut_p, k)
                end
            end
            delete!(sm.refs, f)
            n0 == (length(sm.refs), length(sm.writes), length(sm.mut_g), length(sm.mut_p)) || (changed = true)
        end
    end
    return S
end

# A cell that calls a notebook function, or hands it off as a value, takes on what its body does: it
# reads the globals the body reads (resolved against the writers above THIS cell), and it is the
# writer of the globals the body assigns or mutates. A global the cell passes in a parameter position
# the function mutates is mutated by the cell. A markdown or web cell interpolating a call reads what
# the function reads.
function _apply_function_effects!(report::Report)
    S = _notebook_function_effects(report)
    isempty(S) && return report
    changes!(c, n) = (n in c.writes || push!(c.mutates, n); push!(c.writes, n); push!(c.reads, n))
    for c in report.cells
        if c.kind == MARKDOWN || c.kind == WEB
            for f in intersect(c.reads, keys(S)); union!(c.reads, S[f].refs); end
            continue
        end
        c.kind == CODE || continue
        for f in intersect(c.reads_now, keys(S))
            sm = S[f]
            union!(c.reads, sm.refs)
            for n in sm.writes; changes!(c, n); end
            for n in sm.mut_g; changes!(c, n); end
        end
        for (f, args) in c.topcalls
            sm = get(S, f, nothing); sm === nothing && continue
            for j in sm.mut_p
                j <= length(args) || continue
                b = args[j]
                b !== nothing && b in c.reads_now && changes!(c, b)
            end
        end
    end
    return report
end

# Names a cell changes in place rather than defines: what it mutates, plus what it both reads and
# rebinds (`acc += 1`, `df = clean(df)`). Running such a cell a second time applies its change to its
# own previous result.
_in_place_updates(c::Cell) = union(c.mutates, intersect(c.reads, setdiff(c.writes, c.provides)))

# The cell an in-place update's value comes from: the nearest earlier code cell that assigns `n`
# without reading or mutating it.
function _value_origin(report::Report, idx::Int, n::Symbol)
    for j in idx-1:-1:1
        o = report.cells[j]
        (o.kind == CODE && n in o.writes) || continue
        (n in o.mutates || n in o.reads || n in o.provides) && continue
        return o
    end
    return nothing
end

"""
    note_defines!(report, cell, names) -> Bool

Record globals a run of `cell` was seen to bind (`:defines`, reported by the capture). The ones its
analysis didn't predict join `cell.observed`, which the next graph build adds to its writes, so a
reader of a global the cell binds in a way the analysis can't see (a helper that evals into the
notebook, an unexpandable macro) gets an edge to it. Returns true when something new was learned and
the graph needs rebuilding.
"""
function note_defines!(report::Report, cell::Cell, names)
    cell.kind == CODE || return false
    new = Symbol[]
    for n in names
        s = Symbol(n)
        (s in cell.writes || s in cell.observed) && continue
        push!(new, s)
    end
    isempty(new) && return false
    union!(cell.observed, new)
    return true
end

# The `:defines` names in a cell's harvested effects.
function _defined_by_effects(out)
    out === nothing && return Symbol[]
    names = Symbol[]
    for e in out.effects
        k = e isa AbstractDict ? get(e, :kind, get(e, "kind", nothing)) : (hasproperty(e, :kind) ? e.kind : nothing)
        (k === :defines || k == "defines") || continue
        ns = e isa AbstractDict ? get(e, :names, get(e, "names", Any[])) : e.names
        append!(names, Symbol[Symbol(n) for n in ns])
    end
    return names
end

"""
    close_staleness!(report)

Bring the stale set to the closure the current graph implies, after any rebuild: everything
downstream of a stale cell is stale, and a stale cell that updates a value in place has that value's
origin cell restaled too, so the update applies to a fresh value instead of stacking on the result of
its last run (`push!(v, 2)` edited to `push!(v, 2, 3)` must not leave four elements).

The rebuild that recovers a macro's writes runs after the edit has already restaled through the old
graph; without this pass the new edges reach no one, and a reader keeps its old value.
"""
function close_staleness!(report::Report)
    changed = true
    while changed
        changed = false
        stale = Set{String}(c.id for c in report.cells if c.kind == CODE && c.state == STALE)
        isempty(stale) && return report
        for id in dependents_of(report, stale)
            c = get(report.byid, id, nothing)
            (c === nothing || c.state == STALE || c.state == RUNNING) && continue
            restale!(c) && (changed = true)
        end
        for (i, c) in enumerate(report.cells)
            (c.kind == CODE && c.state == STALE) || continue
            for n in _in_place_updates(c)
                o = _value_origin(report, i, n)
                (o === nothing || o.state == STALE || o.state == RUNNING) && continue
                restale!(o) && (changed = true)
            end
        end
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
            nc.observed = oc.observed     # what runs of this unchanged source were seen to bind
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
        # A deleted cell's `slate_on_cleanup` callbacks fire from the rebuild below
        # (`_track_definitions!`), which sees every removal, not only this path's.
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
    # A TOOL cell is never swept up by an automatic run. Its source is a call OUT of the notebook
    # with real consequences — it starts a job, writes a file, spends money — so opening a document, or recomputing
    # a stale neighbour, must not fire one on the reader's behalf. It stays STALE until someone runs
    # it deliberately, which `eval_cell!` still does.
    auto(c) = c.state == STALE && runs_automatically(c.kind)
    nbatch = count(auto, report.cells)   # cells about to run → UI shows a stable k/N
    nbatch > 0 && _emit_run_batch(report.id, nbatch)
    prepare!(kernel, report)
    flush_forget!(kernel, report)     # removed definitions leave the namespace before anything reads them
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
        elseif auto(c)
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
function refine_usings!(report::Report, kernel::Kernel = InProcessKernel(); rebuild::Bool = true)
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
    # `rebuild=false` lets a caller that holds a notebook lock do the (report-mutating) graph rebuild
    # itself, AFTER this off-lock kernel query — see the nb.lock protocol in server.jl.
    newly && rebuild && rebuild_precise!(report)
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
    forget_expansions!(report, cells) -> nothing

Drop the cached expansion bindings of `cells` so the next graph build re-expands them. The cache is
keyed by cell SOURCE, which is the right key for a macro — but an `include`d file's contents are an
input the source hash can't see, so a file that gains a definition would keep the old write-set (and
the cell using that new name would keep no edge) until the cell itself was edited. The asset watcher
calls this for the cells that read a changed file.
"""
function forget_expansions!(report::Report, cells)
    lock(_MACRO_LOCK) do
        binds = get(_MACRO_BINDS, report.id, nothing)
        tried = get(_MACRO_TRIED, report.id, nothing)
        for c in cells
            binds === nothing || delete!(binds, c.src_hash)
            tried === nothing || delete!(tried, c.src_hash)
        end
    end
    return nothing
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

With `rebuild=false` the caller rebuilds the graph and restales (`restale_macro_racers!`) itself;
pass a set as `recovered` to receive the cells whose recovery included a write.
"""
function refine_macros!(report::Report, kernel::Kernel = InProcessKernel(); restale_racers::Bool = false,
                        rebuild::Bool = true, recovered::Union{Nothing,Set{String}} = nothing)
    cells = pending_macro_cells(report)
    isempty(cells) && return false
    resolve_macros!(report, kernel, cells; mark_tried = true) || return false
    writers = Set{String}()   # attempted cells whose recovery included a WRITE (new downstream edges)
    lock(_MACRO_LOCK) do
        nb = get(_MACRO_BINDS, report.id, nothing)
        nb === nothing && return
        for c in cells
            rec = get(nb, c.src_hash, nothing)
            rec !== nothing && !isempty(rec[2]) && push!(writers, c.id)
        end
    end
    recovered === nothing || union!(recovered, writers)
    # `rebuild=false`: this ran the kernel resolve OFF a notebook lock (the protocol); the caller re-takes
    # the lock to `rebuild_precise!`, and the racer-restale needs the rebuilt graph, so it's the caller's
    # job too (with `recovered`).
    rebuild || return true
    rebuild_precise!(report)
    restale_racers && restale_macro_racers!(report, writers)
    return true
end

"""
    restale_macro_racers!(report, writers)

Restale every cell downstream of a cell in `writers`, whose macro-hidden write was just recovered:
a parallel drain ran it without that edge, so it may have raced its producer, even if it ran
without error. A writer with another recovered writer downstream (two cells that write one name)
is restaled too: they ran at the same time, so the later one may have disturbed the earlier, as two
macros declaring one name in state the analysis can't see would. Needs the rebuilt graph.
"""
function restale_macro_racers!(report::Report, writers::Set{String})
    for w in writers
        downstream = setdiff(dependents_of(report, Set([w])), Set([w]))
        isempty(downstream) && continue
        any(in(writers), downstream) && push!(downstream, w)
        for id in downstream
            c = get(report.byid, id, nothing)
            c === nothing || restale!(c)
        end
    end
    return nothing
end
