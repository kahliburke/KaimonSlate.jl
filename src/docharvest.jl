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

# Case-insensitive resolution of a bare identifier against the names visible in `where`: the module's own
# bindings PLUS the exports of every module it has `using`'d / `import`ed (the module binding itself is in
# scope, so its exports are reachable). Exact case wins; otherwise the unique (sorted-first) case-insensitive
# match. Returns the canonical name, or `nothing` if there's no case-insensitive match. Used only as a
# fallback when the exact-case lookup misses (e.g. `regionplan` → `RegionPlan`).
function _ci_resolve_name(where::Module, nm::AbstractString)
    Symbol(nm) in names(where; all = true, imported = true) && return nm   # exact case takes priority
    target = lowercase(nm)
    cands = Set{Symbol}()
    for s in names(where; all = true, imported = true)
        push!(cands, s)
        (isdefined(where, s) && (v = try getfield(where, s) catch; nothing end) isa Module) || continue
        for e in names(v); push!(cands, e); end
    end
    Symbol(nm) in cands && return nm
    matches = sort!(String[string(s) for s in cands if lowercase(string(s)) == target])
    return isempty(matches) ? nothing : first(matches)
end

"""
    module_help(where, name) -> Dict

Resolve `name` in module `where` (the package must already be `using`'d / `import`ed
there) and return a help record: `{name, module, doc, kind, exports}`. `kind` is
"module", "function", "type", "const", or "unknown". For a Module, `exports` lists
its exported bindings as `{name, kind}` (sorted) for drill-down; empty otherwise.
`doc` is the raw `@doc` text (markdown). Pure (Base.Docs + reflection only) so it
loads into the dependency-light worker, exactly like `harvest_module_docs`.

A bare identifier that doesn't resolve is retried case-insensitively (exact case still
wins), so `regionplan` finds `RegionPlan` — see `_ci_resolve_name`.
"""
function module_help(where::Module, name::AbstractString)
    nm = String(name)
    ex = try; Meta.parse(nm); catch; nothing; end
    val = ex === nothing ? nothing : (try; Core.eval(where, ex); catch; nothing; end)
    # Wrong-case bare name (no dots) that missed → re-resolve to the correctly-cased binding, if unique.
    if val === nothing && occursin(r"^[A-Za-z_][A-Za-z0-9_!]*$", nm)
        canon = _ci_resolve_name(where, nm)
        canon === nothing || canon == nm || return module_help(where, canon)
    end
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
