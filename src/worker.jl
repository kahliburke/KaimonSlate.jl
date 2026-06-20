# Per-notebook gate worker payload (Phase 2). Loaded *standalone* into a worker
# Julia process pinned to the notebook's project (`julia --project=<nb project>`,
# with KaimonGate on LOAD_PATH). It runs KaimonGate as a TCP gate exposing capture
# tools; the KaimonSlate extension drives it over the gate via `:tool_call`.
#
# This is NOT part of `using KaimonSlate` — the extension server never loads it,
# and KaimonSlate gains no KaimonGate dependency. Only the worker process loads it,
# via `include(".../worker.jl")` in its boot script. It shares `capture.jl` with
# the engine, so there is exactly one capture implementation.

module SlateWorker

import KaimonGate
import Pkg                                   # project dep listing for eager docs auto-index

# The enclosing/parent project dir stacked behind this notebook env on LOAD_PATH (set by
# the boot script; "" when the notebook is detached). Used to attribute package provenance
# — which deps are notebook-specific adds vs. inherited from the parent project.
const PARENT_PROJECT = Ref("")

# Minimal ECharts marker so notebooks can `echart(opt)`. Only the struct + helper
# live here (no JSON); the server JSON-encodes the option Dict. `capture.jl`
# detects `value isa EChart` and ships back the raw Dict.
struct EChart
    option::Any
end
echart(option::AbstractDict) = EChart(Dict{String,Any}(string(k) => v for (k, v) in option))

include(joinpath(@__DIR__, "tables.jl"))    # SlateTable / slate_table — uses no deps; soft-detects Tables.jl
include(joinpath(@__DIR__, "paged.jl"))     # PagedProvider / SlatePagedTable / slate_query (provider registry)
include(joinpath(@__DIR__, "widgets.jl"))   # shared @bind widgets + namespace contract (engine + worker)
include(joinpath(@__DIR__, "docharvest.jl")) # shared docstring harvest (runs where the deps are loaded)
include(joinpath(@__DIR__, "capture.jl"))   # run_capture — uses EChart + SlateTable above
include(joinpath(@__DIR__, "completion.jl")) # slate_completions — REPLCompletions in the NB namespace

# Per-notebook execution namespace (warm; reset by replacing the module). Built by the
# SAME shared contract `_populate_notebook_ns!` as the in-process kernel, so the two
# namespaces are identical; only `slate_refresh` differs — here it PUBs on the gate
# stream (a cell's async task calls `slate_refresh(:data)`; the KaimonSlate server,
# subscribed, recomputes those vars' readers and pushes a live update).
function _new_ns()
    m = Module(:NB)
    _populate_notebook_ns!(m;
        echart = echart, EChart = EChart, slate_table = slate_table, SlateTable = SlateTable,
        slate_query = slate_query,
        slate_refresh = (vars...) -> KaimonGate._publish_stream("slate_refresh", join(string.(vars), ",")))
    return m
end
const _NS = Ref{Module}(_new_ns())

# ── Capture tools (invoked by the server via synchronous :tool_call) ───────────
# Each returns a serialization-friendly value that rides back binary in the gate
# response's `value` field.

"Evaluate a cell's source in the warm namespace; return the wire-form capture."
__slate_eval(source::String) = run_capture(_NS[], source)

"Apply a browser `@bind` value change: coerce against the widget, update the registry,
and assign the global — via the namespace's injected `__slate_set_bind`. Returns the
coerced value."
function __slate_set_bind(name::String, value)
    return Base.invokelatest(getfield(_NS[], :__slate_set_bind), Symbol(name), value)
end

"Discard the namespace (full rebuild)."
__slate_reset() = (_NS[] = _new_ns(); true)

# Flat scalar args only (the gate reflects the signature into an MCP schema — a
# nested-Dict argument doesn't validate, so we pass page params individually).
"Fetch one page of a registered paged table (server-paged tables / `slate_query`)."
__slate_table_page(table_id::String, page::Int, page_size::Int, sort_col::Int, sort_desc::Bool, search::String) =
    _provider_page(table_id, PageRequest(page, page_size, sort_col, sort_desc, search))

"Capture markdown `{{ }}` interpolation expressions (rich) — one wire-form each."
__slate_interp(exprs::Vector{String}) = [run_capture(_NS[], e) for e in exprs]

