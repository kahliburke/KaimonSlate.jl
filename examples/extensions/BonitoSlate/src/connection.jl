# ── SlateConnection: Bonito over Slate's own transport ────────────────────────
# A `Bonito.FrontendConnection` that routes a Bonito Session's frames over KaimonSlate's EXISTING
# per-notebook WebSocket instead of Bonito standing up its own HTTP server + WebSocket on a separate
# port. Modelled on Bonito's `IJuliaConnection` (Bonito routed over Jupyter comms):
#
#   Julia → browser : the already-serialized frame rides Slate's BINARY lane
#                     (`slate_emit(chan, SlateBinary(bytes))` → page WS binary frame → `slateOnStream`).
#   browser → Julia : Bonito's outbound sender base64-encodes the frame and `slateCall(chan, b64)`s it;
#                     a `slate_on` handler decodes and `put!`s it into `session.inbox` (Bonito's inbox
#                     task then `process_message`s it). Base64 because `slateCall` args are JSON.
#
# Every figure on a page shares ONE ROOT session + transport channel (see `use_parent_session` below) —
# Bonito routes a page's sub-sessions over the root's connection. Paired with `NoServer` (which inlines
# the Bonito bundle + init blob as `data:` URLs), the emitted fragment references NO localhost URL and
# opens NO extra port — so it also works for a remote/region worker.

# Slate's per-cell emit / JS→Julia-handler registrars, captured from the execution context by
# `enable!()` (a Slate worker serves ONE notebook, so a process-global is per-notebook). `slate_emit`,
# `slate_on` and `slate_off` are stable notebook-namespace functions — safe to call from Bonito's session
# task and from a cleanup callback (which runs on teardown, possibly OUTSIDE any cell eval, so it can't
# read the task-local Slate context and must use these captured refs).
const _SLATE_EMIT = Ref{Any}(nothing)
const _SLATE_ON   = Ref{Any}(nothing)
const _SLATE_OFF  = Ref{Any}(nothing)

_chan(id::AbstractString) = "__bonito:" * id
_ctl(id::AbstractString)  = _chan(id) * ":ctl"    # sibling control channel — carries the browser teardown signal

# Tear a session down when its cell re-evaluates / is deleted / the namespace rebuilds (registered via
# `slate_on_cleanup`). Three jobs, one per resource the session holds: close the Bonito `Session` (ends
# its inbox task + frees Bonito's registries), drop the JS→Julia handler `setup_connection` installed
# (else a dead closure lingers in `__slate_handlers`), and tell the BROWSER to free the WGL session +
# unsubscribe its streams (else `window.__slateStream[chan]` leaks a handler per re-run). Self-contained:
# it captures everything it needs and never touches the task-local context (unset at teardown time).
function _teardown_session!(session)
    id = session.id
    try; Base.isopen(session) && close(session); catch; end
    off = _SLATE_OFF[]; off === nothing || (try; off(_chan(id)); catch; end)
    emit = _SLATE_EMIT[]
    emit === nothing || (try; emit(_ctl(id), Dict("op" => "close")); catch; end)
    return nothing
end

mutable struct SlateConnection <: Bonito.FrontendConnection
    id::String     # the owning session's id → the transport channel; set in `setup_connection`
    open::Bool
end
SlateConnection() = SlateConnection("", true)

# `write` receives an ALREADY-serialized frame (Bonito's `Base.write(::FrontendConnection, ::SerializedMessage)`
# fallback serializes first). Ship the raw bytes over the binary lane, tagged with this session's channel.
function Base.write(c::SlateConnection, bytes::AbstractVector{UInt8})
    emit = _SLATE_EMIT[]
    (emit === nothing || isempty(c.id)) && return
    emit(_chan(c.id), SlateBinary(Vector{UInt8}(bytes)))
    return
end

Base.isopen(c::SlateConnection) = c.open
Base.close(c::SlateConnection) = (c.open = false; nothing)

# Every figure on a page shares ONE ROOT session (exactly like Bonito's IJulia/Pluto connections route
# many figures over one channel). This is REQUIRED for arbitrary figures: WGLMakie's browser
# `orderedExecutor` is global-monotonic and `get_order!` counts per ROOT session, so a shared root gives
# globally monotonic orders (1, 2, 3, …) that the browser scheduler runs in sequence. Per-figure roots
# would each emit "order 1" and collide (only the first figure would render). The first figure establishes
# the page root (`show_html` sets `Bonito.CURRENT_SESSION`); every later figure is a SUB-session sharing it.
Bonito.use_parent_session(::Bonito.Session{SlateConnection}) = true

# The ONE page-root session for this worker, captured when its `setup_connection` runs. It OUTLIVES every
# browser page: a reload re-points it at the new page rather than replacing it (see `_reset_page!`).
const _PAGE_ROOT = Ref{Any}(nothing)

