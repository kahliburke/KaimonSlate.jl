# ── The Slate execution context ───────────────────────────────────────────────
# During a cell eval, Slate's engine seeds a per-task EXECUTION CONTEXT into task-local storage
# under `:slate_ctx`. It is a zero-dependency convention: any package reads it WITHOUT depending
# on KaimonSlate. This module is the ONE canonical definition of that convention, so an extension
# imports these accessors instead of hand-copying the task-local key and shape (which then drifts
# silently when Slate evolves).
#
# Shape (a NamedTuple the engine builds, tolerant of a Dict too):
#   region    :: Union{Symbol,Nothing}   — the region this eval runs on (nothing = the main side)
#   side      :: String                  — the region name as a string ("" = main)
#   regions   :: Vector{Symbol}          — regions declared for this cell
#   notebook  :: String                  — the notebook id
#   emit      :: (channel, value) -> …   — this side's slate_emit (worker → gate stream / in-proc → SSE)
#   effect    :: (kind; names, data...) -> … — the code→Slate declaration channel
#   on        :: (channel, f) -> …       — register a JS→Julia handler (into the notebook's __slate_handlers)

const _CTX_KEY = :slate_ctx

"""
    slate_context() -> NamedTuple | Nothing

Slate's per-cell execution context, or `nothing` outside a Slate eval (e.g. local unit tests /
a plain `include`). See the typed accessors below rather than reading fields directly.
"""
slate_context() = get(task_local_storage(), _CTX_KEY, nothing)

# NamedTuple/Dict-tolerant field read (`nothing` when absent or outside a cell).
function _ctx_field(f::Symbol, default = nothing)
    c = slate_context()
    c === nothing && return default
    if c isa NamedTuple
        return haskey(c, f) ? getfield(c, f) : default
    elseif c isa AbstractDict
        return get(c, f, get(c, string(f), default))
    end
    return default
end

"""
    slate_region() -> Symbol | Nothing

The region this eval runs on (`nothing` = the main side).
"""
slate_region() = _ctx_field(:region)

"""
    slate_regions() -> Vector{Symbol}

Regions declared for the current cell (empty outside a cell or when none are declared).
"""
slate_regions() = (r = _ctx_field(:regions); r === nothing ? Symbol[] : Symbol[Symbol(x) for x in r])

"The current side as a string (`\"\"` = main); `\"\"` outside a cell."
slate_side() = String(_ctx_field(:side, ""))

"The current notebook id (`\"\"` outside a cell)."
slate_notebook() = String(_ctx_field(:notebook, ""))

"""
    slate_emit(channel, value) -> nothing

Push `value` to the front end on `channel` (received by `window.slateOnStream(channel, …)`),
routed through the current context's emitter — a worker PUBs on the gate stream, the in-process
kernel pushes over SSE. A no-op outside a Slate cell, so package code can call it unconditionally.
"""
function slate_emit(channel, value)
    e = _ctx_field(:emit)
    e === nothing && return nothing
    e(channel, value)
    return nothing
end

"""
    slate_effect(kind::Symbol; names = Symbol[], data...) -> nothing

Declare a cell EFFECT to Slate over the code→Slate channel — e.g. `slate_effect(:everywhere;
names = [:my_op])` asks Slate to re-establish those names on every region worker (the analogue
of `Distributed.@everywhere` for process-global state a package registers). A no-op outside a
Slate cell.
"""
function slate_effect(kind::Symbol; names = Symbol[], data...)
    f = _ctx_field(:effect)
    f === nothing && return nothing
    f(kind; names = collect(names), data...)
    return nothing
end

"""
    slate_everywhere(names::Symbol...) -> nothing

Sugar for `slate_effect(:everywhere; names = names)` — mark process-global state (a custom op, a
global config) registered by the current statement so Slate re-establishes it on every worker.
"""
slate_everywhere(names::Symbol...) = slate_effect(:everywhere; names = collect(names))

"""
    slate_on(channel, f) -> nothing

Register a JS→Julia RPC handler for `channel` from PACKAGE code — the browser's `window.slateCall(channel,
payload)` invokes `f`. Routed through the current cell's context (the notebook's `__slate_handlers`), so a
package can wire an interactive widget's actions itself instead of the notebook hand-calling the injected
`slate_on`. The symmetric counterpart to [`slate_emit`](@ref) (push) — `slate_emit` is Julia→JS, this is
JS→Julia. A no-op outside a Slate cell.
"""
function slate_on(channel, f)
    on = _ctx_field(:on)
    on === nothing && return nothing
    on(channel, f)
    return nothing
end

"""
    slate_off(channel) -> nothing

Drop the JS→Julia handler registered for `channel` — the symmetric counterpart to [`slate_on`](@ref).
Use it to remove a TRANSIENT per-cell handler (e.g. a Bonito session's inbox feed, keyed by its session
id) on teardown so a re-run/close doesn't leak dead closures. A no-op outside a Slate cell.
"""
function slate_off(channel)
    off = _ctx_field(:off)
    off === nothing && return nothing
    off(channel)
    return nothing
end

"""
    slate_on_cleanup(f) -> nothing

Register a zero-arg callback `f` to run when the CURRENT cell is torn down — before it RE-EVALUATES,
when it is DELETED, and before a namespace rebuild. Use it to release a live per-cell resource a package
sets up during eval — a Bonito `Session`, a subscription, a spawned task — so a re-run or a delete
doesn't leak it. The callback runs LATER, possibly outside any cell eval (a delete fires it off a worker
teardown call), so it must be self-contained — close over the resource and any captured emit/off it
needs, not [`slate_context`](@ref) (which is unset then). A no-op outside a Slate cell.
"""
function slate_on_cleanup(f)
    c = _ctx_field(:cleanup)
    c === nothing && return nothing
    c(f)
    return nothing
end
