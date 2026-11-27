# The hub in the room (see collab.jl). Besides the browsers, the hubs of the people writing a notebook
# meet in its room, on the `<room>#hubs` topic, and connect to each other directly with WebRTC
# (lib/DataChannels), the knowledge base relaying only their handshake. A channel between two hubs is
# what running a cell on another participant's machine, and moving values between their kernels, will
# travel over; for now it carries hellos, round trips and probes of how fast it is.
#
# On a channel, a text message is a JSON control message (`t` its kind), a binary one a chunk of the
# payload the last control message announced.

import DataChannels
using DataChannels: PeerConnection, Description, Candidate, signals, create_data_channel, wait_open,
    wait_writable, selected_candidate_pair, candidate_type, set_remote_description!, add_remote_candidate!

"How long a call or a request between hubs is given."
const HUB_TIMEOUT = 30.0
"The size of a chunk of a payload: 64 KiB, which any peer accepts."
const HUB_CHUNK = 1 << 16

mutable struct HubPeer
    const id::String
    name::String
    pc::Union{Nothing,PeerConnection}
    dc::Any                                  # its DataChannel once open, else nothing
    state::Symbol                            # :connecting, :open, :closed
    rtt_ms::Union{Nothing,Float64}
    const waiting::Dict{String,Channel{Any}}  # replies awaited, by request id
    incoming::Any                            # a payload being received: (; id, bytes, sha, buf, t0)
end
HubPeer(id, name) = HubPeer(id, name, nothing, nothing, :connecting, nothing, Dict{String,Channel{Any}}(), nothing)

mutable struct HubLink
    const nb_id::String
    const room::String
    const ws_url::String
    const me::String
    const name::String
    const peers::Dict{String,HubPeer}
    const lock::ReentrantLock
    ws::Any
    closed::Bool
end

const HUB_LINKS = Dict{String,HubLink}()   # by notebook id
const HUB_LINKS_LOCK = ReentrantLock()

_hub_topic(l::HubLink) = l.room * "#hubs"

function _hub_publish(l::HubLink, data)
    ws = l.ws
    ws === nothing && return
    msg = JSON.json(Dict("type" => "publish", "topic" => _hub_topic(l), "data" => data))
    try
        lock(() -> HTTP.WebSockets.send(ws, msg), l.lock)
    catch
    end
end

"""
    collab_hub_join!(nb, ticket)

Have notebook `nb`'s hub take part in the room `ticket` (from [`collab_ticket`](@ref)) admits it
to: kept as it is when already there, moved when the room changed.
"""
function collab_hub_join!(nb, t)
    lock(HUB_LINKS_LOCK) do
        old = get(HUB_LINKS, nb.id, nothing)
        old !== nothing && !old.closed && old.room == t.room && return old
        old === nothing || _hub_leave!(old)
        l = HubLink(nb.id, t.room, t.ws, bytes2hex(rand(UInt8, 6)), t.name, Dict{String,HubPeer}(), ReentrantLock(), nothing, false)
        HUB_LINKS[nb.id] = l
        errormonitor(Threads.@spawn _hub_run(l))
        return l
    end
end

"Notebook `nb`'s hub leaves its room."
function collab_hub_leave!(nb)
    l = lock(() -> pop!(HUB_LINKS, nb.id, nothing), HUB_LINKS_LOCK)
    l === nothing || _hub_leave!(l)
    return nothing
end

function _hub_leave!(l::HubLink)
    l.closed && return
    _hub_publish(l, Dict("type" => "bye", "from" => l.me))
    l.closed = true
    for p in collect(values(l.peers))
        _hub_drop!(p)
    end
    ws = l.ws
    ws === nothing || try; close(ws); catch; end
end

function _hub_drop!(p::HubPeer)
    p.state = :closed
    pc = p.pc
    pc === nothing || try; close(pc); catch; end
    for (_, ch) in p.waiting
        try; close(ch); catch; end
    end
end

# The room's WebSocket, kept open while the hub is in the room: reconnected with a growing pause.
function _hub_run(l::HubLink)
    pause = 1.0
    while !l.closed
        try
            HTTP.WebSockets.open(l.ws_url) do ws
                l.ws = ws
                pause = 1.0
                lock(() -> HTTP.WebSockets.send(ws, JSON.json(Dict("type" => "subscribe", "topics" => [_hub_topic(l)]))), l.lock)
                _hub_publish(l, Dict("type" => "announce", "from" => l.me, "name" => l.name))
                for raw in ws
                    l.closed && break
                    _hub_message(l, raw)
                end
            end
        catch e
            l.closed || @debug "slate collab: the room's socket closed" exception = e
        end
        l.ws = nothing
        l.closed && break
        sleep(pause)
        pause = min(30.0, 2pause)
    end
