# A bibliography a `:bibliography` cell names by its address: a knowledge base's site (its `api/bib`)
# or a `.bib` URL. The hub fetches it with what it holds for that host: a sign-in by OAuth, for a site
# that offers one (see "Signing in" below), else an API token pasted on the references card. It keeps
# the last copy on disk and revalidates that copy with its ETag. A notebook never waits for the
# network: it uses the copy it has, and is redrawn when a fetch brings a new one.

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
    oauth::Bool                       # its site signs in by OAuth (see `bib_oauth_metadata`)
    const waiters::Vector{WeakRef}    # notebooks to redraw when it changes
end

const _BIB_REMOTES = Dict{String,BibRemote}()
const _BIB_REMOTE_LOCK = ReentrantLock()
const BIB_RECHECK_SECONDS = Ref(300.0)
# Replaced in tests: `(url, headers) -> HTTP.Response` and `(url, headers, body) -> HTTP.Response`.
const _BIB_GET = Ref{Any}((url, headers) -> HTTP.get(url, headers; status_exception = false, redirect = false,
                                                     retry = false, connect_timeout = 10, readtimeout = 60))
const _BIB_POST = Ref{Any}((url, headers, body) -> HTTP.post(url, headers, body; status_exception = false, redirect = false,
                                                             retry = false, connect_timeout = 10, readtimeout = 60))

_bib_cache_file(url, ext) = joinpath(SlateHome.cache_home(), "bib", bytes2hex(SHA.sha1(url))[1:20] * ext)

function _bib_load_cached(url::AbstractString)
    r = BibRemote(url, "", "", 0.0, 0.0, :pending, "", _BibEntry[], false, false, WeakRef[])
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
    before = (r.status, r.message, r.etag, r.oauth)
    try
        token = bib_access_token(r.url)
        ask(token) = (h = ["Accept" => "text/plain"];
                      isempty(token) || push!(h, "Authorization" => "Bearer " * token);
                      (isempty(r.etag) || isempty(r.text)) || push!(h, "If-None-Match" => r.etag);
                      _BIB_GET[](r.url, h))
        resp = ask(token)
        # A signed-in token refused (revoked, or past its hour): renewed once, and asked again.
        if resp.status == 401 && _bib_oauth_saved(r.url) !== nothing
            token = bib_access_token(r.url; renew = true)
            isempty(token) || (resp = ask(token))
        end
        s = resp.status
        s == 401 && (r.oauth = bib_oauth_metadata(r.url) !== nothing)
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
            r.message = r.oauth ? (isempty(token) ? "Not signed in" : "Signed out: sign in again") :
                        isempty(token) ? "Needs an API token" : "The API token was refused"
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
    if (r.status, r.message, r.etag, r.oauth) != before
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

# ── Signing in ────────────────────────────────────────────────────────────────────────────────────
# A knowledge base that answers OAuth's discovery (a Zemi site, personal or a group's) is signed in to
# rather than given a pasted token. The hub registers itself there as a client, the person approves it
# in their browser, and the site sends the browser back to the hub's callback with a code, which the
# hub exchanges for an access token (short-lived) and a refresh token. They are kept with the hub's
# secrets under `bib-oauth:<host>`, never in the notebook.

"The secret ref holding a sign-in by OAuth for a bibliography address's host (see `bib_token_ref`)."
bib_oauth_ref(url::AbstractString) = "bib-oauth:" * chop(bib_token_ref(url); head = 4, tail = 0)

"The site of a bibliography address: its scheme and host."
_bib_origin(url::AbstractString) = (m = match(r"^https?://[^/?#]+"i, url); m === nothing ? "" : String(m.match))

"""
    bib_oauth_metadata(url) -> Union{Dict,Nothing}

What the site of `url` says of signing in to it (RFC 8414), when it offers a token to read with
(scope `read`); `nothing` for a site that does not, which is given a token instead.
"""
function bib_oauth_metadata(url::AbstractString)
    origin = _bib_origin(url)
    isempty(origin) && return nothing
    resp = try _BIB_GET[](origin * "/.well-known/oauth-authorization-server", ["Accept" => "application/json"]) catch; return nothing end
    resp.status == 200 || return nothing
    meta = try JSON.parse(String(resp.body)) catch; return nothing end
    meta isa AbstractDict && "read" in get(meta, "scopes_supported", String[]) && haskey(meta, "token_endpoint") || return nothing
    return meta
end

_bib_oauth_saved(url) = (v = get(_secrets_or_empty(), bib_oauth_ref(url), ""); isempty(v) ? nothing : try JSON.parse(v) catch; nothing end)
_bib_oauth_save!(url, d) = publish_secret_set!(bib_oauth_ref(url), d === nothing ? "" : JSON.json(d))
_b64url(bytes) = rstrip(replace(Base64.base64encode(bytes), '+' => '-', '/' => '_'), '=')
_form(pairs) = HTTP.escapeuri(pairs)

