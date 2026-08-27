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

# Ensure the docs collection exists. Returns `true` when the collection is ready to
# index into, `false` when Qdrant is unreachable (so callers skip quietly).
# `qdrant_collection_exists` returns a native Bool over the service endpoint when Qdrant
# is up; when it's DOWN the tool returns a human-readable error STRING ("Qdrant is not
# reachable…"). Read the result directly (no `_kt_json`) — parsing that error text as
# JSON is what threw the confusing `invalid JSON at byte position 1` crash. Any answer
# that isn't a clear true/false ⇒ backend unavailable ⇒ don't create/index against it.
function _ensure_docs_collection()::Bool
    ex = _kt(:qdrant_collection_exists, Dict("collection" => _DOCS_COLLECTION))
    (ex === true || ex == "true") && return true       # already exists
    (ex === false || ex == "false") || return false    # non-boolean ⇒ Qdrant down ⇒ skip
    _kt(:qdrant_create_collection, Dict("collection" => _DOCS_COLLECTION,
                                        "vector_size" => _DOCS_DIM, "distance" => "Cosine"))
    return true
end

# Stable positive id for a doc record (first 60 bits of its SHA-256 → fits Int).
_doc_id(s) = parse(Int, SlateHistory._sha(s)[1:15]; base = 16)

# A docstring is embedded in PIECES once it is long enough to be about several things.
#
# One vector has a fixed budget of meaning. A reference-grade docstring covers what a thing is, how to
# construct it, what each field means and how it behaves — and averaged into a single 1024-d vector,
# any one of those is a small component of the whole. A reader searching for the idea in the fourth
# paragraph is then competing against every other idea in the same docstring. Embedding per section
# gives each idea its own vector, and the symbol is recovered from the payload either way.
#
# Split on blank lines with fenced blocks kept whole, then packed greedily toward the target, so a
# chunk is a run of whole paragraphs rather than a cut at an arbitrary character.
const _DOC_CHUNK_MIN = 800       # shorter than this: one vector is plenty
const _DOC_CHUNK_TARGET = 600    # aim for chunks around this size
const _DOC_CHUNK_MAX = 6         # cap the embed calls one symbol can cost

function _doc_chunks(doc::AbstractString)
    s = strip(String(doc))
    (isempty(s) || length(s) <= _DOC_CHUNK_MIN) && return [s]
    blocks = String[]; cur = String[]; infence = false
    for l in split(s, '\n')
        t = strip(l)
        startswith(t, "```") && (infence = !infence)
        if isempty(t) && !infence
            isempty(cur) || (push!(blocks, join(cur, "\n")); empty!(cur))
        else
            push!(cur, l)
        end
    end
    isempty(cur) || push!(blocks, join(cur, "\n"))
    isempty(blocks) && return [s]
    chunks = String[]; buf = String[]; n = 0
    for b in blocks
        if n > 0 && n + length(b) > _DOC_CHUNK_TARGET
            push!(chunks, join(buf, "\n\n")); empty!(buf); n = 0
        end
        push!(buf, b); n += length(b)
    end
    isempty(buf) || push!(chunks, join(buf, "\n\n"))
    return length(chunks) > _DOC_CHUNK_MAX ? chunks[1:_DOC_CHUNK_MAX] : chunks
end

