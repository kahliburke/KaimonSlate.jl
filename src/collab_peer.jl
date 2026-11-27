# Running a cell on another participant's worker (see collab_hub.jl and the worker's `_peer_run`).
# Each hub has a CURVE key pair of its own, which the knowledge base vouches for (collab_keys.jl) and
# which it presents when it asks another's worker to run a cell. A cell's owner grants it to another
# hub: the owner's hub gives its worker the cell's source and hash for that hub's key (gate protocol
# v3: the worker admits the key as a peer and runs only what is granted), and tells the other hub
# where to ask. The other hub then asks by cell id and hash; it never sends code.

"Where a hub keeps its CURVE key pair: Slate's config folder, readable by its owner alone."
hub_key_path() = joinpath(SlateHome.config_home(), "collab", "hub.key")

const _HUB_KEYPAIR = Ref{Union{Nothing,Tuple{String,String}}}(nothing)

"""
    hub_keypair() -> (public, secret)

This hub's CURVE key pair (Z85), made the first time and kept in `hub_key_path()` (public key, then
secret, one per line, mode 0600).
"""
function hub_keypair()
    kp = _HUB_KEYPAIR[]
    kp === nothing || return kp
    path = hub_key_path()
    if isfile(path)
        lines = readlines(path)
        length(lines) >= 2 && length(lines[1]) == 40 && length(lines[2]) == 40 && return (_HUB_KEYPAIR[] = (lines[1], lines[2]))
    end
    pub, sec = zeros(UInt8, 41), zeros(UInt8, 41)
    ccall((:zmq_curve_keypair, ZMQ.lib.libzmq), Cint, (Ptr{UInt8}, Ptr{UInt8}), pub, sec) == 0 ||
        error("This libzmq has no CURVE")
    kp = (unsafe_string(pointer(pub)), unsafe_string(pointer(sec)))
    mkpath(dirname(path))
    tmp = path * ".tmp"
    open(tmp, "w") do io
        chmod(tmp, 0o600)
        println(io, kp[1]); println(io, kp[2])
    end
    mv(tmp, path; force = true)
    return (_HUB_KEYPAIR[] = kp)
end

const _ZMQ_CURVE_PUBLICKEY, _ZMQ_CURVE_SECRETKEY, _ZMQ_CURVE_SERVERKEY = 48, 49, 50

function _zset(sock, opt::Integer, s::AbstractString)
    b = codeunits(String(s))
    rc = GC.@preserve b ZMQ.lib.zmq_setsockopt(sock, Cint(opt), pointer(b), length(b))
    rc == 0 || error("zmq_setsockopt($opt) failed")
end

"""
    peer_ask(endpoint, server_key, text; timeout = 60) -> String

Ask another participant's worker at `endpoint` (`tcp://host:port`), whose CURVE server key is
`server_key`, as this hub's key: send `text` (a TOML request) and return its answer.
"""
function peer_ask(endpoint::AbstractString, server_key::AbstractString, text::AbstractString; timeout::Real = 60)
    pub, sec = hub_keypair()
    ctx = ZMQ.Context()
    sock = ZMQ.Socket(ctx, ZMQ.REQ)
    try
        sock.linger = 0
        sock.rcvtimeo = round(Int, 1000 * timeout)
        _zset(sock, _ZMQ_CURVE_SERVERKEY, server_key)
        _zset(sock, _ZMQ_CURVE_PUBLICKEY, pub)
        _zset(sock, _ZMQ_CURVE_SECRETKEY, sec)
        ZMQ.connect(sock, endpoint)
        ZMQ.send(sock, text)
        return String(ZMQ.recv(sock, Vector{UInt8}))
    catch e
        e isa ZMQ.TimeoutError && error("The other worker did not answer in $(timeout) s (not admitted, or away)")
        rethrow()
    finally
        close(sock)
        close(ctx)
    end
end

# ── Granting, on the cell's owner's hub ─────────────────────────────────────────────────────────

"What this hub has granted, per notebook: peer key → cell id → `(; hash, source)`."
const _GRANTS = Dict{String,Dict{String,Dict{String,NamedTuple}}}()
const _GRANTS_LOCK = ReentrantLock()

"The notebook's worker, when it is one other hubs can be granted cells on (a gated worker serving CURVE)."
function _grantable_worker(nb)
    k = nb.kernel
    k isa ReportEngine.GateKernel || error("This notebook's worker is not a gated one: cells cannot be run on it for others")
    keys = ReportEngine._local_curve_keys()
    keys === nothing && error("This notebook's worker serves without CURVE, so it cannot tell who asks: nothing can be granted on it")
    return (; kernel = k, server_key = keys.server, endpoint = "tcp://127.0.0.1:$(k.port)")