# The sign-ins under way, by their `state`: what the callback needs to finish one. Each is good for
# ten minutes, and once.
const _BIB_SIGNINS = Dict{String,Any}()
const _BIB_SIGNIN_LOCK = ReentrantLock()
const _BIB_SIGNIN_SECONDS = 600.0

"""
    bib_signin_start(url, redirect; scope = "read") -> String

Begin signing in to the site of bibliography address `url`: the address of its approval page for the
person's browser. `redirect` is the hub's callback as that browser reaches it (see
`bib_signin_finish`). The hub registers itself there once per callback address. `scope` is what the
token may do there: reading, or more for writing a notebook together (see collab.jl).
"""
function bib_signin_start(url::AbstractString, redirect::AbstractString; scope::AbstractString = "read")
    meta = bib_oauth_metadata(url)
    meta === nothing && error("$(_bib_origin(url)) does not offer signing in")
    saved = something(_bib_oauth_saved(url), Dict{String,Any}())
    client = get(saved, "redirect", "") == redirect ? String(get(saved, "client_id", "")) : ""
    if isempty(client)
        resp = _BIB_POST[](String(meta["registration_endpoint"]), ["Content-Type" => "application/json"],
                           JSON.json(Dict("client_name" => "Kaimon Slate", "redirect_uris" => [redirect])))
        resp.status in (200, 201) || error("$(_bib_origin(url)) refused to register the hub: HTTP $(resp.status)")
        client = String(JSON.parse(String(resp.body))["client_id"])
    end
    verifier, state = _b64url(rand(UInt8, 32)), bytes2hex(rand(UInt8, 16))
    lock(_BIB_SIGNIN_LOCK) do
        filter!(kv -> time() - kv[2].at < _BIB_SIGNIN_SECONDS, _BIB_SIGNINS)
        _BIB_SIGNINS[state] = (; url = String(url), verifier, client, redirect = String(redirect),
                                 token_endpoint = String(meta["token_endpoint"]), at = time())
    end
    q = _form(["response_type" => "code", "client_id" => client, "redirect_uri" => redirect, "state" => state, "scope" => scope,
               "code_challenge" => _b64url(SHA.sha256(verifier)), "code_challenge_method" => "S256"])
    return String(meta["authorization_endpoint"]) * "?" * q
end

"""
    bib_signin_finish(state, code) -> String

The site sent the person's browser back with `code` for the sign-in `state`: exchange it for tokens,
keep them, and fetch the bibliography with them. Returns the bibliography address signed in to.
"""
function bib_signin_finish(state::AbstractString, code::AbstractString)
    s = lock(() -> pop!(_BIB_SIGNINS, String(state), nothing), _BIB_SIGNIN_LOCK)
    (s === nothing || time() - s.at > _BIB_SIGNIN_SECONDS) && error("This sign-in is unknown or has expired: sign in again from the notebook")
    resp = _BIB_POST[](s.token_endpoint, ["Content-Type" => "application/x-www-form-urlencoded"],
                       _form(["grant_type" => "authorization_code", "code" => code, "client_id" => s.client,
                              "redirect_uri" => s.redirect, "code_verifier" => s.verifier]))
    resp.status == 200 || error("The site refused the sign-in: HTTP $(resp.status)")
    _bib_keep_tokens!(s.url, JSON.parse(String(resp.body)); client = s.client, redirect = s.redirect, token_endpoint = s.token_endpoint)
    bib_remote(s.url; refresh = true)
    return s.url
end

function _bib_keep_tokens!(url, t; client, redirect, token_endpoint)
    _bib_oauth_save!(url, Dict("access" => t["access_token"], "refresh" => get(t, "refresh_token", ""),
                               "expires" => time() + Float64(get(t, "expires_in", 3600)), "client_id" => client,
                               "redirect" => redirect, "token_endpoint" => token_endpoint))
end

"""
    bib_access_token(url; renew = false) -> String

The token to fetch bibliography address `url` with: a signed-in one, renewed with its refresh token
when it is about to expire (or `renew`), else a pasted one, else "". A sign-in the site no longer
renews is forgotten, and the card asks to sign in again.
"""
function bib_access_token(url::AbstractString; renew::Bool = false)
    saved = _bib_oauth_saved(url)
    saved === nothing && return String(get(_secrets_or_empty(), bib_token_ref(url), ""))
    (renew || Float64(get(saved, "expires", 0)) < time() + 60) || return String(saved["access"])
    resp = try
        _BIB_POST[](String(saved["token_endpoint"]), ["Content-Type" => "application/x-www-form-urlencoded"],
                    _form(["grant_type" => "refresh_token", "refresh_token" => String(get(saved, "refresh", "")),
                           "client_id" => String(saved["client_id"])]))
    catch
        return String(saved["access"])            # the site is away: the token it has, for now
    end
    if resp.status != 200
        _bib_oauth_save!(url, nothing)
        return ""
    end
    _bib_keep_tokens!(url, JSON.parse(String(resp.body)); client = saved["client_id"], redirect = saved["redirect"],
                      token_endpoint = saved["token_endpoint"])
    return String(_bib_oauth_saved(url)["access"])
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
