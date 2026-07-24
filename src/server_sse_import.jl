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
# Re-rendering live outputs on browser connect must be DEBOUNCED + SERIALIZED: a burst of quick reloads
# fires a burst of connects, and running a re-render per connect makes them race — each re-render resets
# the ONE Bonito page-root and re-renders the SAME retained figures, so overlapping ones clobber each
# other's session (the "figure loading" that gets worse the faster you reload). So per notebook we run ONE
# immortal debouncer task: a `_sse` connect just KICKS it; the task waits out the burst, coalesces it into a
# single re-render against the final settled page, delivers, and loops back to waiting. Crucially there is
# NO "a re-render is running" flag to get stuck — the task is the only thing that ever re-renders and it
# always returns to `take!`, so a single slow/hung round-trip can't permanently wedge a notebook's figures
# (an earlier running/dirty flag-pair could, if the loop failed to clear the flag).
const _LIVE_RERENDER_LOCK = ReentrantLock()
const _LIVE_RERENDER_KICK = Dict{String,Channel{Nothing}}()   # nb.id → debounce mailbox (buffered, lossy)
const _LIVE_RERENDER_DEBOUNCE = 0.30                          # seconds to let a reload burst settle

# Kick this notebook's live-re-render debouncer (starting it on first use). Never blocks the `_sse` handler:
# the mailbox is buffered, so a kick just enqueues (a full buffer already means a re-render is pending).
function _schedule_live_rerender!(nb::LiveNotebook)
    ch = lock(_LIVE_RERENDER_LOCK) do
        get!(_LIVE_RERENDER_KICK, nb.id) do
            c = Channel{Nothing}(256)
            _run_live_rerender_loop!(nb, c)
            c
        end
    end
    try; put!(ch, nothing); catch; end   # buffered → effectively non-blocking; closed → notebook gone
    return nothing
end

# The immortal per-notebook debouncer: wait for the first connect of a burst, sleep out the burst, drain
# the rest, then re-render once and deliver each live output via `server_celldone`. Loops until the mailbox
# is closed (notebook teardown). Any error is logged and the loop continues — one bad re-render never stops
# future ones. `rerender_live` no-ops without a live worker and carries its own gate timeout, so a down or
# slow worker can't hang this loop indefinitely.
function _run_live_rerender_loop!(nb::LiveNotebook, ch::Channel{Nothing})
    @async while true
        try
            take!(ch)                              # wait for a connect
            sleep(_LIVE_RERENDER_DEBOUNCE)         # let a reload burst settle to the final page
            while isready(ch); take!(ch); end      # coalesce the rest of the burst into this one pass
            for (cid, wire) in ReportEngine.rerender_live(nb.kernel, nb.report)
                try; server_celldone(nb, "reconnect", cid, wire); catch; end
            end
        catch e
            e isa InvalidStateException && break    # mailbox closed → notebook closing → end the task
            @warn "Kaimon Slate: live re-render loop error" id = nb.id exception = (e, catch_backtrace())
            sleep(0.5)                              # avoid a hot error loop
        end
    end
    return nothing
end

# Stop a notebook's live-re-render debouncer (close its mailbox → the loop ends). Called from teardown.
function _stop_live_rerender!(nb::LiveNotebook)
    ch = lock(_LIVE_RERENDER_LOCK) do
        c = get(_LIVE_RERENDER_KICK, nb.id, nothing)
        delete!(_LIVE_RERENDER_KICK, nb.id)
        c
    end
    ch === nothing || try; close(ch); catch; end
    return nothing
end

function _sse(stream::HTTP.Stream, nb::LiveNotebook)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    ch = Channel{String}(256)   # headroom so the slow-client resync tokens (see _broadcast) don't block
    n = lock(nb.llock) do; push!(nb.listeners, ch); length(nb.listeners); end
    @info "Kaimon Slate: browser connected" id = nb.id clients = n
    # A freshly-connected browser page needs any LIVE (session-bound) outputs — WGLMakie figures, whose
    # scene + interaction live in the worker session, not the replayed HTML — re-rendered for IT, the way a
    # Bonito server serves a fresh session per page load (see `_schedule_live_rerender!`).
    _schedule_live_rerender!(nb)
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

# ── Classifying whatever the open box points at ──────────────────────────────
# A user can hand us any file — a Slate notebook, a self-contained bundle, a RUNNABLE HTML export
# (which carries the bundle inside it), a plain Julia script, or something unrelated. `_source_kind`
# names which, so the front end can route each to the right flow instead of blindly opening it.