end

function _hub_message(l::HubLink, raw)
    m = try JSON.parse(raw isa AbstractString ? raw : String(copy(raw))) catch; return end
    (m isa AbstractDict && get(m, "type", "") == "publish") || return
    d = get(m, "data", nothing)
    d isa AbstractDict || return
    from = string(get(d, "from", ""))
    (isempty(from) || from == l.me) && return
    to = get(d, "to", nothing)
    to === nothing || to == l.me || return
    kind = get(d, "type", "")
    if kind == "announce"
        _hub_meet!(l, from, string(get(d, "name", "")); answer = to === nothing)
    elseif kind == "signal"
        _hub_signal!(l, from, get(d, "signal", nothing))
    elseif kind == "bye"
        p = lock(() -> pop!(l.peers, from, nothing), l.lock)
        p === nothing || _hub_drop!(p)
    end
end

# A hub announced, or was heard from: known from now on, and called if it is ours to call (the lower id calls).
function _hub_meet!(l::HubLink, id, name; answer::Bool)
    p, fresh = lock(l.lock) do
        p = get(l.peers, id, nothing)
        p !== nothing && return (p, false)
        p = HubPeer(id, name)
        l.peers[id] = p
        (p, true)
    end
    isempty(name) || (p.name = name)
    fresh || return p
    answer && _hub_publish(l, Dict("type" => "announce", "from" => l.me, "to" => id, "name" => l.name))
    l.me < id && errormonitor(Threads.@spawn _hub_call!(l, p))
    return p
end

function _hub_pc!(l::HubLink, p::HubPeer)
    p.pc === nothing || return p.pc
    pc = PeerConnection()
    p.pc = pc
    # What this side says, to the other hub through the room; what it opens, taken as the channel.
    say = Threads.@spawn for s in signals(pc)
        sig = s isa Description ? Dict("sdp" => s.sdp, "type" => s.type) : Dict("candidate" => s.candidate, "mid" => s.mid)
        _hub_publish(l, Dict("type" => "signal", "from" => l.me, "to" => p.id, "signal" => sig))
    end
    take = Threads.@spawn try
        _hub_channel!(l, p, DataChannels.accept(pc))
    catch e
        e isa InvalidStateException || p.state == :closed || @debug "slate collab: no channel from a hub" exception = e
    end
    errormonitor(say)
    errormonitor(take)
    return pc
end

function _hub_call!(l::HubLink, p::HubPeer)
    pc = _hub_pc!(l, p)
    _hub_channel!(l, p, create_data_channel(pc, "hub"))
end

function _hub_signal!(l::HubLink, from, s)
    s isa AbstractDict || return
    p = _hub_meet!(l, from, ""; answer = false)
    pc = _hub_pc!(l, p)
    try
        if haskey(s, "sdp")
            set_remote_description!(pc, string(s["sdp"]), string(get(s, "type", "")))
        elseif haskey(s, "candidate")
            add_remote_candidate!(pc, string(s["candidate"]), string(get(s, "mid", "")))
        end
    catch e
        @debug "slate collab: a hub's signal was refused" exception = e
    end
end

function _hub_channel!(l::HubLink, p::HubPeer, dc)
    wait_open(dc; timeout = HUB_TIMEOUT) || (p.state = :closed; return)
    p.dc = dc
    p.state = :open
    _hub_send(p, Dict("t" => "hello", "name" => l.name))
    errormonitor(Threads.@spawn _hub_pings(p))
    for msg in dc
        try
            msg isa AbstractString ? _hub_control!(p, JSON.parse(msg)) : _hub_chunk!(p, msg)
        catch e
            @debug "slate collab: a hub's message failed" exception = e
        end
    end
    p.state = :closed
end

_hub_send(p::HubPeer, d) = DataChannels.send(p.dc, JSON.json(d))

function _hub_control!(p::HubPeer, m)
    t = get(m, "t", "")
    if t == "hello"
        p.name = string(get(m, "name", p.name))
    elseif t == "ping"
        _hub_send(p, Dict("t" => "pong", "id" => m["id"]))
    elseif t == "probe"
        p.incoming = (; id = string(m["id"]), bytes = Int(m["bytes"]), sha = string(m["sha"]), buf = IOBuffer(), t0 = time())
        Int(m["bytes"]) == 0 && _hub_probe_done!(p)
    elseif haskey(m, "id")
        ch = get(p.waiting, string(m["id"]), nothing)
        ch === nothing || put!(ch, m)
    end
