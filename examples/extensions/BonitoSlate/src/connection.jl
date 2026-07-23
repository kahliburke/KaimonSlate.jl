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
# One channel per Bonito session id keeps multiple figures independent. Paired with `NoServer` (which
# inlines the Bonito bundle + init blob as `data:` URLs), the emitted fragment references NO localhost
# URL and opens NO extra port — so it also works for a remote/region worker.

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

# Called once per session before its DOM is rendered. Wire the Julia RECEIVE side (a `slate_on` handler
# feeding `session.inbox`) and return the JS that wires the browser side (inbound decode + outbound send).
function Bonito.setup_connection(session::Bonito.Session{SlateConnection})
    session.connection.id = session.id
    chan = _chan(session.id)
    ctl  = _ctl(session.id)
    on = _SLATE_ON[]
    if on !== nothing
        # browser → Julia: base64 payload → raw bytes → Bonito's inbox task (`process_message`).
        on(chan, payload -> (put!(session.inbox, Base64.base64decode(String(payload))); nothing))
    end
    # Close this session when its cell re-runs / is deleted / the namespace rebuilds. `setup_connection`
    # runs synchronously during the figure's `show`, on the cell's EVAL task — so the registration lands
    # against the right cell (the callback itself is self-contained; see `_teardown_session!`).
    SlateExtensionsBase.slate_on_cleanup(() -> _teardown_session!(session))
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
        // Teardown signal from Julia (`_teardown_session!`): free the WGL session if Bonito exposes it,
        // then unsubscribe BOTH streams so no dead handler lingers in the slate stream registry.
        window.slateOnStream(ctl, () => {
            try { Bonito.free_session && Bonito.free_session(chan.slice("__bonito:".length)); } catch (e) {}
            window.slateOffStream(chan);
            window.slateOffStream(ctl);
            delete booted[chan];
        });
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
