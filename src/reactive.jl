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

# namespace id → that namespace's `slate_refresh`. The notifier lives HERE, reached by a plain
# String, instead of inside the value.
#
# A `Reactive` that carries its own notifier closure cannot leave the process it was built in: the
# closure either refuses to serialize, or crosses and arrives still bound to the ORIGIN's gate
# stream, so a write on the far side notifies the wrong hub. That is the sole reason a reactive
# could not be read from a region worker while a `@bind` value could — the cross-kernel transport
# (`transfer_binding!`) is name-addressed and would otherwise have carried it years ago. With only
# `name`/`value`/`nsid` in the struct it serializes like any other value.
#
# Keyed per NAMESPACE, not per process: an in-process hub serves several notebooks from one process,
# and a write in one must not wake another's cells.
const _REFRESH_REGISTRY = Dict{String,Any}()
const _LOCAL_NSID = Ref("")

# Identifies this PROCESS, and it has to, because single-writer is a rule about KERNELS and not about
# namespace instances. A namespace id alone can't tell the two apart: a `Reactive` restored from this
# notebook's own memo store — or one that outlived a namespace rebuild — names an instance that no
# longer exists, and is indistinguishable from a replica that arrived from another worker unless the
# id says which process minted it. Refusing those was a live regression: the declarations cell
# restored, its reactives came back stamped with a dead namespace, and every write in every handler
# threw, so buttons did nothing at all.
const _PROC_TOKEN = Ref("")
function _proc_token()
    isempty(_PROC_TOKEN[]) && (_PROC_TOKEN[] = string(getpid(), "-", string(rand(UInt64); base = 36)))
    return _PROC_TOKEN[]
end

function register_refresh_ns!(nsid::AbstractString, refresh)
    full = _proc_token() * "|" * String(nsid)
    _REFRESH_REGISTRY[full] = refresh
    _LOCAL_NSID[] = full
    return full
end

# The notifier for a write to a reactive that says it belongs to `nsid` — and the enforcement point
# for SINGLE-WRITER discipline: a reactive is written on the kernel that declared it, and read
# anywhere.
#
# A replica that crossed a kernel boundary names a namespace that does not exist here. Writing it
# would update this copy and no other: the declaring kernel keeps the old value, the hub is told the
# value moved, and the two disagree with nothing to reconcile them. Rather than let a write mean
# something different depending on which side ran it, refuse — the same call `_region_presync!`
# already makes for cross-boundary mutation of an ordinary global, so reactives don't get a private
# rule.
#
# No namespace registered AT ALL is a different case: a standalone `julia notebook.jl` run has no hub
# to notify, so a write is simply inert.
mutable struct Reactive
    name::Symbol
    value::Any
    nsid::String              # which namespace to notify — see `_REFRESH_REGISTRY`
end
Base.getindex(r::Reactive) = getfield(r, :value)

function _notifier_for_write(r::Reactive)
    nsid = String(getfield(r, :nsid))
    f = get(_REFRESH_REGISTRY, nsid, nothing)
    f === nothing || return f
    isempty(_REFRESH_REGISTRY) && return nothing
    # Minted by THIS process, but by a namespace that no longer exists — a memo restore, or a
    # namespace rebuilt under it. Same kernel, so single-writer is satisfied; re-bind to the live
    # namespace rather than refusing a write the author is entitled to make.
    startswith(nsid, _proc_token() * "|") &&
        return get(_REFRESH_REGISTRY, _LOCAL_NSID[], nothing)
    error("""
          cannot write the reactive `$(getfield(r, :name))` from here: this is a copy that crossed a \
          kernel boundary, and writing it would change only this copy — the kernel that declared it \
          would keep the old value.

          Reactives are single-writer: written on the kernel that declares them, read anywhere. Move \
          the write to a cell on the declaring kernel (the one holding its `reactive(...)`/`@reactive`), \
          and read it here.""")
end

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

# Session-local ordinal for values `hash` refuses. Only ever produces cache MISSES (see below).
const _WRITE_SEQ = Ref(0)

# The IDENTITY of a write, computed here and carried to the hub alongside the push.
#
# The memo key digests a cell's source, its upstream cells' sources, the `@bind` values it reads and
# its `@asset` contents. A Reactive is none of those — it's an ordinary global, not a `BindSpec` — so
# a cell reading only reactives computes the SAME key on every run and, once cached, is served a
# result computed from values that have since moved. (That is not hypothetical: it froze a progress
# bar in an exported app, where the status cell crossed the auto-cache threshold on cold-JIT alone.)
#
# Digesting at WRITE time, not per key computation, is the load-bearing part: keys are computed on
# every eval, and hashing a large value there would put the whole payload on the hot path. A write
# happens once.
#
# `slate_fingerprint`, NOT `hash`. This has to answer "is this the same VALUE?", and `hash` answers a
# different question: for anything holding heap references it is derived from object identity, so two
# structurally identical values digest differently (`hash(f) != hash(deepcopy(f))` for a plain
# immutable struct with a Vector field), and — worse — an address freed and reused can make two
# genuinely different values digest the SAME, which is a stale restore rather than a harmless
# recompute. `fingerprint.jl` exists for exactly this and says so in its own docstring.
#
# Content-addressed also makes the digest deterministic ACROSS processes, which is what lets an
# exported bundle's entries match a reader's cold open when the state genuinely agrees.
#
# It costs more than `hash` — canonical serialization plus SHA-256 — which is affordable precisely
# because it happens once per write and never per key computation. A reactive pushing large arrays at
# high frequency would feel it; that's a measurement to take if it ever bites, not a reason to go back
# to an answer that is wrong.
function _write_digest(v)
    try
        return slate_fingerprint(v)
    catch
        _WRITE_SEQ[] += 1                     # unfingerprintable → session-local ordinal: always a miss, never a false hit
        return "w" * string(_WRITE_SEQ[])
    end
end

# A write is ALSO a cancellation checkpoint (same check `pause` does) — so a superseded @onclick
# handler that streams values (`level[] = v` in a loop) stops at its next write even with no
# explicit `pause()` call, instead of running to completion and racing the new handler's writes.
function Base.setindex!(r::Reactive, v)
    _cancel_fired!() && throw(_Cancelled())
    # Resolved BEFORE the value is stored, so a refused cross-kernel write leaves this copy untouched
    # rather than diverging from the declaring kernel by exactly the write we just rejected.
    f = _notifier_for_write(r)
    setfield!(r, :value, v)
    # Wire form `name:digest`. The hub restales on the NAME (as it always has) and mirrors the digest
    # so the memo key can move with the value. A bare `slate_refresh(:data)` from a cell's own async
    # task carries no digest and keeps its existing behaviour.
    f === nothing || f(string(getfield(r, :name), ":", _write_digest(v)))
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