"Completion candidates in the warm namespace → `(; items, from, to)` (see `slate_completions`)."
__slate_complete(code::String, pos::Int) = slate_completions(_NS[], code, pos)

# A throwaway module to `import` packages into for harvesting, so eager indexing can
# load project deps the notebook hasn't `using`'d WITHOUT polluting the cell namespace.
const _DOC_SCAN = Ref{Module}()
_doc_scan() = (isassigned(_DOC_SCAN) || (_DOC_SCAN[] = Module(:_SlateDocScan)); _DOC_SCAN[])

"Harvest `{module,name,doc}` for the named modules (loading them if needed) — for docs search."
function __slate_harvest_docs(mod_names::Vector{String})
    m = _doc_scan()
    for nm in mod_names
        try; Core.eval(m, Meta.parse("import " * nm)); catch; end   # load if needed; no-op if already
    end
    return harvest_module_docs(m, mod_names)
end

"Resolve `name` (loading its head module if needed) and return its help record
`{name,module,doc,kind,exports}` — powers the docs palette's `?Module` drill-down."
function __slate_module_help(name::String)
    head = String(first(split(name, '.')))
    # Prefer the live notebook namespace: a `using`'d or cell-defined symbol (e.g. `damped_wave`)
    # resolves there WITH its docs. Only fall back to a throwaway module that imports the head
    # package for `?Module` drill-down on a package the notebook hasn't brought into scope.
    nb = _NS[]
    if isdefined(nb, Symbol(head))
        rec = try; module_help(nb, name); catch; nothing; end
        rec !== nothing && (get(rec, "kind", "unknown") != "unknown" || !isempty(strip(get(rec, "doc", "")))) && return rec
    end
    m = _doc_scan()
    try; Core.eval(m, Meta.parse("import " * head)); catch; end   # load the package if needed
    return module_help(m, name)
end

"The worker project's direct dependencies as `{name, version}` (for eager docs auto-index)."
function __slate_project_deps()
    out = Dict{String,Any}[]
    try
        proj = Pkg.project()
        info = Pkg.dependencies()
        for (name, uuid) in proj.dependencies
            pi = get(info, uuid, nothing)
            ver = (pi === nothing || pi.version === nothing) ? "" : string(pi.version)
            push!(out, Dict{String,Any}("name" => name, "version" => ver, "uuid" => string(uuid)))
        end
    catch
    end
    return out
end

"Read a project's direct deps as `[{name, version, uuid}]`. Versions come from the project's
own `Manifest.toml` when present (best-effort), so this works for a project that isn't the
active one (e.g. the parent). Returns `[]` on any failure."
function _project_deps_at(projdir::AbstractString)
    out = Dict{String,Any}[]
    try
        pf = joinpath(projdir, "Project.toml")
        isfile(pf) || return out
        proj = Pkg.TOML.parsefile(pf)
        deps = get(proj, "deps", Dict{String,Any}())
        # versions: parse the sibling Manifest if present (format differs across Julia, but
        # each dep entry is a 1-elt array of tables carrying `version`).
        vers = Dict{String,String}()
        mf = joinpath(projdir, "Manifest.toml")
        if isfile(mf)
            man = Pkg.TOML.parsefile(mf)
            mdeps = get(man, "deps", man)               # Julia ≥1.7 nests under "deps"
            for (nm, entries) in mdeps
                entries isa AbstractVector && !isempty(entries) && haskey(entries[1], "version") &&
                    (vers[nm] = string(entries[1]["version"]))
            end
        end
        for (name, uuid) in deps
            push!(out, Dict{String,Any}("name" => name, "version" => get(vers, name, ""), "uuid" => string(uuid)))
        end
    catch
    end
    return out
end

"Environment provenance for the package viewer: the notebook's own direct deps (the active
project — where `Pkg.add` lands) and, separately, the parent project's deps (inherited via
LOAD_PATH stacking). Shape: `{notebook:{path,deps}, parent:{path,deps}|nothing}`."
function __slate_env_info()
    nb = Dict{String,Any}("path" => "", "deps" => Dict{String,Any}[])
    try
        nb["path"] = dirname(Pkg.project().path)
        nb["deps"] = __slate_project_deps()
    catch
    end
    parent = nothing
    p = PARENT_PROJECT[]
    if !isempty(p)
        name = ""
        ppf = joinpath(p, "Project.toml")
        isfile(ppf) && (name = string(get(Pkg.TOML.parsefile(ppf), "name", "")))
        parent = Dict{String,Any}("path" => p, "name" => name, "deps" => _project_deps_at(p))
    end
    return Dict{String,Any}("notebook" => nb, "parent" => parent)
