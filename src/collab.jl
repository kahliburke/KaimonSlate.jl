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
ws, room, name, expires, rooms)`, `ws` the WebSocket to open, `name` the person's as the knowledge
base knows them, and `rooms` the project's rooms with someone in them; or `(; ok = false, status, signin, error)`, `signin` when signing in there would help.
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
    return (; ok = true, ws, room = String(t["room"]), name = String(get(t, "name", "")), expires = String(get(t, "expires", "")),
            rooms = get(t, "rooms", Any[]))
end

# ── The room's changes, applied here ─────────────────────────────────────────────────────────────
# What the others in the room changed in the notebook reaches this hub as operations on its cells.
# None runs anything: another person's code runs on this machine only when its owner runs it. A cell
# that gains or loses inputs is marked stale, as an edit marks it.

"""
    collab_apply!(nb, ops) -> Int

Apply the room's operations to notebook `nb` without running any cell: `insert` (`id`, `kind`,
`source`, `tags`, after the cell `after`, first when empty), `delete` (`id`), `move` (`id` to after
`after`), `kind` (`id`, `kind`), `tags` (`id`, `tags`) and `source` (`id`, `source`). One undo step
for the structural ones. Returns how many applied.
"""
function collab_apply!(nb, ops)
    applied = 0
    structural = any(op -> get(op, "op", "") in ("insert", "delete", "move"), ops)
    lock(nb.lock) do
        cells = nb.report.cells
        structural && _snapshot!(nb; label = "from the room")
        old = Dict{String,Set{String}}(c.id => copy(c.deps) for c in cells)
        place(after) = isempty(after) ? 1 : something(_index_of(cells, after), length(cells)) + 1
        for op in ops
            kind, id = String(get(op, "op", "")), String(get(op, "id", ""))
            i = _index_of(cells, id)
            if kind == "insert"
                (i === nothing && !isempty(id)) || continue
                c = Cell(id, _cellkind(String(get(op, "kind", "code"))), String(get(op, "source", "")))
                tags = get(op, "tags", nothing)
                tags isa AbstractVector && union!(c.flags, setdiff(_parse_tag_symbols(tags), ReportEngine._INTERNAL_FLAGS))
                insert!(cells, place(String(get(op, "after", ""))), c)
            elseif kind == "delete"
                i === nothing && continue
                _preempt_superseded!(nb, (cells[i],))
                deleteat!(cells, i)
            elseif kind == "move"
                i === nothing && continue
                c = cells[i]
                deleteat!(cells, i)
                insert!(cells, place(String(get(op, "after", ""))), c)
            elseif kind == "kind"
                i === nothing && continue
                set_kind!(nb, id, String(get(op, "kind", "code")))
            elseif kind == "tags"
                (i === nothing || !(get(op, "tags", nothing) isa AbstractVector)) && continue
                set_cell_tags!(nb, id, op["tags"])
            elseif kind == "source"
                i === nothing && continue
                replace_cells!(nb, Dict(id => String(get(op, "source", ""))); label = "from the room")
            else
                continue
            end
            applied += 1
        end
        if structural
            build_dependencies!(nb.report)
            changed = Set{String}(c.id for c in cells if get(old, c.id, nothing) != c.deps)
            restale = isempty(changed) ? Set{String}() : dependents_of(nb.report, changed)
            for c in cells
                c.id in restale && ReportEngine.restale!(c)
            end
            _persist!(nb; label = "from the room")
        end
    end
    return applied
end

"A markdown cell's text as it would render, its `{{ }}` values as last run, without committing it: for watching another type."
collab_render(nb, id::AbstractString, source::AbstractString) =
    (c = (i = _index_of(nb.report.cells, id)) === nothing ? nothing : nb.report.cells[i];
     markdown_html(source, c === nothing ? CellOutput[] : c.interp))