# Set by `_reset_page!` when a freshly-connected page has not yet been told about the root — consumed by
# `root_announce_html` on the next figure rendered for that page.
const _ANNOUNCE_ROOT = Ref(false)

# Re-point the ONE persistent page-root at a freshly-connected browser — WITHOUT tearing it down.
#
# Destroying the root on every connect is what strands a page: the teardown drops the root's `slate_on`
# handler, so any fragment the browser has ALREADY mounted (the autorun's `celldone` push, a replayed
# output) is left talking to `__bonito:<old-root>` — a channel with no receiver. Julia then waits for a
# handshake that can never arrive and the browser waits for a scene that is never sent: a permanent
# spinner with nothing logged on either side. Whichever fragment happened to land last decided whether
# the page worked, which is exactly the intermittency ("first load spins, a reload fixes it").
#
# Keeping ONE root removes the failure mode at the source — there is never a dead channel to strand on,
# because the channel's id never changes. That works here precisely because `SlateConnection` is a
# PAGE-level transport: it routes through `slate_emit`/`slate_on` on the notebook's own WebSocket, not a
# socket owned by the session, so the same root simply serves whichever page is currently attached.
#
# Two things must be reset for the new page:
#   • its object cache — a reloaded page is a fresh `window.Bonito` with an EMPTY cache, so anything sent
#     as a `CacheKey` back-reference would be unresolvable. Clearing forces full re-serialization.
#   • its readiness — `connection_ready` is what Bonito's `_send` consults to decide WRITE-now vs QUEUE
#     (see `_send`/`init_session` in Bonito's session.jl). While the new page is still loading there is
#     nobody to write to, so we take the readiness token back: every message then QUEUES and gets flushed
#     into the announcement blob below, instead of being written into the void. The browser's own
#     `send_done_loading` drives `init_session` on the Julia side, which re-signals readiness and flushes.
#   • its metadata — per-page scratch that MIRRORS browser state, so it must not cross pages. Re-seeded
#     from the page's durable state immediately after (see `_seed_scene_order!`).
function _reset_page!()
    root = _PAGE_ROOT[]
    root === nothing && return nothing
    empty!(root.session_objects)
    empty!(root.metadata)   # ⇒ WGLMakie's `get_order!` restarts at 1, in step with the new page's executor
    isready(root.connection_ready) && take!(root.connection_ready)
    root.status = Bonito.RENDERED
    Bonito.CURRENT_SESSION[] = root
    _ANNOUNCE_ROOT[] = true
    return nothing
end

# ── WGLMakie's scene-order sequence ───────────────────────────────────────────────────────────────
# Every WGLMakie scene init is tagged with a strictly CONTIGUOUS order (`get_order!` → the session's
# `:wglmakie_scene_order` metadata) and the browser's `orderedExecutor` runs them in exactly that sequence
# — it will not skip a number. So the counter has to track the PAGE, and nothing else:
#   • a new page starts a fresh executor  ⇒ the sequence must restart at 1;
#   • a worker restart leaves the page's executor mid-sequence ⇒ it must CONTINUE, or the next figure
#     queues behind a number that never comes up and spins forever, silently.
# A session-local counter satisfies the first and BREAKS the second: a fresh worker's root restarts at 1.
# That is the open worker-restart bug. The intended fix is to move the durable home to Slate's per-page
# state (`SlateExtensionsBase.page_state`, which is cleared on a new page and carried across a worker
# restart), seeding WGLMakie's session metadata from it before a render and saving it back after.
#
# NOT WIRED UP: that was built and measured, and it REGRESSED the fresh-load path — a fresh page ended up
# seeded from a stale sequence and stalled. The plumbing (SEB `page_state`, the hub store, the worker tool)
# is in place and unit-tested; what is missing is a correct answer to WHICH renders belong to the attached
# page's sequence. Renders the page never receives (a namespace prime, a discarded re-render) still consume
# numbers, so counting them on the Julia side drifts from what the page actually executed. Until that is
# resolved, resetting per page in `_reset_page!` above is what works.

# The persistent root's own DOM — its `setup_connection` wiring plus `init_session(…, "root", …)` carrying
# every message queued for it — emitted ONCE into the first figure rendered for a freshly-connected page.
#
# Keeping the root means `Bonito.show_html` takes its `parent !== nothing` branch, which emits the figure's
# SUB-session fragment alone. A page that has never seen the root would have nothing for that sub to attach
# to. This supplies it, mirroring what Bonito's own fresh-root branch emits (`init_dom` ahead of `sub_dom`).
function root_announce_html()
    _ANNOUNCE_ROOT[] || return ""
    _ANNOUNCE_ROOT[] = false
    return sprint(show, Bonito.session_dom(_PAGE_ROOT[], Bonito.App(nothing; loading_page = nothing)))
end