end

# Seed a forked notebook env from `parent`: copy the parent's deps + compat (NOT its package
# identity) and its Manifest as the resolution baseline, activate the env, then `dev` the
# parent package in so `using ParentModule` works — all preserving the parent's pinned
# versions, so anything already loaded in this worker stays valid. One consistent env.
function _seed_notebook_env!(envdir::AbstractString, parent::AbstractString)
    mkpath(envdir)
    pname = ""
    ppf = joinpath(parent, "Project.toml")
    if isfile(ppf)
        pt = Pkg.TOML.parsefile(ppf)
        seed = Dict{String,Any}()
        haskey(pt, "deps") && (seed["deps"] = pt["deps"])
        haskey(pt, "compat") && (seed["compat"] = pt["compat"])
        open(joinpath(envdir, "Project.toml"), "w") do io; Pkg.TOML.print(io, seed); end
        pmf = joinpath(parent, "Manifest.toml")
        isfile(pmf) && cp(pmf, joinpath(envdir, "Manifest.toml"); force = true)
        (haskey(pt, "name") && haskey(pt, "uuid")) && (pname = String(pt["name"]))
    else
        write(joinpath(envdir, "Project.toml"), "")
    end
    Pkg.activate(envdir)
    if !isempty(pname)
        try
            Pkg.develop(Pkg.PackageSpec(path = parent); preserve = Pkg.PRESERVE_ALL)
        catch
            try; Pkg.develop(Pkg.PackageSpec(path = parent)); catch; end
        end
    end
    return pname
end

"Fork this notebook off its parent: materialise + activate the notebook env (`envdir`) as a
single environment that extends the parent. Called the first time a package is added while
running in base mode. Returns `{ok, message}`."
function __slate_fork(envdir, parent)
    try
        _seed_notebook_env!(String(envdir), String(parent))
        return Dict{String,Any}("ok" => true)
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"Re-resolve a forked notebook env against the CURRENT parent (called when the parent's
Manifest changed): re-seed from the parent, then re-add the notebook's own packages so the
two stay one consistent environment. Returns `{ok, adds}`."
function __slate_sync_parent(envdir, parent)
    try
        e = String(envdir); p = String(parent)
        fdeps = Set{String}()
        fpf = joinpath(e, "Project.toml")
        isfile(fpf) && (fdeps = Set(keys(get(Pkg.TOML.parsefile(fpf), "deps", Dict{String,Any}()))))
        pdeps = Set{String}(); pname = ""
        ppf = joinpath(p, "Project.toml")
        if isfile(ppf)
            pt = Pkg.TOML.parsefile(ppf)
            pdeps = Set(keys(get(pt, "deps", Dict{String,Any}())))
            pname = string(get(pt, "name", ""))
        end
        adds = sort(collect(setdiff(fdeps, pdeps, Set([pname, ""]))))   # the notebook's own packages
        _seed_notebook_env!(e, p)
        isempty(adds) || Pkg.add(adds; preserve = Pkg.PRESERVE_ALL)
        return Dict{String,Any}("ok" => true, "adds" => adds)
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"Reconstruct a notebook env from its `.jl` footer: seed from the parent, then add the
notebook's own packages at the recorded versions. Called on open when the env dir is
absent (e.g. a fresh git clone) but the footer records a delta. `pkgs` is a list of
`{name, version, uuid}`. Returns `{ok, message}`."
function __slate_reconstruct(envdir, parent, pkgs)
    try
        _seed_notebook_env!(String(envdir), String(parent))
        specs = Pkg.PackageSpec[]
        for p in pkgs
            nm = String(get(p, "name", get(p, :name, "")))
            isempty(nm) && continue
            v = string(get(p, "version", get(p, :version, "")))
            push!(specs, isempty(v) ? Pkg.PackageSpec(name = nm) : Pkg.PackageSpec(name = nm, version = VersionNumber(v)))
        end
        isempty(specs) || Pkg.add(specs)
        return Dict{String,Any}("ok" => true)
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"Filesystem coordinates for a self-contained export: the active project dir (its
Project.toml + Manifest.toml fully pin the env) and any path/dev dependencies' source dirs
(the local/parent module code to bundle). The server reads these paths directly (same
machine) to build the tarball. Shape: `{projectdir, pathdeps:[{name, source}]}`."
function __slate_bundle_info()
    out = Dict{String,Any}("projectdir" => "", "pathdeps" => Dict{String,Any}[])
    try
        out["projectdir"] = dirname(Pkg.project().path)
        for (_uuid, pi) in Pkg.dependencies()
            if pi.is_tracking_path && pi.source !== nothing && isdir(pi.source)
                push!(out["pathdeps"], Dict{String,Any}("name" => pi.name, "source" => String(pi.source)))
            end
        end
    catch
    end
    return out