"Embed + upsert harvested doc records into the search index. Returns the count indexed."
function index_docs!(records)
    _agent_available() || return 0
    isempty(records) && return 0
    _ensure_docs_collection()
    n = 0
    for r in records
        modname = string(get(r, "module", "")); name = string(get(r, "name", ""))
        doc = string(get(r, "doc", "")); text = "$modname.$name\n$doc"
        chunks = _doc_chunks(doc)
        # Each chunk carries the qualified name so a match on a later paragraph still knows what it
        # is about. The first chunk's id is the id the whole record would have had, so re-indexing an
        # existing collection overwrites in place instead of leaving the old single point behind.
        for (ci, ch) in enumerate(chunks)
            vec = try; _embed(length(chunks) == 1 ? text : "$modname.$name\n$ch"); catch; continue; end
            pt = Dict("id" => _doc_id(ci == 1 ? text : string(text, " chunk", ci)), "vector" => vec,
                      # `text` (= "Module.name\ndoc") lets Kaimon's FTS index this point — trigram
                      # substring then matches a bare name/module fragment the embedding buries.
                      # `metadata.module` is what BOTH engines filter on for module scoping: Qdrant
                      # keys filters as `metadata.$field`; the FTS side reads json_extract(metadata,
                      # '$.module') — and backfill_fts! mirrors this `metadata` from the payload.
                      # The payload is the WHOLE record on every chunk: the viewer shows the full
                      # docstring however the reader arrived at it, and the lexical arm keeps matching
                      # a name or fragment anywhere in it. Only the vector is per-chunk.
                      "payload" => Dict("module" => modname, "name" => name, "doc" => doc,
                                        "text" => text, "metadata" => Dict("module" => modname)))
            try; _kt(:qdrant_upsert_points, Dict("collection" => _DOCS_COLLECTION, "points" => [pt])); catch; end
        end
        n += 1                                   # count SYMBOLS indexed, not vectors written
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
    # Over-fetch: a long docstring is indexed as several vectors (see `_doc_chunks`), so a symbol whose
    # every section matches would otherwise fill the page by itself. Asking for more and collapsing to
    # one row per symbol keeps `limit` meaning "distinct answers".
    args = Dict{String,Any}("collection" => _DOCS_COLLECTION, "query" => q, "mode" => "hybrid",
                            "format" => "structured", "embedding_model" => _DOCS_MODEL,
                            "limit" => limit * 4)
    isempty(modules) || (args["filters"] = Dict("module" => String[string(m) for m in modules]))
    hits = try
        _kt_json(_kt(:search_code, args))
    catch
        return Dict{String,Any}[]   # search index unavailable → no docs (caller falls back to lexical UI)
    end
    hits isa AbstractVector || return Dict{String,Any}[]
    return _drop_tail(first(_best_per_symbol(Dict{String,Any}[_doc_record(h) for h in hits]), limit))
end

# One row per symbol, keeping its best-scoring chunk, in descending score order. A symbol matched
# through several of its sections is one answer, not several.
function _best_per_symbol(recs::Vector{Dict{String,Any}})
    best = Dict{Tuple{String,String},Dict{String,Any}}()
    for r in recs
        k = (string(get(r, "module", "")), string(get(r, "name", "")))
        prev = get(best, k, nothing)
        (prev === nothing || Float64(get(r, "score", 0.0)) > Float64(get(prev, "score", 0.0))) &&
            (best[k] = r)
    end
    return sort!(collect(values(best)); by = r -> -Float64(get(r, "score", 0.0)))
end

# How far below the best hit a result may score and still be worth showing.
#
# The backend returns `limit` hits whatever the query, so a page is always full whether or not
# anything matched. Relative rather than an absolute cutoff on purpose: the fused score's scale
# depends on the backend and the corpus, so a constant tuned against one index would silently hide
# real answers on another. This only ever removes a tail the top hit already beats by more than half.
const _DOC_TAIL_RATIO = 0.45

function _drop_tail(recs::Vector{Dict{String,Any}})
    isempty(recs) && return recs
    best = maximum(Float64(get(r, "score", 0.0)) for r in recs)
    best > 0 || return recs
    return Dict{String,Any}[r for r in recs if Float64(get(r, "score", 0.0)) >= _DOC_TAIL_RATIO * best]
end

