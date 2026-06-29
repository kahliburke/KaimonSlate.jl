# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Semantic docs search (docs v2) ────────────────────────────────────────────
# Index harvested docstrings into a Qdrant collection via Kaimon's Ollama+Qdrant
# tools (reached through the service endpoint), so the agent AND the UI can search
# the Julia/package API by meaning. Embeddings: qwen3-embedding:0.6b (1024-d, cosine).
const _DOCS_COLLECTION = "slate_docs"
const _DOCS_DIM = 1024
const _DOCS_MODEL = "qwen3-embedding:0.6b"

# Call a Kaimon MCP tool, RAW value (service endpoint uses Serialization, so
# vectors/dicts come back native; tolerate a JSON-string handler too).
_kt(tool::Symbol, args::Dict) = getfield(Main, :Kaimon).KaimonGate.call_tool(tool, Dict{String,Any}(args))
_kt_json(v) = v isa AbstractString ? JSON.parse(v) : v
# Tolerant field access — results may be Dicts (string or symbol keys) or NamedTuples.
_field(x, k) = x isa AbstractDict ? get(x, k, get(x, Symbol(k), nothing)) :
               (hasproperty(x, Symbol(k)) ? getproperty(x, Symbol(k)) : nothing)

_embed(text::AbstractString) = Float64[Float64(x) for x in
    _kt_json(_kt(:ollama_embed, Dict("text" => String(text), "model" => _DOCS_MODEL)))]

function _ensure_docs_collection()
    ex = _kt_json(_kt(:qdrant_collection_exists, Dict("collection" => _DOCS_COLLECTION)))
    (ex === true || ex == "true") && return
    _kt(:qdrant_create_collection, Dict("collection" => _DOCS_COLLECTION,
                                        "vector_size" => _DOCS_DIM, "distance" => "Cosine"))
    return
end

# Stable positive id for a doc record (first 60 bits of its SHA-256 → fits Int).
_doc_id(s) = parse(Int, SlateHistory._sha(s)[1:15]; base = 16)

"Embed + upsert harvested doc records into the search index. Returns the count indexed."
function index_docs!(records)
    _agent_available() || return 0
    isempty(records) && return 0
    _ensure_docs_collection()
    n = 0
    for r in records
        modname = string(get(r, "module", "")); name = string(get(r, "name", ""))
        doc = string(get(r, "doc", "")); text = "$modname.$name\n$doc"
        vec = try; _embed(text); catch; continue; end
        pt = Dict("id" => _doc_id(text), "vector" => vec,
                  # `text` (= "Module.name\ndoc") lets Kaimon's FTS index this point — trigram
                  # substring then matches a bare name/module fragment the embedding buries.
                  # `metadata.module` is what BOTH engines filter on for module scoping: Qdrant
                  # keys filters as `metadata.$field`; the FTS side reads json_extract(metadata,
                  # '$.module') — and backfill_fts! mirrors this `metadata` dict from the payload.
                  "payload" => Dict("module" => modname, "name" => name, "doc" => doc, "text" => text,
                                    "metadata" => Dict("module" => modname)))
        try; _kt(:qdrant_upsert_points, Dict("collection" => _DOCS_COLLECTION, "points" => [pt])); n += 1; catch; end
    end
    return n
end

"Mirror the docs collection's `text` + `metadata` payloads into Kaimon's FTS index (the plain
upsert path doesn't), so lexical name/substring search AND module filters work. Idempotent;
best-effort if FTS is unavailable. The auto-index path calls this; the manual `index_docs` tool too."
ensure_docs_fts!() = (try; _kt(:qdrant_ensure_fts_coverage, Dict("collection" => _DOCS_COLLECTION)); catch; end; nothing)

