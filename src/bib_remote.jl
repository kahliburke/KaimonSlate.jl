# A bibliography a `:bibliography` cell names by its address: a knowledge base's site (its `api/bib`)
# or a `.bib` URL. The hub fetches it with the API token saved for its host, keeps the last copy on
# disk, and revalidates that copy with its ETag. A notebook never waits for the network: it uses the
# copy it has, and is redrawn when a fetch brings a new one.

_bib_is_url(s::AbstractString) = occursin(r"^https?://"i, s)

"The address fetched for a bibliography line: a `.bib` URL as given, else the site's `api/bib`."
function bib_endpoint(line::AbstractString)
    u = String(strip(line))
    endswith(lowercase(first(split(u, '?'))), ".bib") && return u
    m = match(r"^(https?://[^/?#]+)"i, u)
    return (m === nothing ? rstrip(u, '/') : m.captures[1]) * "/api/bib"
end

"The secret ref holding the API token for a bibliography address's host (`bib:host[:port]`)."
function bib_token_ref(url::AbstractString)
    m = match(r"^https?://([^/?#]+)"i, url)
    return "bib:" * lowercase(m === nothing ? String(url) : m.captures[1])
end

mutable struct BibRemote
    const url::String
    text::String
    etag::String
    fetched::Float64                  # when `text` was last confirmed current (0: never)
    checked::Float64                  # when it was last asked for
    status::Symbol                    # :ok, :pending, :signin, :denied, :error
    message::String
    entries::Vector{_BibEntry}
    fetching::Bool
    const waiters::Vector{WeakRef}    # notebooks to redraw when it changes
end

const _BIB_REMOTES = Dict{String,BibRemote}()
const _BIB_REMOTE_LOCK = ReentrantLock()
const BIB_RECHECK_SECONDS = Ref(300.0)
# Replaced in tests: `(url, headers) -> HTTP.Response`.
const _BIB_GET = Ref{Any}((url, headers) -> HTTP.get(url, headers; status_exception = false, redirect = false,
                                                     retry = false, connect_timeout = 10, readtimeout = 60))

_bib_cache_file(url, ext) = joinpath(SlateHome.cache_home(), "bib", bytes2hex(SHA.sha1(url))[1:20] * ext)

function _bib_load_cached(url::AbstractString)
    r = BibRemote(url, "", "", 0.0, 0.0, :pending, "", _BibEntry[], false, WeakRef[])
    f = _bib_cache_file(url, ".bib")
    if isfile(f)
        meta = try; JSON.parse(read(_bib_cache_file(url, ".json"), String)); catch; Dict{String,Any}(); end
        r.text = read(f, String)
        r.etag = String(get(meta, "etag", ""))
        r.fetched = Float64(get(meta, "fetched", 0.0))
        r.entries = _parse_bibtex_entries(r.text)
        r.status = :ok
    end
    return r
end

function _bib_save_cached(r::BibRemote)
    mkpath(dirname(_bib_cache_file(r.url, ".bib")))
    write(_bib_cache_file(r.url, ".bib"), r.text)
    write(_bib_cache_file(r.url, ".json"), JSON.json(Dict("url" => r.url, "etag" => r.etag, "fetched" => r.fetched)))
end

"""
    bib_remote(url; nb = nothing, refresh = false) -> BibRemote

The bibliography at `url` (an endpoint from [`bib_endpoint`](@ref)) as the hub has it now. A copy
older than `BIB_RECHECK_SECONDS`, or `refresh`, starts a fetch in the background; `nb` is redrawn when
it brings a change.
"""
function bib_remote(url::AbstractString; nb = nothing, refresh::Bool = false)
    r = lock(_BIB_REMOTE_LOCK) do
        r = get!(() -> _bib_load_cached(String(url)), _BIB_REMOTES, String(url))
        if nb !== nothing && !any(w -> w.value === nb, r.waiters)
            filter!(w -> w.value !== nothing, r.waiters)
            push!(r.waiters, WeakRef(nb))
        end
        if !r.fetching && (refresh || time() - r.checked > BIB_RECHECK_SECONDS[])
            r.fetching = true
            r.checked = time()
            errormonitor(Threads.@spawn _bib_refresh!(r))
        end
        r
    end
    return r
end

# Fetch `r.url`, revalidating the copy held. Called with `r.fetching` set; clears it.
function _bib_refresh!(r::BibRemote)
    before = (r.status, r.message, r.etag)
    try
        token = String(get(_secrets_or_empty(), bib_token_ref(r.url), ""))
        headers = ["Accept" => "text/plain"]
        isempty(token) || push!(headers, "Authorization" => "Bearer " * token)
        (isempty(r.etag) || isempty(r.text)) || push!(headers, "If-None-Match" => r.etag)
        resp = _BIB_GET[](r.url, headers)
        s = resp.status
        if s == 304
            r.status, r.message, r.fetched = :ok, "", time()
        elseif s == 200
            r.text = String(resp.body)
            r.etag = String(HTTP.header(resp, "ETag", ""))
            r.fetched = time()
            r.entries = _parse_bibtex_entries(r.text)
            r.status, r.message = :ok, ""
            _bib_save_cached(r)
        elseif s == 401 || 300 <= s < 400
            r.status = :signin
            r.message = isempty(token) ? "Needs an API token" : "The API token was refused"
        elseif s == 403
            r.status, r.message = :denied, "The API token lacks the read permission"
        else
            r.status, r.message = :error, "HTTP $s"
        end
    catch e
        r.status, r.message = :error, first(split(sprint(showerror, e), '\n'))
    finally
        r.fetching = false
    end
    if (r.status, r.message, r.etag) != before
        for w in r.waiters
            nb = w.value
            nb === nothing || try; _agent_push!(nb); catch; end
        end
    end
    return r
end

"Save (empty: remove) the API token for a bibliography address's host, and fetch it again."
function bib_token_set!(url::AbstractString, token::AbstractString)
    publish_secret_set!(bib_token_ref(url), token)
    return bib_remote(url; refresh = true)
end

# The raw BibTeX of each entry, by key: for an export that carries only the entries it cites.
function _bibtex_raw_entries(text::AbstractString)
    out = Dict{String,String}()
    for part in split(String(text), r"(?=@\w+\s*\{)")
        m = match(r"^@\w+\s*\{\s*([^,\s]+)", part)
        m === nothing || (out[String(m.captures[1])] = rstrip(part))
    end
    return out
end

"""
    bib_key_matches(entries, q, n) -> Vector

The entries whose key, author or title contains `q` (ignoring case), at most `n`: those whose key
starts with it first, then those whose key contains it, then the rest, each group by key.
"""
function bib_key_matches(entries, q::AbstractString, n::Integer)
    q = lowercase(strip(q))
    rank(e) = (k = lowercase(e.key); startswith(k, q) ? 0 : occursin(q, k) ? 1 :
               (occursin(q, lowercase(e.author)) || occursin(q, lowercase(e.title))) ? 2 : 3)
    hits = [(rank(e), e) for e in entries]
    filter!(h -> h[1] < 3, hits)
    sort!(hits; by = h -> (h[1], h[2].key))
    return [h[2] for h in Iterators.take(hits, n)]
end
