# DataChannels.jl

WebRTC peer connections and data channels for Julia, wrapping the C API of
[libdatachannel](https://github.com/paullouisageneau/libdatachannel) 0.20 (from
`libdatachannel_jll`). Two machines behind NATs get a direct, encrypted (DTLS/SCTP) message
channel; the application carries the signaling between them.

## Example

```julia
using DataChannels

pc = PeerConnection()                      # STUN: stun.cloudflare.com:3478
@async for s in signals(pc)                # Description / Candidate to the other side
    send_to_peer(s)                        # by any means: HTTP, a websocket, copy and paste
end
# Whatever arrives from the other side:
#   set_remote_description!(pc, d::Description)
#   add_remote_candidate!(pc, c::Candidate)

dc = create_data_channel(pc, "files")      # the other side gets it from accept(pc)
wait_open(dc)
send(dc, "hello")
send(dc, read("data.bin"))
for msg in dc                              # String (text) or Vector{UInt8} (binary)
    @show msg
end
close(pc)
```

## API

Peer connections

- `PeerConnection(; ice_servers = ["stun:stun.cloudflare.com:3478"], bind_address, port_range,
  ice_udp_mux, relay_only, mtu, max_message_size, auto_negotiation = true)`.
  TURN servers are given as `"turn:user:password@host:port"`.
- `signals(pc)`: a `Channel` of `Description(type, sdp)` and `Candidate(candidate, mid)` to forward
  to the remote peer.
- `set_remote_description!(pc, ::Description)`, `add_remote_candidate!(pc, ::Candidate)`.
- `set_local_description!(pc, type = "")` when `auto_negotiation = false`.
- `local_description(pc)`, the full SDP with every candidate gathered so far, and
  `wait_gathering(pc; timeout)`, for signaling that sends one message instead of trickling
  candidates.
- `state(pc)`: `:new`, `:connecting`, `:connected`, `:disconnected`, `:failed`, `:closed`.
  `wait_state(pc, states...; timeout)`. `gathering_state(pc)`: `:new`, `:in_progress`, `:complete`.
- `accept(pc)`: the next data channel the remote peer opened.
- `selected_candidate_pair(pc)`: a `CandidatePair(local_candidate, remote_candidate)`, or `nothing`
  before ICE has chosen one. `candidate_type(c)` gives `:host`, `:srflx`, `:prflx` or `:relay`.
  `local_address(pc)`, `remote_address(pc)`.
- `close(pc)` closes its channels and the connection. It also happens on its own when the remote
  peer closes the connection.

Data channels

- `create_data_channel(pc, label; ordered = true, reliable = true, max_retransmits = 0,
  max_packet_lifetime = 0, protocol = "", negotiated = false, stream = nothing)`.
- `send(dc, ::AbstractVector{UInt8})`, `send(dc, ::AbstractString)`: one message each.
- `take!(dc)`, `isready(dc)`, `for msg in dc`: received messages; iteration ends when the channel
  closes.
- `isopen(dc)`, `wait_open(dc; timeout)`, `close(dc)`.
- `buffered_amount(dc)`, `wait_writable(dc)`, `set_watermarks!(dc; low, high)`: `wait_writable`
  returns at once while at most `high` bytes (default 4 MiB) wait to be sent, and otherwise waits
  until the buffer drains to `low` (default 1 MiB). A bulk sender calls it before each `send`.
- `label(dc)`, `protocol(dc)`, `stream_id(dc)`, `max_message_size(dc)`.

`set_log_level(level)` routes libdatachannel's log (default `:warning`) to Julia's logger.
`DataChannels.shutdown()` closes everything and stops libdatachannel's threads; it runs at exit.

Errors from libdatachannel are thrown as `RTCError`; using a closed channel or connection throws
`InvalidStateException`.

## Threading model

libdatachannel runs its own threads and invokes callbacks on them. Julia adopts such a thread the
first time it calls a `@cfunction`. The callbacks here do only this: copy their arguments (SDP,
candidate, message bytes) into an event, push it onto one queue under a spin lock, and wake a
dispatcher task with `uv_async_send`. They never wait on a task lock, never run user code and
never throw.

The dispatcher task (on the interactive thread pool when there is one) drains the queue in order
and routes each event by its libdatachannel id to the registered `PeerConnection` or
`DataChannel`, putting messages into unbounded `Channel`s and notifying conditions. No Julia
object pointer is handed to C.

Every `ccall` into libdatachannel is `gc_safe`. libdatachannel holds internal locks while it runs a
callback; if a Julia thread were blocked on such a lock inside an ordinary `ccall`, a garbage
collection requested by the callback thread could never start.

`close` of a channel or connection unregisters it and then deletes it in libdatachannel, which
waits for any callback in progress and disables further ones; events still queued for it are
dropped.

## Known limits

- **Throughput** in-process over a local interface is about 30-50 MB/s on an Apple-silicon Mac,
  close to what the same transfer gets from C against the same library (35-42 MB/s). The cost is
  in libdatachannel's SCTP stack (usrsctp over DTLS), not in the Julia layer.
- **Connection setup** takes about one second locally, most of it a DTLS retransmission: the
  first handshake packet arrives before the other side's DTLS transport has started.
- **ICE is libjuice** in the JLL build: UDP only. No ICE-TCP, no proxy. Only the first STUN server
  in `ice_servers` is used. TURN works over UDP only; `turns:` and `?transport=tcp` URLs are
  accepted but used over UDP, so networks that allow only TCP/443 cannot be traversed. TURN is not
  available together with `ice_udp_mux`. ICE restarts are not supported.
- **Message size**: libdatachannel accepts up to 256 KiB per message by default, and sends no more
  than the remote peer advertises (64 KiB if the remote SDP says nothing). Chunk at 64 KiB to
  stay safe with any peer.
- **No receive backpressure.** Received messages are copied into an unbounded channel; a consumer
  slower than the sender grows memory on the receiving side. Flow control has to come from the
  application (acknowledgements, windows).
- **GC pauses stall libdatachannel's threads**: a callback thread entering Julia waits for a
  collection in progress. Ordinary pauses are harmless; heavy allocation elsewhere in the process
  lowers throughput.
- Only data channels are wrapped; media tracks and WebSockets in the same library are not.
