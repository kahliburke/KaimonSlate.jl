# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Live push over SSE (per notebook) ────────────────────────────────────────
function _broadcast(nb::LiveNotebook, msg::AbstractString)
    lock(nb.llock) do
        for ch in nb.listeners
            try
                isopen(ch) || continue
                n = Base.n_avail(ch)
                if n < 32
                    put!(ch, String(msg))                 # normal: deliver the message
                elseif n < 200
                    # Slow client: stop forwarding patches (they'd back up), but enqueue ONE bare
                    # version token so it re-pulls full state on catch-up — recovering any dropped
                    # NON-idempotent patch (refresh:/celldone:/cellprog:) instead of going stale.
                    put!(ch, string(nb.version))
                end
                # else: queue already deep with resync tokens — the pending resync covers this msg.
            catch
            end
        end
    end
end

# Close this notebook's live SSE channels so each `_sse` loop's `take!` throws and
# returns, ending its long-lived connection. Without this, `close(server)` blocks
# waiting for those streams to drain (a browser tab left open hangs the close).
function _close_listeners(nb::LiveNotebook)
    lock(nb.llock) do
        for ch in nb.listeners
            try; close(ch); catch; end
        end
        empty!(nb.listeners)
    end
end

# One SSE connection over a raw `HTTP.Stream` (HTTP 2.0's documented streaming
# pattern — `listen!` + a `Stream` handler). Registers a channel, streams the
# current version on connect, then `data: <version>` on each change and `: hb`
# comment-line heartbeats (which the browser ignores) so a dead connection
# surfaces as a failed write that ends the loop. Each `write` flushes as its own
# chunk — unlike the high-level `sse_stream`/`SSEStream`, whose chunked writer
# blocks for a full 16 KiB buffer before flushing and so can't drive a long-lived
# push connection.
function _sse(stream::HTTP.Stream, nb::LiveNotebook)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    ch = Channel{String}(256)   # headroom so the slow-client resync tokens (see _broadcast) don't block
    n = lock(nb.llock) do; push!(nb.listeners, ch); length(nb.listeners); end
    @info "Kaimon Slate: browser connected" id = nb.id clients = n
    try
        write(stream, "data: $(nb.version)\n\n")
        while true
            msg = take!(ch)
            write(stream, msg == "hb" ? ": hb\n\n" : "data: $msg\n\n")
        end
    catch
    finally
        left = lock(nb.llock) do; filter!(c -> c !== ch, nb.listeners); length(nb.listeners); end
        close(ch)
        @info "Kaimon Slate: browser disconnected" id = nb.id clients = left
    end
    return nothing
end

# ── Streaming import of a self-contained `.jl` (index page) ───────────────────
# A self-contained notebook is a transport artifact: before it can run it must be `expand`ed
# into a real project tree and its environment instantiated. `_sse_import` streams that whole
# flow over SSE (same raw-Stream pattern as `_sse`) so the open box shows live progress —
# expand → the actual package resolve/instantiate output → open.

# True if `path`'s file carries a `Slate.bundle` footer. Scans for the open marker only; never
# decodes the (potentially large) base64 payload.
function _has_bundle_footer(path::AbstractString)
    isfile(path) || return false
    try
        for line in eachline(path)
            startswith(line, _BUNDLE_OPEN) && return true
        end
    catch
    end
    return false
end

# The single notebook `.jl` at the root of an expanded bundle (Project/Manifest/local/repo are
# the only other root entries). "" if none found.
function _expanded_notebook(tdir::AbstractString)
    for f in readdir(tdir)
        (endswith(f, ".jl") && isfile(joinpath(tdir, f))) && return joinpath(tdir, f)
    end
    return ""
end