end

# The whole policy, as the worker takes it: who's who among the granted hubs, and their cells.
function _policy_toml(nb_id::String)
    g = lock(() -> deepcopy(get(_GRANTS, nb_id, Dict{String,Dict{String,NamedTuple}}())), _GRANTS_LOCK)
    keys = Dict{String,String}()
    grants = Dict{String,Any}()
    for (i, (key, cells)) in enumerate(sort!(collect(g); by = first))
        isempty(cells) && continue
        id = "p$i"
        keys[key] = id
        grants[id] = Dict(c => Dict("hash" => v.hash, "source" => v.source) for (c, v) in cells)
    end
    return sprint(TOML.print, Dict("keys" => keys, "grants" => grants))
end

_push_policy!(nb, w) = ReportEngine._tool(w.kernel, "__slate_peer_policy", Dict("policy" => _policy_toml(nb.id)))

"""
    collab_grant!(nb, cell, peer) -> NamedTuple

Grant cell `cell` of notebook `nb` to hub `peer` (an id from `collab_hubs`): its worker may run that
cell's present source for that hub's key. The grant is sent to the hub. A changed cell needs granting
again. Returns `(; cell, hash, to)`.
"""
function collab_grant!(nb, cell::AbstractString, peer::AbstractString)
    l = lock(() -> get(HUB_LINKS, nb.id, nothing), HUB_LINKS_LOCK)
    l === nothing && error("This notebook is in no room")
    p = lock(() -> get(l.peers, String(peer), nothing), l.lock)
    (p === nothing || p.state != :open) && error("No hub $peer in the room")
    isempty(p.key) && error("That hub has no key to grant to")
    p.vouched === nothing && error("That hub's key is not one the knowledge base vouches for")
    c = findfirst(x -> x.id == cell, nb.report.cells)
    c === nothing && error("No cell $cell")
    source = nb.report.cells[c].source
    hash = bytes2hex(SHA.sha256(source))
    w = _grantable_worker(nb)
    lock(_GRANTS_LOCK) do
        get!(Dict{String,Dict{String,NamedTuple}}, _GRANTS, nb.id)
        get!(Dict{String,NamedTuple}, _GRANTS[nb.id], p.key)[String(cell)] = (; hash, source)
    end
    _push_policy!(nb, w)
    _hub_send(p, Dict("t" => "grant", "cell" => String(cell), "hash" => hash, "server_key" => w.server_key,
                      "endpoint" => w.endpoint))
    return (; cell = String(cell), hash, to = p.name)
end

"Take back cell `cell`'s grant to hub `peer` (all its cells when `cell` is empty)."
function collab_revoke!(nb, cell::AbstractString, peer::AbstractString)
    l = lock(() -> get(HUB_LINKS, nb.id, nothing), HUB_LINKS_LOCK)
    p = l === nothing ? nothing : lock(() -> get(l.peers, String(peer), nothing), l.lock)
    key = p === nothing ? String(peer) : p.key
    lock(_GRANTS_LOCK) do
        cells = get(get(_GRANTS, nb.id, Dict()), key, nothing)
        cells === nothing && return
        isempty(cell) ? empty!(cells) : delete!(cells, String(cell))
    end
    try _push_policy!(nb, _grantable_worker(nb)) catch end
    p === nothing || p.state != :open || _hub_send(p, Dict("t" => "revoke", "cell" => String(cell)))
    return (; cell = String(cell))
end

# ── Running, on the grantee's hub ────────────────────────────────────────────────────────────────

"""
    collab_run_granted(nb, cell) -> Dict

Run cell `cell`, granted to this hub by another, on that other's worker: its answer, the run's
`stdout`, `stderr`, `value`, `displays`, `exception` and `duration_ms`, with `ran_on`, whose worker it
was.
"""
function collab_run_granted(nb, cell::AbstractString)
    l = lock(() -> get(HUB_LINKS, nb.id, nothing), HUB_LINKS_LOCK)
    l === nothing && error("This notebook is in no room")
    g = lock(() -> get(l.received, String(cell), nothing), l.lock)
    g === nothing && error("Cell $cell is granted to this hub by no one")
    answer = peer_ask(g.endpoint, g.server_key, sprint(TOML.print, Dict("verb" => "run", "cell" => String(cell), "hash" => g.hash)))
    r = TOML.parse(answer)
    r["ran_on"] = g.name
    return r
end
