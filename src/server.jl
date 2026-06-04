"""
    NotebookServer

The live, interactive notebook backend (interactivity layer 1). Holds a notebook
bound to a `.jl` file and serves a browser SPA plus a small JSON API. Editing a
cell reconciles → reactively recomputes only stale cells → persists back to the
`.jl` (so the agent and the browser share one source). Runs CLI-side, wrapping
the engine (`ReportEngine`) and per-cell renderer (`ReportRender`).
"""
module NotebookServer

using HTTP, JSON, FileWatching
import REPL
using ..ReportEngine
using ..ReportRender

export serve_notebook, start_server, stop_server, LiveNotebook
export Hub, start_hub, open_notebook!, close_notebook!, stop_hub

const _ASSET = joinpath(@__DIR__, "assets", "notebook.html")

mutable struct LiveNotebook
    id::String                           # hub id (unique; used in /n/<id> + /api/<id>/…)
    path::String
    report::Report
    kernel::Kernel                       # where cells eval (in-process or per-notebook gate worker)
    version::Int                         # bumps on external (file) changes
    undo::Vector{String}                 # source snapshots (most recent last)
    redo::Vector{String}
    lock::ReentrantLock                  # serializes eval (UI actions vs. async refresh)
    listeners::Vector{Channel{String}}   # this notebook's live SSE connections
    llock::ReentrantLock                 # protects `listeners`
end

# GateKernel when running as the Kaimon extension AND the notebook is inside a
# Julia project (cells eval in a per-notebook worker); else in-process.
function _select_kernel(path::AbstractString)
    if ReportEngine.gate_available()
        proj = Base.current_project(dirname(abspath(path)))
        proj === nothing ?
            (@warn "KaimonSlate: no enclosing project for $path — using in-process kernel") :
            return GateKernel(dirname(proj))
    end
    return InProcessKernel()
end

function load_notebook(path::AbstractString; id::AbstractString = "")
    src = read(path, String)
    base = splitext(basename(path))[1]
    rid = replace(base, r"[^A-Za-z0-9]" => "_")
    nbid = isempty(id) ? rid : String(id)
    r = parse_report(src; id = rid, title = base)
    build_dependencies!(r)
    kernel = _select_kernel(path)
    eval_stale!(r, kernel)               # initial full run
    nb = LiveNotebook(nbid, String(path), r, kernel, 0, String[], String[],
                      ReentrantLock(), Channel{String}[], ReentrantLock())
    # Async cells call `slate_refresh(:x)` → recompute readers of x + push live.
    register_refresh!(r.id, vars -> server_refresh(nb, vars))
    return nb
end

# Reactive push triggered by a cell's async task (`slate_refresh(:data, …)`):
# restale the cells that READ those vars (but not the producers that WRITE them,
# so we don't re-trigger the task), recompute, and push a lightweight live update.
function server_refresh(nb::LiveNotebook, vars)
    syms = Set{Symbol}(vars)
    lock(nb.lock) do
        seed = String[]
        for c in nb.report.cells
            c.kind == CODE || continue
            (!isdisjoint(c.reads, syms) && isdisjoint(c.writes, syms)) || continue
            c.state = STALE
            push!(seed, c.id)
        end
        isempty(seed) && return
        for id in dependents_of(nb.report, Set(seed))
            i = _index_of(nb.report.cells, id)
            i === nothing || (nb.report.cells[i].state = STALE)
        end
        eval_stale!(nb.report, nb.kernel)
    end
    _broadcast(nb, "refresh")
    return nothing
end

# Undo/redo over source snapshots. Call _snapshot! *before* a mutating op.
function _snapshot!(nb::LiveNotebook)
    push!(nb.undo, serialize_report(nb.report))
    length(nb.undo) > 100 && popfirst!(nb.undo)
    empty!(nb.redo)
end

function _restore!(nb::LiveNotebook, src::AbstractString)
    update_source!(nb.report, src)
    eval_stale!(nb.report, nb.kernel)
    write(nb.path, serialize_report(nb.report))
end

function undo!(nb::LiveNotebook)
    isempty(nb.undo) && return nb
    push!(nb.redo, serialize_report(nb.report))
    _restore!(nb, pop!(nb.undo))
    return nb
end

function redo!(nb::LiveNotebook)
    isempty(nb.redo) && return nb
    push!(nb.undo, serialize_report(nb.report))
    _restore!(nb, pop!(nb.redo))
    return nb
end