# SSE handler for `GET /api/import-standalone?path=&target=` — the **Import** flow: expand the
# bundle into `target` (a real project the user owns) and open it, streaming progress. ("Run
# (temporary)" is a plain open instead: load_notebook hydrates against the depot cache, so it
# needs no streamed instantiate here.) Events:
#   status <text>  — coarse phase label
#   log    <line>  — one line of expand / instantiate output
#   done   <json>  — {id,url,target}; the client redirects into the opened notebook
#   failed <text>  — a handled error (named `failed`, not `error`, to avoid clashing with
#                    EventSource's built-in transport `error` event on the client)
# `h` is the `Hub` (untyped here only because its struct is defined later in this file).
function _sse_import(stream::HTTP.Stream, h)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    # Returns false if the write failed (client disconnected / cancelled) so callers can stop.
    function emit(ev::AbstractString, data::AbstractString)
        io = IOBuffer()
        println(io, "event: ", ev)
        for ln in split(data, '\n'); println(io, "data: ", ln); end   # SSE: one data: per line
        println(io)
        try; write(stream, String(take!(io))); return true; catch; return false; end
    end
    # Stream `Pkg.instantiate()` for `projdir`; returns :ok / :aborted / :failed.
    function instantiate!(projdir)
        emit("status", "Resolving & instantiating packages — this can take a while…")
        jl = Base.julia_cmd()[1]
        out = Pipe()
        proc = run(pipeline(`$jl --project=$projdir --color=no --startup-file=no -e 'using Pkg; Pkg.instantiate()'`;
                            stdout = out, stderr = out); wait = false)
        close(out.in)                       # parent's write end; lets eachline see EOF on exit
        for line in eachline(out)
            emit("log", line) || (try; kill(proc); catch; end; return :aborted)
        end
        wait(proc)
        return proc.exitcode == 0 ? :ok : :failed
    end
    q = HTTP.queryparams(HTTP.URI(stream.message.target))
    path = expanduser(strip(get(q, "path", "")))
    target = let t = strip(get(q, "target", "")); isempty(t) ? "" : expanduser(t); end
    try
        (isfile(path) && _has_bundle_footer(path)) ||
            return emit("failed", "Not a self-contained notebook (no Slate.bundle footer):\n$path")
        (!isempty(target) && isdir(target) && !isempty(readdir(target))) &&
            return emit("failed", "Target directory already exists and isn't empty:\n$target")
        emit("status", "Expanding bundle…")
        tdir = expand(path; target = target)
        openpath = _expanded_notebook(tdir)
        isempty(openpath) && return emit("failed", "Expanded, but found no notebook .jl in $tdir")
        emit("log", "Expanded to $tdir")
        r = instantiate!(tdir)
        r === :aborted && return            # client gone
        r === :failed && return emit("failed",
            "Package instantiation failed.\nThe project is at $tdir — open it and retry there.")
        emit("status", "Opening notebook…")
        id = open_notebook!(h, openpath)
        emit("done", JSON.json(Dict("id" => id, "url" => "/n/$id", "target" => tdir)))
    catch e
        emit("failed", sprint(showerror, e))
    end
    return nothing
end

# Watch the file for external edits (VS Code / agent) → sync → push instantly.
# `watch_file` returns on change (instant) or after a 2s safety timeout (covers
# editors that save via atomic rename). Server's own writes match canonically in
# `sync_from_file!`, so they don't echo back.
function _start_watcher!(nb::LiveNotebook)
    @async while true
        try
            FileWatching.watch_file(nb.path, 2.0)
            sync_from_file!(nb) && _broadcast(nb, string(nb.version))
        catch
            sleep(0.5)
        end
    end
    @async while true
        sleep(15)
        _broadcast(nb, "hb")
    end
    # Periodic safety net: a low-frequency snapshot of the current state, deduped by
    # hash so it's free when nothing changed. Catches any state that slipped past the
    # op-level checkpoints (and guarantees the "at least every minute" capture).
    @async while true
        sleep(60)
        try; _history!(nb; source = "auto", kind = "draft"); catch; end
    end
end