end

function _hub_chunk!(p::HubPeer, bytes::Vector{UInt8})
    r = p.incoming
    r === nothing && return
    write(r.buf, bytes)
    position(r.buf) >= r.bytes && _hub_probe_done!(p)
end

function _hub_probe_done!(p::HubPeer)
    r = p.incoming
    p.incoming = nothing
    data = take!(r.buf)
    _hub_send(p, Dict("t" => "probe_ok", "id" => r.id, "verified" => bytes2hex(SHA.sha256(data)) == r.sha,
                      "bytes" => length(data), "seconds" => time() - r.t0))
end

# Ask the other hub `m` and wait for its answer (a control message with the same `id`).
function _hub_ask(p::HubPeer, m::AbstractDict; timeout::Real = HUB_TIMEOUT, payload = nothing)
    id = bytes2hex(rand(UInt8, 6))
    ch = Channel{Any}(1)
    p.waiting[id] = ch
    try
        _hub_send(p, merge(m, Dict("id" => id)))
        if payload !== nothing
            for i in 1:HUB_CHUNK:length(payload)
                wait_writable(p.dc)
                DataChannels.send(p.dc, view(payload, i:min(i + HUB_CHUNK - 1, length(payload))))
            end
        end
        # Woken by the answer itself; the timer closes the channel if none comes.
        late = Timer(_ -> close(ch), timeout)
        try
            return take!(ch)
        catch
            error(isopen(late) ? "the channel to the other hub closed" : "the other hub did not answer in $(timeout) s")
        finally
            close(late)
        end
    finally
        delete!(p.waiting, id)
    end
end

function _hub_pings(p::HubPeer)
    while p.state == :open
        try
            t0 = time()
            _hub_ask(p, Dict("t" => "ping"); timeout = 10)
            p.rtt_ms = round((time() - t0) * 1000; digits = 1)
        catch
        end
        sleep(10)
    end
end

"""
    collab_hubs(nb) -> Vector{NamedTuple}

The hubs notebook `nb`'s hub has met in its room: `(; id, name, state, local, remote, rtt_ms)`,
`local` and `remote` the selected candidates' types (`host`, `srflx`, `prflx`, `relay`).
"""
function collab_hubs(nb)
    l = lock(() -> get(HUB_LINKS, nb.id, nothing), HUB_LINKS_LOCK)
    l === nothing && return (; room = "", connected = false, peers = NamedTuple[])
    peers = map(collect(values(l.peers))) do p
        pair = p.pc === nothing ? nothing : try selected_candidate_pair(p.pc) catch; nothing end
        (; id = p.id, name = p.name, state = String(p.state),
           var"local" = pair === nothing ? "" : String(candidate_type(pair.local_candidate)),
           remote = pair === nothing ? "" : String(candidate_type(pair.remote_candidate)), rtt_ms = p.rtt_ms)
    end
    return (; room = l.room, connected = l.ws !== nothing, peers)
end

"""
    collab_probe(nb, peer, bytes) -> NamedTuple

Send `bytes` random bytes to hub `peer` (an id from [`collab_hubs`](@ref), or its name) over their
channel, the other hub checking their SHA-256: `(; bytes, seconds, mb_per_s, verified)`.
"""
function collab_probe(nb, peer::AbstractString, nbytes::Integer)
    l = lock(() -> get(HUB_LINKS, nb.id, nothing), HUB_LINKS_LOCK)
    l === nothing && error("This hub is in no room")
    p = get(l.peers, peer, nothing)
    if p === nothing
        k = findfirst(x -> x.name == peer, l.peers)
        p = k === nothing ? nothing : l.peers[k]
    end
    (p === nothing || p.state != :open) && error("No open channel to the hub $peer")
    data = rand(UInt8, nbytes)
    t0 = time()
    r = _hub_ask(p, Dict("t" => "probe", "bytes" => nbytes, "sha" => bytes2hex(SHA.sha256(data))); payload = data,
                 timeout = max(HUB_TIMEOUT, nbytes / 1e6))
    s = time() - t0
    return (; bytes = nbytes, seconds = round(s; digits = 3), mb_per_s = round(nbytes / 1e6 / s; digits = 1),
              verified = get(r, "verified", false) === true)
end
