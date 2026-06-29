# Task-demultiplexing output — the primitive that lets a POOL of cell evaluators run concurrently in
# ONE worker process while each captures its OWN stdout/stderr. Julia's `redirect_stdout` is
# process-global, so two cells redirecting at once clobber each other; instead we install ONE global
# `DemuxIO` as stdout/stderr and route every write to the CURRENTLY-RUNNING task's buffer (set in its
# task-local storage), falling back to the real stream for non-cell tasks. Because `write` runs on the
# calling task, concurrent evaluators land in separate buffers with no locking. Shared by worker.jl
# (installed at startup) and test/test_demux.jl (unit-tested directly). Base-only, dependency-free.

"A process-global stdout/stderr stand-in that routes each write to the current task's capture buffer
(task-local key `key`), or to `fallback` when this task isn't a cell evaluator."
struct DemuxIO <: IO
    key::Symbol        # task-local-storage key holding this task's capture IOBuffer (:slate_out / :slate_err)
    fallback::IO       # the real stream (worker's original stdout/stderr → the log) when no capture is set
end

@inline _demux_sink(d::DemuxIO) = get(task_local_storage(), d.key, d.fallback)

# Write interface — delegate to the resolved per-task sink. Covers what print/show/log emit.
Base.unsafe_write(d::DemuxIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(_demux_sink(d), p, n)
Base.write(d::DemuxIO, b::UInt8) = write(_demux_sink(d), b)
Base.flush(d::DemuxIO) = (s = _demux_sink(d); applicable(flush, s) && flush(s); nothing)
Base.isopen(::DemuxIO) = true
Base.iswritable(::DemuxIO) = true
Base.isreadable(::DemuxIO) = false
Base.displaysize(::DemuxIO) = (24, 80)
# `print`/`show` sometimes probe color/limit context off the stream — keep them sane for captured output.
Base.get(d::DemuxIO, key::Symbol, default) = key === :color ? false : default

# Install the demux as the process stdout/stderr. `redirect_stdout` is process-global AND only accepts
# a Pipe (not a custom IO), so we rebind `Base.stdout`/`Base.stderr` directly (they're non-const). The
# CURRENT streams become the demux fallback, so non-cell output still flows to the real stream/log.
# Returns the prior (stdout, stderr) for restore.
function install_demux!()
    prev_out, prev_err = Base.stdout, Base.stderr
    @eval Base stdout = $(DemuxIO(:slate_out, prev_out))
    @eval Base stderr = $(DemuxIO(:slate_err, prev_err))
    return (prev_out, prev_err)
end
function restore_streams!(prev)
    @eval Base stdout = $(prev[1])
    @eval Base stderr = $(prev[2])
    return nothing
end

# Run `f()` with stdout+stderr captured to fresh per-task buffers (routed via the installed DemuxIO),
# returning `(value, stdout, stderr)`. Concurrency-safe: the buffers live in THIS task's storage, so
# parallel evaluators never share them. Restores the prior capture keys on exit (nested-safe).
function with_captured_output(f)
    tls = task_local_storage()
    out = IOBuffer(); err = IOBuffer()
    prev_out = get(tls, :slate_out, nothing); prev_err = get(tls, :slate_err, nothing)
    tls[:slate_out] = out; tls[:slate_err] = err
    try
        value = f()
        return (value = value, stdout = String(take!(out)), stderr = String(take!(err)))
    finally
        prev_out === nothing ? delete!(tls, :slate_out) : (tls[:slate_out] = prev_out)
        prev_err === nothing ? delete!(tls, :slate_err) : (tls[:slate_err] = prev_err)
    end
end
