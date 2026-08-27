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
# Is this "docstring" actually the renderer saying there ISN'T one?
#
# Three wordings all mean the same thing and all have to be recognised: `@doc` answers "No
# documentation found" for a binding and "No docstring found" for a module, and a package that stubs
# its types emits "No docstring defined". Indexing one of these as documentation adds an entry that
# matches nothing a reader would search for while occupying a result slot.
const _DOC_PLACEHOLDERS = ("No documentation found", "No docstring found", "No docstring defined")

function _is_placeholder_doc(doc::AbstractString)
    # The placeholder need not come first: a stubbed type renders as its signature line and then the
    # placeholder. So drop the parts that carry no prose — fenced blocks, and lines that are only a
    # bold or inline-code signature — and judge what is left.
    body = String[]
    infence = false
    for l in split(String(doc), '\n')
        t = strip(l)
        startswith(t, "```") && (infence = !infence; continue)
        infence && continue
        isempty(t) && continue
        # a signature-only line: `**`Foo <: Bar`**` or `Foo(x)` in backticks, nothing else
        (startswith(t, "**") && endswith(t, "**")) && continue
        (startswith(t, "`") && endswith(t, "`")) && continue
        push!(body, t)
    end
    isempty(body) && return false                      # only a signature: thin, but not a placeholder
    return any(p -> startswith(first(body), p), _DOC_PLACEHOLDERS)
end

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
            (isempty(doc) || _is_placeholder_doc(doc)) && continue
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
    _is_placeholder_doc(doc) && (doc = "")        # undocumented / undefined → no doc, in any wording
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
    # A binding that RESOLVED but carries no docstring is a different answer from one that isn't
    # there, and the caller needs to tell them apart. Undocumented is the common case in real code, so
    # answer with what reflection knows: what it is, and for anything callable its signatures, which is
    # most of what a docstring would have said anyway.
    src = isempty(doc) ? "none" : "docstring"
    if isempty(doc) && val !== nothing
        doc = _reflected_doc(nm, val, _kind(val))
        isempty(doc) || (src = "reflection")
    end
    return Dict{String,Any}("name" => nm, "module" => modname,
                            "doc" => doc, "kind" => _kind(val), "exports" => exports,
                            # Whether `doc` is the author's or ours, so a caller can present it as
                            # the fallback it is rather than passing it off as documentation.
                            "docsource" => src)
end

const _REFLECT_MAX_METHODS = 12

# What reflection can say about an undocumented binding. Markdown, so it renders through the same
# path a docstring does.
function _reflected_doc(nm::AbstractString, val, kind::AbstractString)
    io = IOBuffer()
    if kind == "function"
        ms = try; collect(methods(val)); catch; Any[]; end
        n = length(ms)
        print(io, "`", nm, "` is a function with ", n, n == 1 ? " method" : " methods",
              ", and no docstring.\n")
        if n > 0
            print(io, "\n```\n")
            for m in first(ms, _REFLECT_MAX_METHODS)
                # The signature only: a file:line here would point into the package's source, which
                # the reader of a notebook cannot open.
                print(io, first(split(string(m), " @ "; limit = 2)), "\n")
            end
            n > _REFLECT_MAX_METHODS && print(io, "… and ", n - _REFLECT_MAX_METHODS, " more\n")
            print(io, "```\n")
        end
    elseif kind == "type"
        print(io, "`", nm, "` is a type, and has no docstring.\n")
        fs = try; fieldnames(val); catch; (); end
        if !isempty(fs)
            print(io, "\n```\n")
            for f in fs
                t = try; string(fieldtype(val, f)); catch; "Any"; end
                print(io, f, "::", t, "\n")
            end
            print(io, "```\n")
        end
    else
        print(io, "`", nm, "` is a `", (try; string(typeof(val)); catch; kind; end),
              "`, and has no docstring.\n")
    end
    return String(take!(io))
end
