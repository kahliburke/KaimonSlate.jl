# Docstring harvesting for semantic docs search — SHARED by the in-process kernel
# (ReportEngine) and the gate worker (SlateWorker), so docs are extracted wherever
# the notebook's packages are actually loaded (the worker for project notebooks).
# Pure (Base.Docs only), so it loads cleanly into the dependency-light worker.

"""
    harvest_module_docs(where, mod_names) -> Vector{Dict}

For each module named in `mod_names` (resolved in module `where`, so a notebook must
have `using Foo` first), collect `{module, name, doc}` for every documented exported
binding. The docstring already carries the signature, so it isn't extracted apart.
"""
function harvest_module_docs(where::Module, mod_names)
    recs = Dict{String,Any}[]
    seen = Set{Tuple{String,String}}()
    for nm in mod_names
        m = try
            Core.eval(where, Meta.parse(String(nm)))
        catch
            nothing
        end
        m isa Module || continue
        mod_name = string(nameof(m))
        for s in names(m)                          # exported names
            isdefined(m, s) || continue
            key = (mod_name, string(s))
            key in seen && continue
            doc = try
                strip(string(Core.eval(m, :(@doc($s)))))   # canonical doc lookup (what `@doc sym` does)
            catch
                ""
            end
            (isempty(doc) || occursin("No documentation found", doc)) && continue
            push!(seen, key)
            push!(recs, Dict{String,Any}("module" => mod_name, "name" => string(s), "doc" => doc))
        end
    end
    return recs
end

"""
    search_module_names(where, mod_names, query; limit=20) -> Vector{Dict}

Local lexical doc search: case-insensitive substring match of `query` against the EXPORTED names
of each module in `mod_names` (resolved in `where`), ranked exact > prefix > substring (shorter
names first). Docstrings are fetched only for the returned (capped) matches, so it's cheap enough
to run per-keystroke with no index. The standalone stand-in for the Qdrant FTS search when no
embedding/index service (Kaimon) is available — restores partial-name matching. Pure (reflection +
`Base.Docs`), so it also loads into the dependency-light worker.
"""
function search_module_names(where::Module, mod_names, query::AbstractString; limit::Int = 20)
    q = lowercase(strip(String(query)))
    isempty(q) && return Dict{String,Any}[]
    hits = Tuple{Int,String,String,Symbol,Module}[]   # (score, modname, name, sym, module)
    seen = Set{Tuple{String,String}}()
    for nm in mod_names
        m = try; Core.eval(where, Meta.parse(String(nm))); catch; nothing; end
        m isa Module || continue
        mn = string(nameof(m))
        for s in names(m)
            isdefined(m, s) || continue
            ls = lowercase(string(s))
            occursin(q, ls) || continue
            key = (mn, string(s)); key in seen && continue; push!(seen, key)
            score = ls == q ? 3 : startswith(ls, q) ? 2 : 1
            push!(hits, (score, mn, string(s), s, m))
        end
    end
    sort!(hits; by = h -> (-h[1], length(h[3]), h[3]))   # score desc, shorter first, then alpha
    out = Dict{String,Any}[]
    for (score, mn, name, sym, m) in first(hits, limit)
        doc = try; strip(string(Core.eval(m, :(@doc($sym))))); catch; ""; end
        occursin("No documentation found", doc) && (doc = "")
        push!(out, Dict{String,Any}("module" => mn, "name" => name, "doc" => doc,
                                    "score" => score, "lexical" => true))
    end
    return out
end

"""
    module_help(where, name) -> Dict

Resolve `name` in module `where` (the package must already be `using`'d / `import`ed
there) and return a help record: `{name, module, doc, kind, exports}`. `kind` is
"module", "function", "type", "const", or "unknown". For a Module, `exports` lists
its exported bindings as `{name, kind}` (sorted) for drill-down; empty otherwise.
`doc` is the raw `@doc` text (markdown). Pure (Base.Docs + reflection only) so it
loads into the dependency-light worker, exactly like `harvest_module_docs`.
"""
function module_help(where::Module, name::AbstractString)
    nm = String(name)
    ex = try; Meta.parse(nm); catch; nothing; end
    val = ex === nothing ? nothing : (try; Core.eval(where, ex); catch; nothing; end)
    _kind(v) = v isa Module ? "module" :
               v isa Type ? "type" :
               (v isa Function || v isa Base.Callable) ? "function" :
               v === nothing ? "unknown" : "const"
    doc = ex === nothing ? "" : (try; strip(string(Core.eval(where, :(@doc($ex))))); catch; ""; end)
    occursin("No documentation found", doc) && (doc = "")        # undocumented / undefined → no doc
    exports = Dict{String,Any}[]
    modname = ""
    if val isa Module
        modname = string(nameof(val))
        self = nameof(val)
        for s in sort!(names(val); by = string)
            (s === self || !isdefined(val, s)) && continue
            v = try; getfield(val, s); catch; nothing; end
            push!(exports, Dict{String,Any}("name" => string(s), "kind" => _kind(v)))
        end
    elseif val !== nothing
        modname = try; string(parentmodule(val)); catch; ""; end
    end
    return Dict{String,Any}("name" => nm, "module" => modname,
                            "doc" => doc, "kind" => _kind(val), "exports" => exports)
end