end

"Add or remove a package in the worker's OWN active project (the notebook's deps).
`op` is \"add\" or \"rm\". Returns `{ok, message}`."
function __slate_pkg(op, name)
    nm = strip(String(name))
    isempty(nm) && return Dict{String,Any}("ok" => false, "message" => "empty package name")
    try
        o = String(op)
        o == "add" ? Pkg.add(nm) :
        o == "rm"  ? Pkg.rm(nm) :
        return Dict{String,Any}("ok" => false, "message" => "unknown op '$o'")
        return Dict{String,Any}("ok" => true, "message" => "$(o == "add" ? "added" : "removed") $nm")
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

# ── Hot-reload of the parent project's /src (Revise) ──────────────────────────
# Revise is loaded in Main by the boot script and tracks dev'd packages (the notebook's
# parent project). KaimonGate's serve() PUBs `files_changed` on each Revise.revision_event;
# the slate server then calls __slate_revise to APPLY the pending revisions and learn which
# definitions changed, so it can invalidate exactly the cells that read them.

# `_def_name` / `_sig_name` / `_name_str` / `findfirst_def` — the top-level-def name extractor,
# in a shared, dependency-free file so it's unit-tested directly (test/test_defname.jl).
include(joinpath(@__DIR__, "defname.jl"))

# Changed top-level def-names from a snapshot of (PkgData, relpath) revision entries. Reads the
# changed file's parsed defs (whole file → file-granular invalidation), best-effort.
function _changed_names(queue)
    changed = Set{String}()
    for item in queue
        try
            pd, rpath = item
            idx = findfirst(==(rpath), pd.info.files)
            idx === nothing && continue
            for (_mod, exprinfos) in pd.fileinfos[idx].mod_exs_infos, (rex, _info) in exprinfos
                nm = _def_name(convert(Expr, rex)); nm === nothing || push!(changed, nm)
            end
        catch
        end
    end
    return collect(changed)
end

# A Revise apply error → a short message (the file + reason), best-effort across Revise versions.
# Snapshot of the keys currently in Revise's (persistent) error queue.
_qe_keys(R) = try; isdefined(R, :queue_errors) ? Set(collect(keys(R.queue_errors))) : Set{Any}(); catch; Set{Any}(); end

# An error message IF this revise introduced one. `thrown` is a revise() throw; otherwise we
# compare queue_errors against `before` and only report errors NEW to this pass — `queue_errors`
# RETAINS old entries, so checking it absolutely would wedge us in the error branch forever
# (the bug behind "stopped notifying after a few edits").
function _revise_error_msg(R, thrown, before::Set)
    thrown === nothing || return first(sprint(showerror, thrown), 400)
    qe = try; isdefined(R, :queue_errors) ? R.queue_errors : nothing; catch; nothing; end
    qe === nothing && return ""
    newks = [k for k in keys(qe) if !(k in before)]
    isempty(newks) && return ""
    return try
        k = newks[1]; v = qe[k]; ex = v isa Tuple ? v[1] : v
        "$(basename(string(k))): $(first(sprint(showerror, ex), 300))"
    catch
        "Revise could not apply a source change."
    end
end

const _LAST_SRC_ERR = Ref{String}("")

