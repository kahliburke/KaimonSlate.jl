# Whose hub a CURVE key is (see collab_hub.jl). When one participant's hub reaches another's worker,
# its long-term CURVE key says who is asking; an authority vouches for keys. The knowledge base the
# room is at is the first (ZemiKeys): a hub registers its key with the person's account when it asks
# for a ticket, and the knowledge base vouches for the keys of the people who may contribute to the
# room's project, dropping those of anyone taken off it. Others (comparing fingerprints, trust on
# first use) can be added beside it.

"Vouches for hubs' CURVE public keys (Z85)."
abstract type KeyAuthority end

"""
    key_owner(authority, key) -> Union{NamedTuple,Nothing}

`(; name, label, user_id)` of the person whose hub `key` is, while `authority` vouches for it;
`nothing` for a key it does not vouch for.
"""
function key_owner end

"""
    refresh_keys!(authority) -> Vector{String}

Ask again which keys `authority` vouches for. Returns those it no longer does.
"""
function refresh_keys! end

"The keys a knowledge base vouches for in project `project`'s rooms (collab.jl's hub keys there)."
mutable struct ZemiKeys <: KeyAuthority
    const origin::String
    const project::String
    keys::Dict{String,NamedTuple}
    checked::Float64
end

function ZemiKeys(origin::AbstractString, project::AbstractString, list)
    k = ZemiKeys(String(origin), String(project), Dict{String,NamedTuple}(), 0.0)
    _set_keys!(k, list)
    return k
end

function _set_keys!(k::ZemiKeys, list)
    k.keys = Dict{String,NamedTuple}(String(x["key"]) => (; name = String(get(x, "name", "")), label = String(get(x, "label", "")),
                                                          user_id = Int(get(x, "user_id", 0)))
                                     for x in list if x isa AbstractDict && haskey(x, "key"))
    k.checked = time()
    return k
end

key_owner(k::ZemiKeys, key::AbstractString) = get(k.keys, String(key), nothing)

function refresh_keys!(k::ZemiKeys)
    token = bib_access_token(k.origin)
    resp = _BIB_GET[](k.origin * "/api/projects/" * k.project * "/collab/keys",
                      ["Accept" => "application/json", (isempty(token) ? Pair{String,String}[] : ["Authorization" => "Bearer " * token])...])
    resp.status == 200 || return String[]
    before = Set(keys(k.keys))
    _set_keys!(k, get(JSON.parse(String(resp.body)), "keys", Any[]))
    return collect(setdiff(before, keys(k.keys)))
end
