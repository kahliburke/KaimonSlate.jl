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

# Has this task been cancelled — and is this the FIRST checkpoint to notice?
#
# The check fires ONCE per task, and that "once" is the whole point. Cancelling has to abort the
# handler's work, which one throw does: it unwinds the streaming loop and everything around it. But
# a handler also has to CLEAN UP, and cleanup is written where cleanup belongs —
#
#     try
#         busy[] = true; …work…
#     finally
#         busy[] = false          # ← a Reactive write, in the unwinding path
#     end
#
# — so a checkpoint that kept throwing would abort the cleanup too, on every attempt, and strand the
# UI in the state the cancelled handler was last able to push (a progress bar that never stops). The
# recommended pattern would be broken exactly when it is most needed. After the first throw the task
# is already unwinding, so later writes are cleanup and are allowed through.
#
# The cost: a body that CATCHES `_Cancelled` inside its own loop and keeps going is no longer stopped
# by subsequent writes. That is a loop actively swallowing its own cancellation, and it was already
# uninterruptible between checkpoints.
function _cancel_fired!()
    tok = get(task_local_storage(), :slate_cancel, nothing)
    (tok === nothing || !tok[]) && return false
    get(task_local_storage(), :slate_cancel_fired, false) && return false
    task_local_storage(:slate_cancel_fired, true)
    return true
end

# A write is ALSO a cancellation checkpoint (same check `pause` does) — so a superseded @onclick
# handler that streams values (`level[] = v` in a loop) stops at its next write even with no
# explicit `pause()` call, instead of running to completion and racing the new handler's writes.
function Base.setindex!(r::Reactive, v)
    _cancel_fired!() && throw(_Cancelled())
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
    _cancel_fired!() && throw(_Cancelled())
    sleep(dt)
    _cancel_fired!() && throw(_Cancelled())
    return nothing
end

# Dispatch a control's @onclick/@onchange handler with the new value (event model — called from
# __slate_set_bind when the control changes, NOT by recomputing a cell). `tokens` is the notebook's
# per-control cancel-token dict; a new change flips the prior token (cooperative cancel, seen at the
# next `pause`) before spawning the fresh task, so a re-trigger restarts cleanly.
function __on_fire!(tokens, name::Symbol, f, value, ctx = nothing)
    t = get(tokens, name, nothing)
    t === nothing || (t[] = true)
    tok = Ref(false); tokens[name] = tok
    @async begin
        task_local_storage(:slate_cancel, tok)
        # Re-establish the notebook's Slate execution context in this spawned task so a handler that STREAMS
        # (`slate_emit`/`afm_emit`/`slate_effect` via the SEB ctx accessors) works — the fire path runs on a
        # server task with no `:slate_ctx`, and `@async` doesn't inherit task-local storage. Without this,
        # streaming from an @onclick/@onchange body is a silent no-op (its `_ctx_field(:emit)` is unset).
        ctx === nothing || task_local_storage(:slate_ctx, ctx)
        try
            f(value)
        catch e
            # Runs in an unawaited `@async`, so a rethrow would just vanish — LOG the handler error
            # (an @onclick/@onchange body that threw) instead. Cancellation is expected and ignored.
            e isa _Cancelled || @error "Slate: reactive handler '$name' errored" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

# Cooperatively cancel the running handler for `name` — it stops at its next `pause` OR its next
# `Reactive` write. Used from a Stop button (`@onclick stop cancel(:fill)`). Cancelling an
# idle/finished handler is a no-op. (Julia can't force-kill a task — a handler with NEITHER a
# `pause` NOR a reactive write in its body still can't be interrupted, but such a handler has no
# visible side effect to race against anyway.)
__on_cancel!(tokens, name::Symbol) = (t = get(tokens, name, nothing); t === nothing || (t[] = true); nothing)