# Pull the embedded standalone `.jl` out of a runnable HTML export. `export_html(...; embed_bundle=true)`
# inlines the whole self-contained notebook as a base64 string (`var _bb64="…"`); decode it back to
# the `.jl` source. Returns the source text, or `nothing` when the page carries no bundle (a static
# export, or a foreign HTML file).
function _html_bundle_source(path::AbstractString)
    isfile(path) || return nothing
    txt = try; read(path, String); catch; return nothing; end
    m = match(r"var _bb64=\"([A-Za-z0-9+/=]+)\"", txt)
    m === nothing && return nothing
    src = try; String(Base64.base64decode(m.captures[1])); catch; return nothing; end
    occursin(_BUNDLE_OPEN, src) || return nothing   # sanity: a real self-contained bundle
    return src
end

# True if `path` looks like a Slate HTML export (our export chrome) — used only to tailor the
# "no runnable bundle" message for a static export vs an unrelated HTML file.
function _is_slate_export_html(path::AbstractString)
    isfile(path) || return false
    try
        for line in eachline(path)
            (occursin("exp-titleblock", line) || occursin("class=\"export\"", line)) && return true
        end
    catch
    end
    return false
end

# True if a `.jl` carries Slate structure — an explicit `#%%` cell header or a `# ╔═╡ Slate.` footer.
# A file with neither is a plain Julia script (offered as a NEW notebook rather than opened in place).
# Scans a bounded line prefix so a huge file stays cheap.
function _looks_like_notebook(path::AbstractString)
    isfile(path) || return false
    try
        n = 0
        for line in eachline(path)
            startswith(lstrip(line), "#%%") && return true
            startswith(line, "# ╔═╡ Slate.") && return true
            (n += 1) > 4000 && break
        end
    catch
    end
    return false
end

# Classify a path the open box points at, so the front end can route it:
#   "bundle"      self-contained `.jl` (Slate.bundle footer)   → import helper
#   "notebook"    a Slate `.jl` notebook (has #%% cells)        → open live / inactive
#   "plain"       a plain Julia script, no Slate structure      → offer a new notebook (a copy)
#   "html-bundle" a RUNNABLE HTML export (bundle embedded)      → extract → import helper
#   "html-static" a static HTML export (no embedded bundle)     → clear error (re-export runnable)
#   "foreign"     anything else                                 → clear error
#   "none"        not a file
function _source_kind(path::AbstractString)
    isfile(path) || return "none"
    ext = lowercase(splitext(path)[2])
    if ext == ".jl"
        _has_bundle_footer(path) && return "bundle"
        return _looks_like_notebook(path) ? "notebook" : "plain"
    elseif ext == ".html" || ext == ".htm"
        _html_bundle_source(path) === nothing || return "html-bundle"
        return _is_slate_export_html(path) ? "html-static" : "foreign"
    end
    return "foreign"
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
    runon = strip(get(q, "runon", ""))              # run-location chosen in the import dialog ("" = local/global)
    try
        (isfile(path) && _has_bundle_footer(path)) ||
            return emit("failed", "Not a self-contained notebook (no Slate.bundle footer):\n$path")
        (!isempty(target) && isdir(target) && !isempty(readdir(target))) &&
            return emit("failed", "Target directory already exists and isn't empty:\n$target")
        emit("status", "Expanding bundle…")
        tdir = expand(path; target = target)
        co = _read_coords(tdir)                       # (root, envdir, parent, notebook)
        openpath = co.notebook
        isempty(openpath) && return emit("failed", "Expanded, but found no notebook .jl in $tdir")
        emit("log", "Expanded to $tdir" * (co.envdir == tdir ? "" : " (env: $(co.envdir))"))
        r = instantiate!(co.envdir)
        r === :aborted && return            # client gone
        r === :failed && return emit("failed",
            "Package instantiation failed.\nThe project is at $tdir — open it and retry there.")
        emit("status", "Opening notebook…")
        id = open_notebook!(h, openpath; runon = String(runon))
        emit("done", JSON.json(Dict("id" => id, "url" => "/n/$id", "target" => tdir)))
    catch e
        emit("failed", sprint(showerror, e))
    end
    return nothing
end

