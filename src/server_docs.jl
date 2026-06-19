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
                  "payload" => Dict("module" => modname, "name" => name, "doc" => doc, "text" => text))
        try; _kt(:qdrant_upsert_points, Dict("collection" => _DOCS_COLLECTION, "points" => [pt])); n += 1; catch; end
    end
    return n
end

"Semantic (vector) search of the docs index → {module,name,doc,score} matches."
function _semantic_docs(query::AbstractString; limit::Int = 8)
    vec = try; _embed(query); catch; return Dict{String,Any}[]; end
    res = _kt_json(_kt(:qdrant_search, Dict("collection" => _DOCS_COLLECTION,
                                            "vector" => vec, "limit" => limit)))
    hits = res isa AbstractVector ? res :
           something(_field(res, "result"), _field(res, "hits"), Any[])
    out = Dict{String,Any}[]
    for h in hits
        p = something(_field(h, "payload"), h)
        push!(out, Dict("module" => string(something(_field(p, "module"), "")),
                        "name"   => string(something(_field(p, "name"), "")),
                        "doc"    => string(something(_field(p, "doc"), "")),
                        "score"  => something(_field(h, "score"), 0.0)))
    end
    return out
end

# One FTS hit (its `text` payload is "Module.name\ndoc") → {module,name,doc,score,lexical}.
function _fts_record(h)
    name = string(something(_field(h, "name"), ""))
    text = string(something(_field(h, "text"), ""))
    nl = findfirst('\n', text)
    head = nl === nothing ? text : String(SubString(text, 1, prevind(text, nl)))
    doc  = nl === nothing ? "" : String(SubString(text, nextind(text, nl)))
    i = findlast('.', head)
    modname = i === nothing ? "" : String(SubString(head, 1, prevind(head, i)))
    isempty(name) && i !== nothing && (name = String(SubString(head, nextind(head, i))))
    return Dict{String,Any}("module" => modname, "name" => name, "doc" => doc,
                            "score" => something(_field(h, "score"), 0.0), "lexical" => true)
end

"Lexical (FTS) search of the docs index — matches a bare name/module fragment the embedding buries."
function _fts_docs(query::AbstractString; limit::Int = 20)
    # `qdrant_fts_search` was folded into `search_code` (mode="lexical", format="structured");
    # the structured hits carry name/text/score, which `_fts_record` reads.
    hits = try
        _kt_json(_kt(:search_code, Dict("collection" => _DOCS_COLLECTION, "query" => String(query),
                                        "limit" => limit, "mode" => "lexical", "format" => "structured")))
    catch
        return Dict{String,Any}[]   # FTS unavailable (old Kaimon / uncovered) → semantic-only
    end
    hits isa AbstractVector || return Dict{String,Any}[]
    return Dict{String,Any}[_fts_record(h) for h in hits]
end

"Hybrid docs search: lexical (FTS name/substring) ∪ semantic (vector), lexical floated, deduped."
function search_docs(query::AbstractString; limit::Int = 8)
    _agent_available() || return Dict{String,Any}[]
    q = strip(String(query)); isempty(q) && return Dict{String,Any}[]
    lex = _fts_docs(q)
    sem = _semantic_docs(q; limit = limit)
    seen = Set{Tuple{String,String}}(); out = Dict{String,Any}[]
    for d in Iterators.flatten((lex, sem))           # lexical first → name matches outrank pure-semantic
        k = (string(d["module"]), string(d["name"])); k in seen && continue
        push!(seen, k); push!(out, d)
    end
    return first(out, max(limit, min(length(lex), 12)))   # keep lexical hits; cap the tail
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
const _DOC_SCHEMA = "2"   # bump when the indexed payload shape changes → forces a one-time re-harvest
                          # (schema 2 added the `text` payload that Kaimon's FTS index needs)
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

"Background auto-index: project deps (eager) ∪ packages the cells use, version-cached."
function _autoindex!(nb::LiveNotebook)
    _agent_available() || return nothing
    Threads.@spawn try
        _doc_cache_load()
        want = Dict{String,String}()
        for d in (try; ReportEngine.project_deps(nb.kernel, nb.report); catch; Dict{String,Any}[]; end)
            n = string(get(d, "name", "")); isempty(n) || (want[n] = string(get(d, "version", "")))
        end
        for u in _used_packages(nb.report); haskey(want, u) || (want[u] = ""); end
        pending = String[n for (n, v) in want if get(_DOC_CACHE, n, nothing) != v]
        isempty(pending) && return
        recs = ReportEngine.harvest_docs(nb.kernel, nb.report, pending)
        index_docs!(recs)
        # Mirror the new `text` payloads into Kaimon's FTS index (the plain upsert path doesn't),
        # so lexical name/substring search works. Idempotent; best-effort if FTS is unavailable.
        try; _kt(:qdrant_ensure_fts_coverage, Dict("collection" => _DOCS_COLLECTION)); catch; end
        for n in pending; _doc_cache_put!(n, get(want, n, "")); end
        @info "slate: auto-indexed docs" notebook = nb.id packages = pending symbols = length(recs)
    catch e
        @warn "slate: auto-index failed" exception = (e, catch_backtrace())
    end
    return nothing
end