# Pull in external edits (VS Code, the agent, …). Re-reads the file; if it differs
# (canonically) from our state, reconciles → runs stale → bumps version. Returns
# true if changed. The server's own writes match canonically, so they don't loop.
function sync_from_file!(nb::LiveNotebook)
    isfile(nb.path) || return false
    disk = read(nb.path, String)
    norm = try
        serialize_report(parse_report(disk; id = nb.report.id))
    catch
        return false                     # mid-save / unparseable — skip this tick
    end
    norm == serialize_report(nb.report) && return false
    update_source!(nb.report, disk)
    eval_stale!(nb.report, nb.kernel)
    nb.version += 1
    return true
end

_echarts_specs(c::Cell) = c.output === nothing ? Any[] : c.output.echarts
_table_specs(c::Cell) = c.output === nothing ? Any[] : c.output.tables

# A bound control resolved for the frontend: enough to render the widget *and*
# POST value changes to `/api/bind/<id>` (the *defining* cell's id) keyed by
# variable name, regardless of which cell surfaces it.
_control_spec(cell::Cell, spec::BindSpec) =
    Dict{String,Any}("id" => cell.id, "name" => String(spec.name),
                     "widget" => spec.widget, "params" => spec.params, "value" => spec.value)

_bind_json(spec::BindSpec, hosted::Bool) =
    Dict{String,Any}("name" => String(spec.name), "widget" => spec.widget,
                     "params" => spec.params, "value" => spec.value, "hosted" => hosted)

# `bindref`: var-name → (defining cell, its BindSpec). `hostednames`: variable
# names surfaced via some cell's `controls=` (so each collapses to a chip).
function cell_json(c::Cell, bindref::Dict{String,Tuple{Cell,BindSpec}} = Dict{String,Tuple{Cell,BindSpec}}(),
                   hostednames::Set{String} = Set{String}())
    d = Dict{String,Any}(
        "id"      => c.id,
        "kind"    => c.kind == MARKDOWN ? "md" : "code",
        "source"  => c.source,
        "state"   => lowercase(string(c.state)),
        "output"  => c.kind == MARKDOWN ? markdown_html(c.source) : output_html(c),
        "echarts" => c.kind == MARKDOWN ? String[] : _echarts_specs(c),
        "tables" => c.kind == MARKDOWN ? Any[] : _table_specs(c),
        "duration" => c.output === nothing ? nothing : round(c.output.duration_ms; digits = 1),
        "deps"    => collect(c.deps),
    )
    if !isempty(c.controls)
        # resolve each column's names to (defining cell, spec); drop unknown names + empty columns
        cols = [[_control_spec(bindref[n]...) for n in col if haskey(bindref, n)] for col in c.controls]
        cols = filter(!isempty, cols)
        isempty(cols) || (d["controls"] = cols)
    end
    if !isempty(c.binds)
        d["binds"] = [_bind_json(b, String(b.name) in hostednames) for b in c.binds]
    end
    return d
end

# Set widget `name` (defined by cell `id`) → recompute its dependents (the
# reactive heart of @bind). A group cell's blast radius is by cell id, which is
# conservative (touches readers of any of its vars) but never under-invalidates.
function set_bind!(nb::LiveNotebook, id::AbstractString, name::AbstractString, value)
    idx = findfirst(c -> c.id == id, nb.report.cells)
    idx === nothing && return nb
    cell = nb.report.cells[idx]
    isempty(cell.binds) && return nb
    lock(nb.lock) do
        set_bind_value!(nb.report, cell, Symbol(name), value, nb.kernel)
        for did in dependents_of(nb.report, Set([id]))
            did == id && continue
            j = findfirst(c -> c.id == did, nb.report.cells)
            j === nothing || (nb.report.cells[j].state = STALE)
        end
        eval_stale!(nb.report, nb.kernel)
    end
    return nb
end

# Index every bound variable by name → (defining cell, spec), and the set of
# variable names surfaced in some cell's control strip.
function _bind_index(report::Report)
    bindref = Dict{String,Tuple{Cell,BindSpec}}()
    for c in report.cells, b in c.binds
        bindref[String(b.name)] = (c, b)
    end
    hostednames = Set{String}()
    for c in report.cells, col in c.controls, n in col
        haskey(bindref, n) && push!(hostednames, n)
    end
    return bindref, hostednames
end

function state_json(nb::LiveNotebook)
    bindref, hostednames = _bind_index(nb.report)
    return Dict("id"      => nb.id,
                "title"   => nb.report.title,
                "path"    => abspath(nb.path),
                "version" => nb.version,
                "cells"   => [cell_json(c, bindref, hostednames) for c in nb.report.cells])
