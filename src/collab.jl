# Writing a notebook together through a knowledge base (see assets/js/collab.js). The browsers of the
# people editing it meet in the notebook's room there: a project's, named by the notebook's `docid`. The
# page asks its hub for a ticket to the room, and the hub asks the knowledge base with what it holds for
# that site (a sign-in or a token, see bib_remote.jl), so no key reaches the page. A ticket is the
# page's alone to use: it opens the room's WebSocket, and nothing else.

"The scope a sign-in for writing together asks for: reading, and contributing to the projects' work."
const COLLAB_SCOPE = "read tasks.view tasks.edit"

"""
    collab_ticket(nb, kb, project) -> NamedTuple

A ticket to notebook `nb`'s room in `project` at knowledge base `kb` (its address): `(; ok = true,
ws, room, name, expires)`, `ws` the WebSocket to open and `name` the person's, as the knowledge base
knows them; or `(; ok = false, status, signin, error)`, `signin` when signing in there would help.
"""
function collab_ticket(nb, kb::AbstractString, project::AbstractString)
    origin = _bib_origin(String(strip(kb)))
    isempty(origin) && return (; ok = false, status = 400, signin = false, error = "A knowledge base's address starts with http:// or https://")
    key = uppercase(strip(project))
    occursin(r"^[A-Z][A-Z0-9]{0,15}$", key) || return (; ok = false, status = 400, signin = false, error = "A project's key is letters and digits")
    body = JSON.json(Dict("document" => _ensure_docid!(nb)))
    url = origin * "/api/projects/" * key * "/collab/ticket"
    ask(token) = _BIB_POST[](url, ["Content-Type" => "application/json", "Accept" => "application/json",
                                   (isempty(token) ? Pair{String,String}[] : ["Authorization" => "Bearer " * token])...], body)
    resp = try
        r = ask(bib_access_token(origin))
        # A signed-in token refused (past its hour, say): renewed once, and asked again.
        if r.status == 401 && _bib_oauth_saved(origin) !== nothing
            token = bib_access_token(origin; renew = true)
            isempty(token) || (r = ask(token))
        end
        r
    catch e
        return (; ok = false, status = 502, signin = false, error = "$(origin) did not answer: " * first(split(sprint(showerror, e), '\n')))
    end
    if resp.status != 200
        said = try String(get(JSON.parse(String(resp.body)), "error", "")) catch; "" end
        signin = resp.status in (401, 403) && bib_oauth_metadata(origin) !== nothing
        return (; ok = false, status = Int(resp.status), signin,
                error = isempty(said) ? "$(origin) refused the ticket: HTTP $(resp.status)" : said)
    end
    t = JSON.parse(String(resp.body))
    ws = replace(origin, r"^http"i => "ws") * String(t["path"]) * "?ticket=" * String(t["ticket"])
    return (; ok = true, ws, room = String(t["room"]), name = String(get(t, "name", "")), expires = String(get(t, "expires", "")))
end