"""
    doc_summary(doc; lines = 4) -> String

The part of a docstring worth showing in a RESULT LIST: its prose, not its signature.

A Julia docstring conventionally opens with its signature, which `@doc` renders as a fenced block.
In a result list the signature is the least useful part: it restates what the reader typed, while the
prose is what tells them whether this is the symbol they want.

Skips one leading fenced block, then takes the first `lines` non-blank lines of what follows. A
docstring that is only a signature falls back to that signature rather than to nothing.
"""
function doc_summary(doc::AbstractString; lines::Int = 4)
    s = strip(String(doc))
    isempty(s) && return ""
    ls = split(s, '\n')
    i = 1
    if startswith(strip(ls[1]), "```")                     # leading signature fence → skip past it
        j = findnext(l -> startswith(strip(l), "```"), ls, 2)
        j === nothing || (i = j + 1)
    end
    while i <= length(ls) && isempty(strip(ls[i]))         # …and any blank line after it
        i += 1
    end
    body = i <= length(ls) ? ls[i:end] : String[]
    isempty(filter(l -> !isempty(strip(l)), body)) && return join(first(ls, min(lines, length(ls))), "\n")
    return join(first(body, min(lines, length(body))), "\n")
end

# A docstring (markdown) → safe HTML for the help viewer. Empty in → empty out.
_doc_esc(s) = replace(String(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;")
_doc_html(doc) = (s = strip(String(doc)); isempty(s) ? "" : (try; markdown_html(s); catch; "<pre>" * _doc_esc(s) * "</pre>"; end))

# Live help lookup for `name` (a binding or module), resolved where cells eval. Returns the
# module_help record + a rendered `docHtml`. Powers the docs palette's ?Module drill-down +
# cross-reference links. Best-effort: a missing kernel/binding yields an empty-ish record.
function help_lookup(nb::LiveNotebook, name::AbstractString)
    # A Slate helper (echart, @bind, Checkbox, animate, …) is documented in the SLATE_API registry, not
    # as a package docstring — resolve it there FIRST so drill-down / "Related" chips show the real doc
    # instead of "No documentation found" (the injected constructor/macro carries no docstring).
    e = slate_api_entry(name)
    if e !== nothing
        doc = _entry_markdown(e)
        return Dict{String,Any}("name" => e.name, "module" => "Slate", "kind" => "slate",
                                "doc" => doc, "exports" => Dict{String,Any}[], "docHtml" => _doc_html(doc))
    end
    # An ECharts option path (e.g. `yAxis.type`) — resolve from the curated registry, not a live binding.
    ec = echarts_doc_entry(name)
    if ec !== nothing
        return Dict{String,Any}("name" => ec.path, "module" => "ECharts", "kind" => "echarts",
                                "doc" => ec.doc, "exports" => Dict{String,Any}[], "docHtml" => _doc_html(ec.doc))
    end
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
# Keys (package names / "Slate" / "ECharts") with a harvest IN FLIGHT. The version cache is only
# written AFTER a harvest completes, so without this a re-trigger during a slow harvest (e.g. a huge
# Makie doc set) sees the same packages still "pending" and spawns ANOTHER overlapping harvest — they
# pile up, each re-parsing the same docstrings, pegging every thread. Single-flight per key fixes that.
const _INDEXING = Set{String}()
const _DOC_SCHEMA = "5"   # bump when the indexed payload shape changes → forces a one-time re-harvest
                          # (schema 2 added the `text` payload that Kaimon's FTS index needs;
                          #  schema 3 added the `metadata.module` payload that module-scoped filters read;
                          #  schema 4 excludes "no docstring" placeholders;
                          #  schema 5 embeds a long docstring per section rather than whole, so an
                          #  existing collection needs the extra per-chunk vectors written)
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
const _UNIVERSAL_MODULES = String["Base", "Core", "Slate", "ECharts"]   # Slate = injected helpers; ECharts = curated option docs (echart is always available)

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

# The cache key for one dependency's docs: what has to change before its docstrings are re-harvested.
#
# A registry dep's version answers that exactly. A `dev`'d one does not: its version is whatever its
# Project.toml says and holds still across edits — and that is precisely the package whose docstrings
# are most likely to be moving, since it is the one being written.
#
# So a path dep is keyed on a signature of its source instead: name, size and mtime of every `.jl`
# under `src/`. Cheap (a stat per file, no reads) and it moves whenever an edit does. `Slate` and
# `ECharts` key on a content hash for the same reason.
function _dep_doc_version(d::AbstractDict)
    ver = string(get(d, "version", ""))
    string(get(d, "source", "")) == "path" || return ver
    dir = string(get(d, "origin", ""))
    (isempty(dir) && return ver)
    src = joinpath(dir, "src")
    isdir(src) || return ver
    h = zero(UInt64)
    try
        for (root, _, files) in walkdir(src), f in files
            endswith(f, ".jl") || continue
            p = joinpath(root, f)
            st = stat(p)
            h = hash((relpath(p, src), st.size, st.mtime), h)
        end
    catch
        return ver          # unreadable tree → fall back to the version rather than re-index forever
    end
    return string(ver, "+src", string(h; base = 16))
end

"Background auto-index: project deps (eager) ∪ packages the cells use, version-cached."
# Auto-indexing is a background SERVICE (agent doc-search). A standalone/BYOC run brings Kaimon in
# only as the compute gate — it shouldn't fire this (a viewer opening a notebook shouldn't trigger a
# giant package doc-harvest). `KAIMONSLATE_NO_AUTOINDEX=1` turns it off; run.jl sets it.
_autoindex_enabled() = get(ENV, "KAIMONSLATE_NO_AUTOINDEX", "0") != "1"

function _autoindex!(nb::LiveNotebook)
    (_agent_available() && _autoindex_enabled()) || return nothing
    Threads.@spawn begin
        claimed = String[]                                 # keys this task owns; released in `finally`
        try
            _doc_cache_load()
            # What needs (re)indexing: Slate helpers + ECharts DSL (version-cached on content hash),
            # plus the notebook's project deps and any package a cell `using`s.
            want = Dict{String,String}("Slate" => slate_api_version(), "ECharts" => echarts_docs_version())
            for d in (try; ReportEngine.project_deps(nb.kernel, nb.report); catch; Dict{String,Any}[]; end)
                n = string(get(d, "name", "")); isempty(n) && continue
                want[n] = _dep_doc_version(d)
            end
            for u in _used_packages(nb.report); haskey(want, u) || (want[u] = ""); end
            # CLAIM only the stale keys that no concurrent harvest already owns (single-flight) — so a
            # re-trigger during a slow harvest can't spawn a second pass over the same docstrings.
            lock(_DOC_CACHE_LOCK) do
                for (k, v) in want
                    (get(_DOC_CACHE, k, nothing) != v && !(k in _INDEXING)) && (push!(claimed, k); push!(_INDEXING, k))
                end
            end
            isempty(claimed) && return
            if "Slate" in claimed
                ns = index_docs!(slate_api_records())
                ns == 0 || (ensure_docs_fts!(); _doc_cache_put!("Slate", slate_api_version()))
            end
            if "ECharts" in claimed
                ne = index_docs!(echarts_doc_records())
                ne == 0 || (ensure_docs_fts!(); _doc_cache_put!("ECharts", echarts_docs_version()))
            end
            pkgs = String[k for k in claimed if k != "Slate" && k != "ECharts"]
            if !isempty(pkgs)
                recs = ReportEngine.harvest_docs(nb.kernel, nb.report, pkgs)
                index_docs!(recs)
                ensure_docs_fts!()   # mirror the new text+metadata payloads into the FTS index
                for n in pkgs; _doc_cache_put!(n, get(want, n, "")); end
                @info "slate: auto-indexed docs" notebook = nb.id packages = pkgs symbols = length(recs)
            end
        catch e
            @warn "slate: auto-index failed" exception = (e, catch_backtrace()) maxlog = 5
        finally
            isempty(claimed) || lock(_DOC_CACHE_LOCK) do; setdiff!(_INDEXING, claimed); end
        end
    end
    return nothing
end