end

# Edit a cell's source → reconcile (mark it + dependents stale) → run stale →
# persist back to the `.jl`.
function edit_cell!(nb::LiveNotebook, id::AbstractString, source::AbstractString)
    cells = nb.report.cells
    idx = findfirst(c -> c.id == id, cells)
    idx === nothing && return nb
    cells[idx].source == String(source) || _snapshot!(nb)
    # Build the new full source with this cell swapped, WITHOUT disturbing report
    # state first — otherwise update_source! compares the new source to itself,
    # sees "unchanged", and never marks the cell stale (so it never re-runs).
    saved = cells[idx].source
    cells[idx].source = String(source)
    new_full = serialize_report(nb.report)
    cells[idx].source = saved
    update_source!(nb.report, new_full)
    eval_stale!(nb.report, nb.kernel)
    write(nb.path, serialize_report(nb.report))
    return nb
end

# ── Structural ops (add / delete / move / change type) ───────────────────────

function _gen_id(report::Report)
    existing = Set(c.id for c in report.cells)
    while true
        id = string(hash(time_ns()) % 0xffffff; base = 16, pad = 6)
        id in existing || return id
    end
end

# A structural change at index `idx` reorders state, so conservatively restale
# everything from there on, recompute, and persist.
function _commit_structure!(nb::LiveNotebook, idx::Int)
    build_dependencies!(nb.report)
    for (i, c) in enumerate(nb.report.cells)
        i >= idx && (c.state = STALE)
    end
    eval_stale!(nb.report, nb.kernel)
    write(nb.path, serialize_report(nb.report))
    return nb
end

_index_of(cells, id) = findfirst(c -> c.id == id, cells)

function add_cell!(nb::LiveNotebook, after_id::AbstractString, kind::AbstractString)
    _snapshot!(nb)
    cells = nb.report.cells
    i = isempty(after_id) ? length(cells) : something(_index_of(cells, after_id), length(cells))
    cell = Cell(_gen_id(nb.report), kind == "md" ? MARKDOWN : CODE, "")
    insert!(cells, i + 1, cell)
    _commit_structure!(nb, i + 1)
    return cell.id
end

function delete_cell!(nb::LiveNotebook, id::AbstractString)
    i = _index_of(nb.report.cells, id); i === nothing && return nb
    _snapshot!(nb)
    deleteat!(nb.report.cells, i)
    _commit_structure!(nb, max(1, i))
end

function move_cell!(nb::LiveNotebook, id::AbstractString, dir::AbstractString)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    j = dir == "up" ? i - 1 : i + 1
    (j < 1 || j > length(cells)) && return nb
    _snapshot!(nb)
    cells[i], cells[j] = cells[j], cells[i]
    _commit_structure!(nb, min(i, j))
end

# Move `id` to just before/after `target_id` (drag-and-drop).
function move_cell_rel!(nb::LiveNotebook, id::AbstractString, target_id::AbstractString, before::Bool)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    _snapshot!(nb)
    c = cells[i]; deleteat!(cells, i)
    j = _index_of(cells, target_id)
    p = j === nothing ? length(cells) + 1 : (before ? j : j + 1)
    insert!(cells, p, c)
    _commit_structure!(nb, min(i, p))
end

# Set the `controls=` layout of one or more cells (drag-to-host: add / move /
# reorder / remove / re-column). Presentation only — no re-eval; just rewrite the
# `.jl`. The caller sends each affected cell's *full desired* layout as columns of
# names (`[[a,b],[c]]`); empty columns are dropped.
function set_controls_map!(nb::LiveNotebook, map)
    isempty(map) && return nb
    _snapshot!(nb)
    for (id, cols) in map
        i = _index_of(nb.report.cells, id); i === nothing && continue
        cleaned = Vector{String}[String[String(n) for n in col] for col in cols]
        nb.report.cells[i].controls = filter(!isempty, cleaned)
    end
    write(nb.path, serialize_report(nb.report))
    return nb
end

function set_kind!(nb::LiveNotebook, id::AbstractString, kind::AbstractString)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    _snapshot!(nb)
    old = cells[i]
    cells[i] = Cell(old.id, kind == "md" ? MARKDOWN : CODE, old.source)
    _commit_structure!(nb, i)
end

_json(x) = HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(x))

# HTTP 2.0: request body is a BytesBody wrapper; read it as a String.
function _body(req)
    s = String(req.body)
    return isempty(s) ? Dict{String,Any}() : JSON.parse(s)