# SSE handler for `GET /api/preflight-stream?host=&transport=` — the browser "Test connection" flow.
# Runs the same reported dry-run as the `check_remote` gate tool, but STREAMS each step as it starts
# ("run") and completes ("ok"/"fail"/"skip") so the checklist fills in live (a cold provision is
# minutes). Browser-triggerable, no MCP tool required.
function _sse_preflight(stream::HTTP.Stream, h)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    function emit(ev::AbstractString, data::AbstractString)
        io = IOBuffer(); println(io, "event: ", ev)
        for ln in split(data, '\n'); println(io, "data: ", ln); end
        println(io)
        try; write(stream, String(take!(io))); return true; catch; return false; end
    end
    q = HTTP.queryparams(HTTP.URI(stream.message.target))
    host = strip(get(q, "host", ""))
    tr = Symbol(strip(get(q, "transport", "tunnel"))); tr in (:tunnel, :direct) || (tr = :tunnel)
    isempty(host) && (emit("failed", "no host given"); return nothing)
    try
        r = ReportEngine.preflight_remote(host; transport = tr, on_step = step ->
            emit("step", JSON.json(Dict("name" => step.name, "status" => step.status,
                                        "detail" => step.detail, "ms" => step.ms))))
        emit("done", JSON.json(Dict("ok" => r["ok"], "host" => r["host"], "transport" => r["transport"])))
    catch e
        emit("failed", sprint(showerror, e))
    end
    return nothing
end

# Resolved absolute paths of the notebook's `@asset` file deps (existing files only). `cell.inputs`
# holds the statically-extracted literal paths; resolve each against `assetbase` (the project dir).
function _asset_files(nb::LiveNotebook)
    base = String(get(nb.report.meta, "assetbase", ""))
    out = String[]
    lock(nb.lock) do
        for c in nb.report.cells, rel in c.inputs
            ap = isabspath(rel) ? String(rel) : (isempty(base) ? String(rel) : joinpath(base, rel))
            isfile(ap) && push!(out, ap)
        end
    end
    return unique!(out)
end

# Change signal for an asset file: its mtime via `stat` (NOT a content read). Reading the file to
# hash it would bump the file's ATIME, which `watch_file` reports as a change (NOTE_ATTRIB) — and
# since the recompute itself reads the asset via `@asset`, a hash-based watcher would wake itself in
# a tight loop. `stat`/mtime touches nothing, so an atime-only event leaves the signal unchanged.
_asset_mtime(f) = try; mtime(f); catch; 0.0; end

# Watch the file for external edits (VS Code / agent) → sync → push instantly.
# `watch_file` returns on change (instant) or after a 2s safety timeout (covers
# editors that save via atomic rename). Server's own writes match canonically in
# `sync_from_file!`, so they don't echo back.
function _start_watcher!(nb::LiveNotebook)
    @async begin
        last = _asset_mtime(nb.path)
        while true
            try
                FileWatching.watch_file(nb.path, 2.0)
                # Guard the atime self-wake loop: `sync_from_file!` READS + RE-PARSES the whole .jl, and
                # that read bumps the file's atime, which `watch_file` reports as a change (NOTE_ATTRIB)
                # → without this it re-parses in a tight CPU loop (an intermittent 300%+ spin that
                # starved the eval). Only sync when mtime actually advanced; `sleep` floors event storms
                # to ≤5 Hz — the same hardening as the @asset watcher below.
                m = _asset_mtime(nb.path)
                if m != last
                    last = m
                    sync_from_file!(nb) && _broadcast(nb, string(nb.version))
                end
                sleep(0.2)
            catch
                sleep(0.5)
            end
        end
    end
    # `@asset` reactivity: watch the files cells read via `@asset` → on a content change, recompute
    # the readers (server_asset_changed). Event-driven (one short `watch_file` per file, first-wins)
    # with a 2 s ceiling that re-derives the set (picks up newly-added deps) and covers atomic-rename
    # saves a single-file watch can miss — the same idiom as the notebook-file watcher above. A
    # content-hash diff means a metadata-only touch (or our own read) never triggers a recompute.
    @async while true
        try
            files = _asset_files(nb)
            if isempty(files)
                sleep(2); continue                    # no @asset deps yet — cheap periodic recheck
            end
            prev = Dict(f => _asset_mtime(f) for f in files)
            ch = Channel{Nothing}(length(files) + 1)  # buffer ≥ putters → none blocks, no leaked tasks
            for f in files
                @async begin
                    try; FileWatching.watch_file(f, 2.0); catch; end
                    try; put!(ch, nothing); catch; end
                end
            end
            take!(ch)                                 # wake on the first event (or the 2 s ceiling)
            changed = String[f for f in files if _asset_mtime(f) != get(prev, f, 0.0)]
            isempty(changed) || server_asset_changed(nb, changed)
            sleep(0.2)                                # floor: bound any event storm (e.g. an editor's
                                                      # multi-write save) to ≤5 Hz regardless of wakes
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