# Wire the Julia RECEIVE side for `session`: a `slate_on` handler that feeds decoded browser frames into
# the session's inbox (Bonito's inbox task then `process_message`s them).
#
# Factored out because it must be re-established INDEPENDENTLY of session creation. The handler registry
# (`__slate_handlers`) lives in the notebook NAMESPACE, while `_PAGE_ROOT` is a process global — so a
# "rebuild in a new namespace" wipes the handler while the root (and the browser's live session for it)
# survives. The channel id is unchanged, so the browser keeps sending to `__bonito:<root>` and Julia has
# nobody listening: "no slate_on handler registered for channel …", and the figure stops responding.
# `enable!` re-runs on every namespace rebuild, so calling this there re-attaches the surviving root.
function _wire_receive!(session)
    on = _SLATE_ON[]
    on === nothing && return nothing
    on(_chan(session.id), payload -> (put!(session.inbox, Base64.base64decode(String(payload))); nothing))
    return nothing
end

# Re-attach the persistent page-root's receiver to the CURRENT namespace (see `_wire_receive!`). No-op
# before any root exists.
_rewire_page_root!() = (root = _PAGE_ROOT[]; root === nothing || _wire_receive!(root); nothing)

# Called once per session before its DOM is rendered. Wire the Julia RECEIVE side (a `slate_on` handler
# feeding `session.inbox`) and return the JS that wires the browser side (inbound decode + outbound send).
function Bonito.setup_connection(session::Bonito.Session{SlateConnection})
    session.connection.id = session.id
    chan = _chan(session.id)
    ctl  = _ctl(session.id)
    _wire_receive!(session)   # browser → Julia: base64 payload → raw bytes → this session's inbox
    # Runs for the page ROOT (Bonito wires the connection only for `isroot`; sub-session figures share it).
    # Hold the root so the page can be reset when a fresh browser connects and a new root is established.
    # It OUTLIVES individual cells (figures come and go as cells re-run), so it is NOT torn down per-cell.
    _PAGE_ROOT[] = session
    comp = session.compression_enabled
    return Bonito.js"""
    (() => {
        const chan = $(chan);
        const ctl = $(ctl);
        const compression = $(comp);
        // Idempotent boot: one wiring per session id, even if the fragment's <script> runs more than once
        // (Slate's output swap already dedups identical output; this guards the rest). Re-wiring would
        // stack a duplicate init and trip Bonito's ordered-message system ("Duplicate task for order 1").
        const booted = (window.__bonitoSlate = window.__bonitoSlate || {});
        if (booted[chan]) return;
        booted[chan] = true;
        // Julia → browser: raw binary frame on the Slate stream → straight into Bonito.
        window.slateOnStream(chan, (data) => {
            Bonito.lock_loading(() => {
                Bonito.process_message(Bonito.decode_binary(data.d, compression));
            });
        });
        // Free this session on the page: drop the WGL session if Bonito exposes it, then unsubscribe BOTH
        // streams so no dead handler lingers in the slate stream registry.
        const teardown = () => {
            try { Bonito.free_session && Bonito.free_session(chan.slice("__bonito:".length)); } catch (e) {}
            window.slateOffStream(chan);
            window.slateOffStream(ctl);
            delete booted[chan];
        };
        // Teardown signal from Julia (`_teardown_session!`), for a session the worker retires itself.
        window.slateOnStream(ctl, teardown);
        // Teardown when the WORKER is replaced. That signal can't come from Julia: the process that owned
        // this session is the one that died, so nothing is left to send on `ctl` — and this session's
        // channel now has no receiver, so the page would keep sending into the void ("no slate_on handler
        // registered for channel …") and the figure would wait forever. Slate's hub notifies the page
        // instead, and we retire ourselves so the fresh worker's render starts from a clean page.
        window.slateOnWorkerReset && window.slateOnWorkerReset(teardown);
        // browser → Julia: register our sender + drive the connection lifecycle EXPLICITLY. This is the
        // crux of routing Bonito live over Slate's transport. `NoServer` boots the page in Bonito's
        // "no_connection" (static) mode, where `send_to_julia` DROPS every browser→Julia message — so the
        // init's `send_done_loading` (JSDoneLoading) is lost and the Julia session never leaves DISPLAYED
        // (its `on_open` never fires, so WGLMakie never ships its scene → the spinner hangs forever).
        // Fix: mark the connection OPEN with our sender (pings off — Slate's own WS keepalive suffices),
        // then RE-SEND JSDoneLoading now that sends flow, so the Julia session opens and flushes.
        const send = (binary) => Bonito.base64encode(binary).then((b64) => window.slateCall(chan, b64));
        const C = Bonito.Connection;
        C.on_connection_open(send, compression, false);
        C.send_done_loading(chan.slice("__bonito:".length), null);
    })()
    """
end