end

# ── Live push over SSE (per notebook) ────────────────────────────────────────
function _broadcast(nb::LiveNotebook, msg::AbstractString)
    lock(nb.llock) do
        for ch in nb.listeners
            try
                isopen(ch) && Base.n_avail(ch) < 32 && put!(ch, String(msg))
            catch
            end
        end
    end
end

# Close this notebook's live SSE channels so each `_sse` loop's `take!` throws and
# returns, ending its long-lived connection. Without this, `close(server)` blocks
# waiting for those streams to drain (a browser tab left open hangs the close).
function _close_listeners(nb::LiveNotebook)
    lock(nb.llock) do
        for ch in nb.listeners
            try; close(ch); catch; end
        end
        empty!(nb.listeners)
    end
end

# One SSE connection over a raw `HTTP.Stream` (HTTP 2.0's documented streaming
# pattern — `listen!` + a `Stream` handler). Registers a channel, streams the
# current version on connect, then `data: <version>` on each change and `: hb`
# comment-line heartbeats (which the browser ignores) so a dead connection
# surfaces as a failed write that ends the loop. Each `write` flushes as its own
# chunk — unlike the high-level `sse_stream`/`SSEStream`, whose chunked writer
# blocks for a full 16 KiB buffer before flushing and so can't drive a long-lived
# push connection.
function _sse(stream::HTTP.Stream, nb::LiveNotebook)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    ch = Channel{String}(32)
    lock(nb.llock) do; push!(nb.listeners, ch); end
    try
        write(stream, "data: $(nb.version)\n\n")
        while true
            msg = take!(ch)
            write(stream, msg == "hb" ? ": hb\n\n" : "data: $msg\n\n")
        end
    catch
    finally
        lock(nb.llock) do; filter!(c -> c !== ch, nb.listeners); end
        close(ch)
    end
    return nothing
end

# Watch the file for external edits (VS Code / agent) → sync → push instantly.
# `watch_file` returns on change (instant) or after a 2s safety timeout (covers
# editors that save via atomic rename). Server's own writes match canonically in
# `sync_from_file!`, so they don't echo back.
function _start_watcher!(nb::LiveNotebook)
    @async while true
        try
            FileWatching.watch_file(nb.path, 2.0)
            sync_from_file!(nb) && _broadcast(nb, string(nb.version))
        catch
            sleep(0.5)
        end
    end
    @async while true
        sleep(15)
        _broadcast(nb, "hb")
    end
end

# ── Hub: one server, one port, many notebooks ────────────────────────────────
#
# Notebooks live in a registry keyed by a unique hub `id`. Routes are
# notebook-scoped (`/n/<id>` SPA, `/api/<id>/…`, `/api/<id>/events` SSE); `/` is
# an index/switcher page. One HTTP 2.0 server replaces the old one-port-per-file.
mutable struct Hub
    notebooks::Dict{String,LiveNotebook}
    server::Any
    host::String
    port::Int
    lock::ReentrantLock
end

