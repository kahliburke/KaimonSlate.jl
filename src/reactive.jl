# ── Reactive async primitives ─────────────────────────────────────────────────
# Clean building blocks for "a background process that streams updates into a live value",
# replacing the global / @isdefined / generation-counter / manual-slate_refresh boilerplate.
# Shared by the engine (ReportEngine) and the standalone worker (SlateWorker); Base only, so it
# loads into any worker env. `reactive` / `pause` / `@onclick` are injected into the notebook
# namespace by `_populate_notebook_ns!` (each `reactive` capturing that notebook's slate_refresh).
#
#   level = reactive(:level, 0)        # a live value: level[] reads; level[] = v pushes to readers
#   @onclick fill begin                # runs on click; a NEW click cancels the still-running prior run
#       for v in 0:2:rand(45:100)
#           level[] = v                # no global, no name repetition, no manual slate_refresh
#           pause(0.04)                # cancellable sleep — aborts cleanly if superseded
#       end
#   end
#
# Why it doesn't loop on itself: `level[] = v` marks the @onclick cell as a WRITER of `level`,
# and server_refresh restales only READERS that don't write — so the handler isn't re-triggered,
# while the chart (a pure reader of `level`) recomputes and live-pushes.

mutable struct Reactive
    name::Symbol
    value::Any
    refresh::Any              # this notebook's slate_refresh
end
Base.getindex(r::Reactive) = getfield(r, :value)
function Base.setindex!(r::Reactive, v)
    setfield!(r, :value, v)
    getfield(r, :refresh)(getfield(r, :name))     # restale + recompute the cells that read this value
    return v
end
Base.show(io::IO, r::Reactive) = show(io, getfield(r, :value))                       # displays as its value
Base.show(io::IO, m::MIME"text/plain", r::Reactive) = show(io, m, getfield(r, :value))

struct _Cancelled <: Exception end

# `pause` inside an @onclick body is a CANCELLABLE sleep — it aborts the run cleanly the moment a
# newer click supersedes it. Used outside an @onclick (no token in the task), it's a plain sleep.
function pause(dt)
    tok = get(task_local_storage(), :slate_cancel, nothing)
    (tok !== nothing && tok[]) && throw(_Cancelled())
    sleep(dt)
    (tok !== nothing && tok[]) && throw(_Cancelled())
    return nothing
end

# Dispatch a control's @onclick/@onchange handler with the new value (event model — called from
# __slate_set_bind when the control changes, NOT by recomputing a cell). `tokens` is the notebook's
# per-control cancel-token dict; a new change flips the prior token (cooperative cancel, seen at the
# next `pause`) before spawning the fresh task, so a re-trigger restarts cleanly.
function __on_fire!(tokens, name::Symbol, f, value)
    t = get(tokens, name, nothing)
    t === nothing || (t[] = true)
    tok = Ref(false); tokens[name] = tok
    @async begin
        task_local_storage(:slate_cancel, tok)
        try
            f(value)
        catch e
            e isa _Cancelled || rethrow()           # cancellation is expected; surface anything else
        end
    end
    return nothing
end

# Cooperatively cancel the running handler for `name` — it stops at its next `pause`. Used from a
# Stop button (`@onclick stop cancel(:fill)`). Cancelling an idle/finished handler is a no-op.
# (Julia can't force-kill a task, so a handler with no `pause` can't be interrupted.)
__on_cancel!(tokens, name::Symbol) = (t = get(tokens, name, nothing); t === nothing || (t[] = true); nothing)