# Map one `search_code` structured hit → {module,name,doc,score}. The indexed `text` payload is
# "Module.name\ndoc" (see index_docs!), so module/name/doc are recovered from it (the hit's own
# `name` field wins for the symbol when present).
function _doc_record(h)
    name = string(something(_field(h, "name"), ""))
    text = string(something(_field(h, "text"), ""))
    nl = findfirst('\n', text)
    head = nl === nothing ? text : String(SubString(text, 1, prevind(text, nl)))
    doc  = nl === nothing ? "" : String(SubString(text, nextind(text, nl)))
    i = findlast('.', head)
    modname = i === nothing ? "" : String(SubString(head, 1, prevind(head, i)))
    isempty(name) && i !== nothing && (name = String(SubString(head, nextind(head, i))))
    return Dict{String,Any}("module" => modname, "name" => name, "doc" => doc,
                            "score" => something(_field(h, "score"), 0.0))
end

"Hybrid docs search over the `slate_docs` index. ONE `search_code` call now does the query embed,
the semantic+lexical fusion, and span-dedup — replacing the old `_embed` + `_semantic_docs` +
`_fts_docs` + hand-rolled fusion (per Kaimon's SEARCH_INTEGRATION_NOTES two-tool model). `modules`
(when non-empty) scopes to those packages via a `metadata.module` any-of `filters` on BOTH engines —
pass the notebook's in-scope set (`_inscope_modules`) so a query can't surface another notebook's
packages from the shared index. Notes: `collection` is required (the service endpoint has no
workspace binding); `embedding_model` must match `index_docs!` (qwen3-embedding:0.6b) or the
semantic arm degrades to lexical-only — which still returns name/substring hits."
function search_docs(query::AbstractString; limit::Int = 8, modules::AbstractVector = String[])
    _agent_available() || return Dict{String,Any}[]
    q = strip(String(query)); isempty(q) && return Dict{String,Any}[]
    args = Dict{String,Any}("collection" => _DOCS_COLLECTION, "query" => q, "mode" => "hybrid",
                            "format" => "structured", "embedding_model" => _DOCS_MODEL, "limit" => limit)
    isempty(modules) || (args["filters"] = Dict("module" => String[string(m) for m in modules]))
    hits = try
        _kt_json(_kt(:search_code, args))
    catch
        return Dict{String,Any}[]   # search index unavailable → no docs (caller falls back to lexical UI)
    end
    hits isa AbstractVector || return Dict{String,Any}[]
    return Dict{String,Any}[_doc_record(h) for h in first(hits, limit)]
end

# A docstring (markdown) → safe HTML for the help viewer. Empty in → empty out.
_doc_esc(s) = replace(String(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;")
_doc_html(doc) = (s = strip(String(doc)); isempty(s) ? "" : (try; markdown_html(s); catch; "<pre>" * _doc_esc(s) * "</pre>"; end))

# Live help lookup for `name` (a binding or module), resolved where cells eval. Returns the
# module_help record + a rendered `docHtml`. Powers the docs palette's ?Module drill-down +
# cross-reference links. Best-effort: a missing kernel/binding yields an empty-ish record.
function help_lookup(nb::LiveNotebook, name::AbstractString)
    rec = try
        ReportEngine.module_help(nb.kernel, nb.report, String(name))
    catch
        Dict{String,Any}("name" => String(name), "module" => "", "doc" => "", "kind" => "unknown", "exports" => Dict{String,Any}[])
    end
    rec["docHtml"] = _doc_html(get(rec, "doc", ""))
    return rec
end

# ── Auto-indexing ─────────────────────────────────────────────────────────────
# Index docs WITHOUT the agent asking: on open, eagerly index the notebook's project
# deps; incrementally pick up any package a cell `using`s. Runs in the background and
# is version-cached (persistent), so re-opens are instant and only changed deps re-index.
const _DOC_CACHE = Dict{String,String}()                 # package name → last-indexed version
const _DOC_CACHE_LOCK = ReentrantLock()
const _DOC_SCHEMA = "3"   # bump when the indexed payload shape changes → forces a one-time re-harvest
                          # (schema 2 added the `text` payload that Kaimon's FTS index needs;
                          #  schema 3 added the `metadata.module` payload that module-scoped filters read)
_doc_cache_file() = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                             "kaimonslate", "docindex.json")
function _doc_cache_load()
    lock(_DOC_CACHE_LOCK) do
        isempty(_DOC_CACHE) || return
        f = _doc_cache_file()
        isfile(f) || return
        try
            loaded = Dict(String(k) => string(v) for (k, v) in JSON.parsefile(f))
            # A stale schema → leave the cache empty so every package re-harvests + re-indexes
            # (re-upserting the same point ids with the new payload; the old points are overwritten).
            get(loaded, "__schema__", "") == _DOC_SCHEMA && merge!(_DOC_CACHE, loaded)
        catch
        end
    end
end
function _doc_cache_put!(name, version)
    lock(_DOC_CACHE_LOCK) do
        _DOC_CACHE[String(name)] = String(version)
        _DOC_CACHE["__schema__"] = _DOC_SCHEMA           # not a package — never in the harvest set
        f = _doc_cache_file()
        try; mkpath(dirname(f)); open(f, "w") do io; JSON.print(io, _DOC_CACHE); end; catch; end
    end
end

# Package names `using`/`import`ed across the notebook's code cells (`using X: y` → X).
function _used_packages(report::Report)
    pkgs = String[]
    for c in report.cells
        c.kind == CODE || continue
        top = try; Meta.parseall(c.source); catch; continue; end
        for s in (top isa Expr && top.head === :toplevel ? top.args : Any[top])
            (s isa Expr && (s.head === :using || s.head === :import)) || continue
            for a in s.args
                m = (a isa Expr && a.head === :(:)) ? a.args[1] : a
                if m isa Expr && m.head === :. && !isempty(m.args) && m.args[1] isa Symbol
                    nm = String(m.args[1])
                    nm in ("Base", "Core", "Main") || push!(pkgs, nm)
                end
            end
        end
    end
    return unique(pkgs)
end

# Base/Core docs (if ever indexed) are relevant to every notebook — always in scope so a hard
# module filter can never hide them. Stdlibs a notebook actually uses arrive via project_deps.
const _UNIVERSAL_MODULES = String["Base", "Core", "Slate"]   # "Slate" = the injected notebook helpers

"The package/module names in scope for `nb`: its project deps ∪ the packages its cells `using`,
plus the universal Base/Core. Drives module-scoped doc search so the SHARED index only surfaces
THIS notebook's packages, not another notebook's. Error-tolerant — a failure yields the universals."
function _inscope_modules(nb::LiveNotebook)
    mods = Set{String}(_UNIVERSAL_MODULES)
    for d in (try; ReportEngine.project_deps(nb.kernel, nb.report); catch; Dict{String,Any}[]; end)
        n = string(get(d, "name", "")); isempty(n) || push!(mods, n)
    end
    for u in _used_packages(nb.report); push!(mods, u); end
    return collect(mods)
end

"Background auto-index: project deps (eager) ∪ packages the cells use, version-cached."
function _autoindex!(nb::LiveNotebook)
    _agent_available() || return nothing
    Threads.@spawn try
        _doc_cache_load()
        # Slate's own injected helpers (echart / @bind / animate / …) — indexed under module "Slate"
        # so `search_docs` finds them too. Version-cached on the API docs' content hash.
        if get(_DOC_CACHE, "Slate", nothing) != slate_api_version()
            ns = index_docs!(slate_api_records())
            ns == 0 || (ensure_docs_fts!(); _doc_cache_put!("Slate", slate_api_version()))
        end
        want = Dict{String,String}()
        for d in (try; ReportEngine.project_deps(nb.kernel, nb.report); catch; Dict{String,Any}[]; end)
            n = string(get(d, "name", "")); isempty(n) || (want[n] = string(get(d, "version", "")))
        end
        for u in _used_packages(nb.report); haskey(want, u) || (want[u] = ""); end
        pending = String[n for (n, v) in want if get(_DOC_CACHE, n, nothing) != v]
        isempty(pending) && return
        recs = ReportEngine.harvest_docs(nb.kernel, nb.report, pending)
        index_docs!(recs)
        ensure_docs_fts!()   # mirror the new text+metadata payloads into the FTS index
        for n in pending; _doc_cache_put!(n, get(want, n, "")); end
        @info "slate: auto-indexed docs" notebook = nb.id packages = pending symbols = length(recs)
    catch e
        @warn "slate: auto-index failed" exception = (e, catch_backtrace())
    end
    return nothing
end