_hub_url(h::Hub) = "http://$(h.host):$(h.port)"
_esc(s) = replace(String(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

# A unique id from the filename (deduped against the registry).
function _unique_id(h::Hub, path::AbstractString)
    base = replace(splitext(basename(path))[1], r"[^A-Za-z0-9]" => "_")
    isempty(base) && (base = "nb")
    id = base; i = 1
    while haskey(h.notebooks, id); i += 1; id = "$(base)_$i"; end
    return id
end

_notebooks_json(h::Hub) = lock(h.lock) do
    [Dict("id" => nb.id, "title" => nb.report.title, "path" => abspath(nb.path),
          "cells" => length(nb.report.cells)) for nb in values(h.notebooks)]
end

# The index / switcher page: a Pluto-style list of open notebooks.
function _index_html(h::Hub)
    rows = lock(h.lock) do
        isempty(h.notebooks) ?
            "<p class=\"empty\">No notebooks open. Open one with the <code>slate.open</code> tool.</p>" :
            join(("<a class=\"nb\" href=\"/n/$(nb.id)\"><span class=\"t\">$(_esc(nb.report.title))</span>" *
                  "<span class=\"p\">$(_esc(abspath(nb.path)))</span>" *
                  "<span class=\"c\">$(length(nb.report.cells)) cells</span></a>"
                  for nb in values(h.notebooks)))
    end
    return """<!DOCTYPE html><html><head><meta charset="UTF-8"/><title>Kaimon Slate</title>
    <style>body{background:#0d1120;color:#d4d8e8;font-family:system-ui,sans-serif;margin:0;padding:40px;}
    h1{color:#fff;font-size:1.3rem;} .empty{color:#6a7090;}
    .nb{display:flex;flex-direction:column;gap:2px;padding:12px 16px;margin:8px 0;background:#141828;
        border:1px solid #2a2e40;border-left:3px solid #569cd6;border-radius:8px;text-decoration:none;color:inherit;max-width:760px;}
    .nb:hover{border-color:#569cd6;} .nb .t{color:#fff;font-weight:600;} .nb .p{color:#6a7090;font-family:monospace;font-size:.8rem;}
    .nb .c{color:#56d364;font-size:.75rem;}
    .open{display:flex;gap:8px;margin:8px 0 18px;max-width:760px;}
    .pathwrap{position:relative;flex:1;}
    .pathwrap input{width:100%;background:#141828;color:#d4d8e8;border:1px solid #2a2e40;border-radius:8px;padding:8px 12px;font-family:monospace;font-size:.85rem;}
    .pathwrap input:focus{outline:none;border-color:#569cd6;}
    .comp{position:absolute;top:calc(100% + 3px);left:0;right:0;z-index:5;list-style:none;margin:0;padding:4px;
      background:#141828;border:1px solid #2a2e40;border-radius:8px;max-height:300px;overflow:auto;display:none;box-shadow:0 8px 24px rgba(0,0,0,.4);}
    .comp li{padding:4px 10px;border-radius:5px;cursor:pointer;font-family:monospace;font-size:.82rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
    .comp li.on{background:#569cd6;color:#0d1120;} .comp li:hover{background:#1a1e2e;}
    .open button{background:#141828;color:#d4d8e8;border:1px solid #2a2e40;border-radius:8px;padding:8px 16px;cursor:pointer;}
    .open button:hover{border-color:#569cd6;color:#569cd6;}</style></head>
    <body><h1>📓 Kaimon Slate — notebooks</h1>
    <div class="open">
      <div class="pathwrap">
        <input id="pathin" autocomplete="off" spellcheck="false"
               placeholder="~/path/to/notebook.jl — Tab to complete, Enter to open"/>
        <ul id="comp" class="comp"></ul>
      </div>
      <button id="openbtn">Open</button>
    </div>
    <script>
    (function(){
      var inp=document.getElementById('pathin'), comp=document.getElementById('comp'), items=[], sel=-1;
      var esc=function(s){return s.replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});};
      function openPath(p){p=(p||'').trim();if(!p)return;
        fetch('/api/open',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:p})})
          .then(function(r){return r.ok?r.json():r.text().then(function(t){return Promise.reject(t);});})
          .then(function(d){location.href=d.url;}).catch(function(e){alert('Open failed: '+e);});}
      function render(){comp.innerHTML=items.map(function(c,i){return '<li class="'+(i===sel?'on':'')+'" data-i="'+i+'">'+esc(c)+'</li>';}).join('');
        comp.style.display=items.length?'block':'none';}
      function fetchComp(){fetch('/api/path-complete?q='+encodeURIComponent(inp.value))
        .then(function(r){return r.json();}).then(function(d){items=d.completions||[];sel=items.length?0:-1;render();});}
      function commonPrefix(a){if(!a.length)return '';var p=a[0];for(var k=0;k<a.length;k++){var s=a[k],i=0;
        while(i<p.length&&i<s.length&&p[i]===s[i])i++;p=p.slice(0,i);}return p;}
      var t;inp.addEventListener('input',function(){clearTimeout(t);t=setTimeout(fetchComp,110);});
      inp.addEventListener('keydown',function(e){
        if(e.key==='Tab'){e.preventDefault();
          if(items.length===1){inp.value=items[0];fetchComp();}
          else if(items.length>1){var cp=commonPrefix(items);
            if(cp.length>inp.value.length){inp.value=cp;fetchComp();}
            else{sel=(sel+1)%items.length;inp.value=items[sel];render();}}}
        else if(e.key==='ArrowDown'){e.preventDefault();if(items.length){sel=(sel+1)%items.length;inp.value=items[sel];render();}}
        else if(e.key==='ArrowUp'){e.preventDefault();if(items.length){sel=(sel-1+items.length)%items.length;inp.value=items[sel];render();}}
        else if(e.key==='Enter'){e.preventDefault();openPath(inp.value);}
        else if(e.key==='Escape'){items=[];render();}});
      comp.addEventListener('mousedown',function(e){var li=e.target.closest('li');if(!li)return;e.preventDefault();
        inp.value=items[+li.dataset.i];inp.focus();fetchComp();});
      document.getElementById('openbtn').onclick=function(){openPath(inp.value);};
      inp.focus();
    })();
    </script>
    $rows</body></html>"""
end

_html(body) = HTTP.Response(200, ["Content-Type" => "text/html", "Cache-Control" => "no-store"], body)

# Run `f(nb)` for the notebook named by the request's `id` path param, else 404.
function _withnb(h::Hub, req, f)
    id = HTTP.getparam(req, "id")
    nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
    nb === nothing && return HTTP.Response(404, "no such notebook: $id")
    return f(nb)
end

# Filesystem path completions for the open box. Expands a leading `~`, lists the
# directory implied by the typed prefix, and returns full suggestions that PRESERVE
# the user's `~` (directories suffixed `/`). Dirs and `.jl` files surface first;
# dotfiles are hidden unless the prefix itself starts with a dot.
function _path_completions(q::AbstractString; limit::Int = 40)
    s = String(q)
    isempty(s) && (s = "~/")
    s == "~" && return ["~/"]
    slash = findlast('/', s)
    prefix = slash === nothing ? "" : s[1:slash]
    leaf   = slash === nothing ? s : s[nextind(s, slash):end]
    base   = isempty(prefix) ? pwd() : expanduser(prefix)
    isdir(base) || return String[]
    entries = try
        readdir(base)
    catch
        return String[]
    end
    keep = String[]
    for e in entries
        startswith(e, leaf) || continue
        (startswith(e, ".") && !startswith(leaf, ".")) && continue
        full = joinpath(base, e)
        push!(keep, isdir(full) ? prefix * e * "/" : prefix * e)
    end
    sort!(keep; by = p -> (endswith(p, "/") ? 0 : (endswith(p, ".jl") ? 1 : 2), lowercase(p)))
    return first(keep, limit)
end

# ── Cell-local completion ─────────────────────────────────────────────────────
# `REPLCompletions` only sees the live module, so identifiers a cell BINDS before
# it has run (assignments, `for`/`let`/`function`/generator vars, params) don't
# complete. We parse the cell's complete leading statements and union their bound
# names in — an over-approximation (ignores nested-scope visibility), which is fine
# for completion. Only for bare identifiers; field access (after `.`) is left to
# REPLCompletions.
_isidcu(b::UInt8) = (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) ||
                    (UInt8('0') <= b <= UInt8('9')) || b == UInt8('_') || b == UInt8('!')

# (token-start-0based, typed-prefix, is-field-access) for the identifier at `pos`.
function _id_prefix(code::String, pos::Int)
    cu = codeunits(code)
    i = pos
    while i > 0 && _isidcu(cu[i]); i -= 1; end
    dotted = i >= 1 && cu[i] == UInt8('.')
    return (i, String(cu[(i + 1):pos]), dotted)
end

# Names introduced at a binding site (LHS of `=`, params, `f(a,b)` def, `x::T`, …).
function _bind_names!(out::Set{Symbol}, x)
    if x isa Symbol
        x === :_ || push!(out, x)
    elseif x isa Expr
        h = x.head
        if h === :(::) || h === :(<:) || h === :kw || h === :(=) || h === :(...) || h === :curly
            isempty(x.args) || _bind_names!(out, x.args[1])
        elseif h === :tuple || h === :parameters || h === :call   # destructuring / def LHS+params
            for a in x.args
                _bind_names!(out, a)
            end
        end
    end
end

function _collect_binds!(out::Set{Symbol}, ex)
    ex isa Expr || return
    h = ex.head
    if h === :(=)
        _bind_names!(out, ex.args[1]); _collect_binds!(out, ex.args[2])
    elseif h === :function || h === :(->)
        _bind_names!(out, ex.args[1])
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :for
        spec = ex.args[1]
        for b in (spec isa Expr && spec.head === :block ? spec.args : (spec,))
            b isa Expr && b.head === :(=) && _bind_names!(out, b.args[1])
        end
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :generator || h === :comprehension || h === :flatten
        for a in ex.args
            (a isa Expr && a.head === :(=)) ? _bind_names!(out, a.args[1]) : _collect_binds!(out, a)
        end
    elseif h === :let
        binds = ex.args[1]
        for b in (binds isa Expr && binds.head === :block ? binds.args : (binds,))
            b isa Symbol ? push!(out, b) : (b isa Expr && b.head === :(=) && _bind_names!(out, b.args[1]))
        end
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :local || h === :global
        for a in ex.args; _bind_names!(out, a); end
    else
        for a in ex.args; _collect_binds!(out, a); end
    end
end

# All names bound by the cell's complete leading statements (stops at the first
# incomplete/erroring statement — typically the line being typed).
function _cell_locals(code::AbstractString)
    out = Set{Symbol}()
    s = String(code); n = ncodeunits(s); idx = 1
    while idx <= n
        ex, nxt = try
            Meta.parse(s, idx; raise = false)
        catch
            break
        end
        ex === nothing && break
        (ex isa Expr && (ex.head === :incomplete || ex.head === :error)) && break
        _collect_binds!(out, ex)
        nxt <= idx && break
        idx = nxt
    end
    return out
end

function _make_router(h::Hub)
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/", _ -> _html(_index_html(h)))
    HTTP.register!(router, "GET", "/api/notebooks", _ -> _json(_notebooks_json(h)))
    # Open/close a notebook by path over HTTP — lets the index page (and any
    # caller) bring up a notebook without the `slate.*` MCP tools. Mirrors
    # `KaimonSlate.create_tools`'s open: creates the file if it doesn't exist.
    HTTP.register!(router, "POST", "/api/open", req -> begin
        path = expanduser(strip(String(get(_body(req), "path", ""))))   # resolve ~ (tab-complete emits ~ paths)
        isempty(path) && return HTTP.Response(400, "missing path")
        isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
        id = open_notebook!(h, path)
        _json(Dict("id" => id, "url" => "/n/$id", "path" => abspath(path)))
    end)
    HTTP.register!(router, "POST", "/api/close", req -> begin
        file = abspath(expanduser(strip(String(get(_body(req), "path", "")))))
        id = lock(h.lock) do
            for nb in values(h.notebooks)
                abspath(nb.path) == file && return nb.id
            end
            return nothing
        end
        id === nothing ? HTTP.Response(404, "not open") : (close_notebook!(h, id); _json(Dict("closed" => file)))
    end)
    HTTP.register!(router, "GET", "/api/path-complete", req -> begin
        q = get(HTTP.queryparams(HTTP.URI(req.target)), "q", "")
        _json(Dict("completions" => _path_completions(q)))
    end)
    HTTP.register!(router, "GET", "/n/{id}", _ -> _html(read(_ASSET, String)))
    HTTP.register!(router, "GET", "/api/{id}/state", req -> _withnb(h, req, nb -> (sync_from_file!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/cell/{cid}", req -> _withnb(h, req, nb -> begin
        edit_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "source", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/complete", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        code = String(get(body, "code", ""))
        pos = clamp(Int(get(body, "pos", ncodeunits(code))), 0, ncodeunits(code))
        mod = nb.report.mod === nothing ? Main : nb.report.mod
        pstart, prefix, dotted = _id_prefix(code, pos)
        texts, from, to = try
            comps, range, _ = REPL.REPLCompletions.completions(code, pos, mod)
            ([REPL.REPLCompletions.completion_text(c) for c in comps], first(range) - 1, last(range))
        catch
            (String[], pstart, pos)
        end
        if !dotted                          # union in cell-local bindings (skip field access)
            have = Set(texts)
            locals = try; _cell_locals(code); catch; Set{Symbol}(); end
            extra = sort!(String[n for n in (String(s) for s in locals) if startswith(n, prefix) && !(n in have)])
            isempty(extra) || (texts = vcat(extra, texts))
        end
        _json(Dict("completions" => texts, "from" => from, "to" => to))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-add", req -> _withnb(h, req, nb -> begin
        b = _body(req); add_cell!(nb, get(b, "after", ""), get(b, "kind", "code")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-delete/{cid}", req -> _withnb(h, req, nb ->
        (delete_cell!(nb, HTTP.getparam(req, "cid")); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/cell-move/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req); cid = HTTP.getparam(req, "cid")
        haskey(b, "target") ? move_cell_rel!(nb, cid, b["target"], get(b, "before", true) === true) :
                              move_cell!(nb, cid, get(b, "dir", "up"))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-type/{cid}", req -> _withnb(h, req, nb -> begin
        set_kind!(nb, HTTP.getparam(req, "cid"), get(_body(req), "kind", "code")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/controls", req -> _withnb(h, req, nb -> begin
        set_controls_map!(nb, get(_body(req), "map", Dict{String,Any}())); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/bind/{cid}", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        set_bind!(nb, HTTP.getparam(req, "cid"), get(body, "name", ""), get(body, "value", nothing))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/table-page", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        res = lock(nb.lock) do                       # serialize vs eval (shared gate connection)
            ReportEngine.table_page(nb.kernel, nb.report, String(get(b, "table_id", "")), b)
        end
        _json(Dict("rows" => res.rows, "total" => res.total))
    end))
    HTTP.register!(router, "POST", "/api/{id}/undo", req -> _withnb(h, req, nb -> (undo!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/redo", req -> _withnb(h, req, nb -> (redo!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/run", req -> _withnb(h, req, nb -> (eval_stale!(nb.report, nb.kernel); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/reset", req -> _withnb(h, req, nb -> begin
        ReportEngine.reset!(nb.kernel, nb.report); build_dependencies!(nb.report); eval_stale!(nb.report, nb.kernel); _json(state_json(nb))
    end))
    return router
end

const _EVENTS_RE = r"^/api/([^/]+)/events$"

"""
    start_hub(; host="127.0.0.1", port=8765) -> Hub

Start the single notebook server with an empty registry. Add notebooks with
[`open_notebook!`](@ref). Non-blocking.
"""
function start_hub(; host = "127.0.0.1", port = 8765)
    h = Hub(Dict{String,LiveNotebook}(), nothing, host, port, ReentrantLock())
    handle = HTTP.streamhandler(_make_router(h))
    server = HTTP.listen!(host, port) do stream::HTTP.Stream
        m = match(_EVENTS_RE, stream.message.target)
        if m !== nothing
            nb = lock(h.lock) do; get(h.notebooks, m.captures[1], nothing); end
            nb === nothing ? (HTTP.setstatus(stream, 404); HTTP.startwrite(stream)) : _sse(stream, nb)
        else
            handle(stream)
        end
    end
    h.server = server
    @info "Kaimon Slate hub" url = _hub_url(h)
    return h
end

"""
    open_notebook!(hub, path) -> id

Load the notebook at `path` into the hub (reusing the existing entry if already
open) and start its file watcher. Returns the hub id (its `/n/<id>` route).
"""
function open_notebook!(h::Hub, path::AbstractString)
    file = abspath(path)
    lock(h.lock) do
        for nb in values(h.notebooks)
            abspath(nb.path) == file && return nb.id
        end
        id = _unique_id(h, file)
        nb = load_notebook(file; id = id)
        h.notebooks[id] = nb
        _start_watcher!(nb)
        return id
    end
end

"Remove a notebook from the hub: drain its SSE connections and drop it."
function close_notebook!(h::Hub, id::AbstractString)
    lock(h.lock) do
        nb = get(h.notebooks, id, nothing)
        nb === nothing && return false
        _close_listeners(nb)
        unregister_refresh!(nb.report.id)
        try; shutdown!(nb.kernel); catch; end
        delete!(h.notebooks, id)
        return true
    end
end

"Stop the hub: drain every notebook's SSE connections, then close the server."
function stop_hub(h::Hub)
    lock(h.lock) do
        for nb in values(h.notebooks)
            _close_listeners(nb); unregister_refresh!(nb.report.id)
            try; shutdown!(nb.kernel); catch; end
        end
        empty!(h.notebooks)
    end
    h.server === nothing || close(h.server)
    return nothing
end

# ── Standalone convenience (one notebook) ─────────────────────────────────────

"""
    start_server(path; host="127.0.0.1", port=8765) -> Hub

Start a hub and open the single notebook at `path`. Non-blocking; returns the
`Hub` (stop it with [`stop_hub`](@ref)). The notebook is served at `/n/<id>`
(printed); `/` is the index. For a blocking launcher use [`serve_notebook`](@ref).
"""
function start_server(path::AbstractString; host = "127.0.0.1", port = 8765)
    h = start_hub(; host = host, port = port)
    id = open_notebook!(h, path)
    @info "Notebook" url = "$(_hub_url(h))/n/$id" file = abspath(path)
    return h
end

"Stop a hub started by [`start_server`](@ref) (drains SSE, frees the port)."
stop_server(h::Hub) = stop_hub(h)

"""
    serve_notebook(path; host="127.0.0.1", port=8765)

Open the notebook at `path` in a hub and serve it. **Blocks** until stopped.
"""
function serve_notebook(path::AbstractString; host = "127.0.0.1", port = 8765)
    h = start_server(path; host = host, port = port)
    wait(h.server)
    return h
end

end # module NotebookServer