# Resilient headless hot-reload. Revise's own file watchers populate `revision_queue`
# headlessly; we poll it, APPLY the revisions, and PUB either the changed def-names
# (`slate_revise`) or a parse/load error (`slate_revise_err`). Every iteration is wrapped so a
# bad/invalid save can NEVER kill the watcher — tracking resumes the instant the file parses
# again. Logs each pass so the worker log shows what hot-reload is doing.
function _start_src_watcher()
    if !isdefined(Main, :Revise)
        @info "slate hot-reload: Revise not loaded — disabled"
        return nothing
    end
    @info "slate hot-reload: watcher started"
    @async while true
        try
            sleep(0.4)
            R = Main.Revise
            (isdefined(R, :revision_queue) && !isempty(R.revision_queue)) || continue
            queue = collect(R.revision_queue)
            before = _qe_keys(R)
            thrown = nothing
            try; R.revise(); catch e; thrown = e; end
            emsg = _revise_error_msg(R, thrown, before)
            if !isempty(emsg)
                @warn "slate hot-reload: revise error" error = emsg
                if emsg != _LAST_SRC_ERR[]
                    _LAST_SRC_ERR[] = emsg
                    KaimonGate._publish_stream("slate_revise_err", emsg)
                end
            else
                _LAST_SRC_ERR[] = ""
                names = _changed_names(queue)
                @info "slate hot-reload: revised" files = length(queue) changed = names
                isempty(names) || KaimonGate._publish_stream("slate_revise", join(names, ","))
            end
        catch e
            try; @warn "slate hot-reload: watcher iteration failed" exception = e; catch; end
            try; sleep(0.5); catch; end
        end
    end
    return nothing
end

"Apply pending Revise revisions; return the changed top-level def names (manual / testing)."
function __slate_revise()
    isdefined(Main, :Revise) || return String[]
    queue = try; collect(Main.Revise.revision_queue); catch; Tuple[]; end
    try; Main.Revise.revise(); catch; end
    return _changed_names(queue)
end

"GateTools exposed to the KaimonSlate server."
function tools()
    return KaimonGate.GateTool[
        KaimonGate.GateTool("__slate_eval", __slate_eval),
        KaimonGate.GateTool("__slate_set_bind", __slate_set_bind),
        KaimonGate.GateTool("__slate_reset", __slate_reset),
        KaimonGate.GateTool("__slate_table_page", __slate_table_page),
        KaimonGate.GateTool("__slate_interp", __slate_interp),
        KaimonGate.GateTool("__slate_complete", __slate_complete),
        KaimonGate.GateTool("__slate_harvest_docs", __slate_harvest_docs),
        KaimonGate.GateTool("__slate_module_help", __slate_module_help),
        KaimonGate.GateTool("__slate_project_deps", __slate_project_deps),
        KaimonGate.GateTool("__slate_env_info", __slate_env_info),
        KaimonGate.GateTool("__slate_fork", __slate_fork),
        KaimonGate.GateTool("__slate_sync_parent", __slate_sync_parent),
        KaimonGate.GateTool("__slate_reconstruct", __slate_reconstruct),
        KaimonGate.GateTool("__slate_bundle_info", __slate_bundle_info),
        KaimonGate.GateTool("__slate_pkg", __slate_pkg),
        KaimonGate.GateTool("__slate_revise", __slate_revise),
    ]
end

"""
    start(; host="127.0.0.1", port, stream_port)

Run the worker gate over TCP, exposing the capture tools. Blocks (this is the
worker process's main loop).
"""
function start(; host::String = "127.0.0.1", port::Int, stream_port::Int)
    KaimonGate.serve(; mode = :tcp, host = host, port = port, stream_port = stream_port,
                     tools = tools(), force = true, allow_mirror = false,
                     allow_restart = false, spawned_by = "slate")
    _start_src_watcher()   # resilient /src hot-reload (Revise); no-op if Revise didn't load
    # `serve` runs the message loop on a spawned thread and returns — but this is
    # a non-interactive `-e` process, so we must block to keep it alive until a
    # remote `:shutdown` (which calls `exit(0)` from the gate task). Flush each
    # tick so stdout/stderr (block-buffered when piped, not a TTY) reaches the
    # parent's log reader live rather than only on exit/crash.
    while true
        flush(stdout); flush(stderr)
        sleep(1)
    end
end

end # module SlateWorker
