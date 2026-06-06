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
