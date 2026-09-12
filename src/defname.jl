# Extract the defined name from a top-level definition Expr — shared by the worker's hot-reload
# change detector (worker.jl) and its unit test (test/test_defname.jl). Pure, dependency-free.
#
# Best-effort across the forms Julia parsing AND Revise produce: short-form/`function`/`where`/
# return-typed defs, structs (incl. parametric / `<: Super`), abstract & primitive types, consts,
# macros, and — crucially — the wrappers Revise stores defs in: a `:macrocall` (docstrings,
# `@inline foo()=…`) and a `:block` (`begin <LineNumberNode> def end`, e.g. consecutive bare
# one-liners). Returns the name `String`, or `nothing` for non-definitions. Over/under-matching
# only affects which cells are flagged stale on a /src edit, never correctness.

# Name out of a "name position" expr: a Symbol, `Foo{T}` (curly), `Foo <: Bar` (<:), or a
# qualified `Mod.foo` (take the last component).
_name_str(x) = x isa Symbol ? string(x) :
    x isa QuoteNode ? _name_str(x.value) :                       # `Mod.foo` → .args[end] is QuoteNode(:foo)
    (x isa Expr ? (x.head === :curly ? _name_str(x.args[1]) :
                   x.head === :(<:) ? _name_str(x.args[1]) :
                   x.head === :(.)  ? _name_str(x.args[end]) : nothing) : nothing)

# Name out of a function signature: `f`, `f(args)` (call), `f(args) where T` (where),
# `f(args)::Ret` (return-typed), or a bare `x` (a plain `x = …` global assignment).
_sig_name(sig) = sig isa Symbol ? string(sig) :
    (sig isa Expr ? (sig.head === :call ? _name_str(sig.args[1]) :
                     sig.head === :where || sig.head === :(::) ? _sig_name(sig.args[1]) : nothing) : nothing)

function _def_name(ex)
    ex isa Expr || return nothing
    h = ex.head
    h === :function || h === :(=)            ? _sig_name(ex.args[1]) :
    h === :struct                            ? _name_str(ex.args[2]) :
    (h === :abstract || h === :primitive)    ? _name_str(ex.args[1]) :
    h === :macro                             ? (n = _sig_name(ex.args[1]); n === nothing ? nothing : "@" * n) :
    h === :const && !isempty(ex.args)        ? (a = ex.args[1]; _name_str(a isa Expr && a.head === :(=) ? a.args[1] : a)) :
    # Revise wraps some defs as `begin <LineNumberNode> def end` (:block) or with a docstring /
    # macro (:macrocall) — recurse into the children to find the inner def's name.
    (h === :macrocall || h === :block)       ? findfirst_def(ex.args) :
    nothing
end
# First non-nothing def name among a list of child exprs (skips LineNumberNodes / strings / etc.).
findfirst_def(args) = (for a in args; r = _def_name(a); r === nothing || return r; end; nothing)

# LineNumberNode-free copy, so an edit that only shifts line numbers doesn't read as a change
# (used to body-hash a def for change-granular hot-reload — see worker.jl `_file_defs`, and to
# normalise a sweep body before it is stringified — see sweep.jl `@sweep`).
#
# A `:macrocall`'s SECOND argument is positional, not decoration: `@f x` parses as
# `(:macrocall, :@f, <line>, :x)`, and everything that reads or prints one takes args[3:end] as the
# arguments. Dropping the line node there shifts them left, so `@sfile "x.h5"` deparses to a bare
# `@sfile` — a macro call silently losing its arguments. `nothing` is the canonical placeholder
# (it is what hand-built macrocalls use) and carries no line information, so it normalises the same.
_strip_lines(x) = x
function _strip_lines(ex::Expr)
    if ex.head === :macrocall && length(ex.args) >= 2
        return Expr(ex.head, _strip_lines(ex.args[1]), nothing,
                    Any[_strip_lines(a) for a in ex.args[3:end] if !(a isa LineNumberNode)]...)
    end
    return Expr(ex.head, Any[_strip_lines(a) for a in ex.args if !(a isa LineNumberNode)]...)
end

# VERBATIM source of each top-level statement, sliced by the line spans `Meta.parseall` recorded.
#
# Deparsing (`string(expr)`) is not a substitute, and quietly so: it does not round-trip. A
# comprehension with a filter over several iterators comes back as `$(Expr(:filter, …))`, which no
# parser will take — so a definition containing one cannot be re-read from its deparse at all. Text
# that is going to be shipped somewhere and run has to be the text the author wrote.
#
# Trailing blank and comment-only lines are dropped, because they belong to whatever comes next: a
# comment written under a definition would otherwise count as part of it, and anything keyed on this
# text would change when it was edited.
function stmt_texts(source::AbstractString, ast)
    (ast isa Expr && ast.head === :toplevel) || return String[]
    lines = split(String(source), '\n'; keepempty = true)
    starts = Int[]
    at = 0
    for a in ast.args
        a isa LineNumberNode ? (at = a.line) : push!(starts, at == 0 ? 1 : at)
    end
    out = String[]
    for (i, s) in enumerate(starts)
        stop = i < length(starts) ? starts[i + 1] - 1 : length(lines)
        lo = clamp(s, 1, length(lines))
        hi = clamp(stop, lo, length(lines))
        while hi > lo
            t = strip(lines[hi])
            (isempty(t) || startswith(t, "#")) || break
            hi -= 1
        end
        push!(out, rstrip(join(lines[lo:hi], "\n")))
    end
    return out
end

# Walk a parsed file (a :toplevel Expr) into (def-name → body-hash), recursing into (sub)modules
# so a def INSIDE a submodule (e.g. `Sub.greet`) is captured under its leaf name — matching how
# cells read it (leaf-aware change matching, server side). `_def_name` already unwraps the
# :block / :macrocall / docstring wrappers Julia & Revise produce.
function _collect_defs!(d::Dict{String,UInt64}, ex)
    ex isa Expr || return d
    if ex.head === :toplevel || ex.head === :block
        for a in ex.args; _collect_defs!(d, a); end
    elseif ex.head === :module
        _collect_defs!(d, ex.args[3])                       # module Name <block>
    else
        nm = _def_name(ex)
        if nm !== nothing
            # FOLD, don't overwrite: several methods of one function (or a type plus its constructors)
            # share a name, and assigning here would keep only the last one — an edit to any earlier
            # method would then hash identically, so it would raise no hot-reload banner AND leave the
            # memo key unchanged, restoring a cached result computed from the old code.
            d[nm] = hash(_strip_lines(ex), get(d, nm, UInt64(0)))
        elseif ex.head === :macrocall
            # A DOCUMENTED module parses as `@doc "…" module M … end`, so the `:module` branch above
            # never sees it and every definition inside is lost. Most packages document their top
            # module, which made this return NOTHING for their main file — the digest then depended
            # only on the file's path, so editing any function in it changed nothing that watches.
            # `_def_name` already unwraps a docstring'd FUNCTION, so we only get here for the wrappers
            # it does not treat as definitions.
            for a in ex.args
                a isa Expr && a.head in (:module, :block, :toplevel) && _collect_defs!(d, a)
            end
        end
    end
    return d
end

# ── Digesting a source tree ───────────────────────────────────────────────────────────────────
# "Has the code changed?" — asked by two callers with the same requirements, so it lives here with
# the def extractor it is built on rather than being written twice.
#
#   • the memo layer, to invalidate a cached cell when a function it calls was edited;
#   • the batch fabric, to re-provision a cluster's task environment (and re-key its sweeps) when
#     the package the units call into was edited.
#
# By DEFINITION BODY, not file bytes: reformatting or a comment must not invalidate anything. That
# is merely nice for the memo cache and important for a cluster, where a spurious change costs an
# copy, an instantiate and a precompile across the whole allocation.
#
# HOST-PORTABLE: a file is keyed by its path RELATIVE to the src root it was found under, never the
# absolute path — the same tree lives at /Users/… locally and elsewhere on a compute node, and an
# absolute path would fork the digest and make every transferred entry unfindable.

"(def-name → body-hash) for one source file, parsed fresh from disk."
function file_defs(path::AbstractString)
    d = Dict{String,UInt64}()
    isfile(path) || return d
    src = try; read(path, String); catch; return d; end
    top = try; Meta.parseall(src); catch; return d; end
    return _collect_defs!(d, top)
end

"Every `.jl` file under `dirs`, deterministically ordered."
function src_tree_files(dirs)
    files = String[]
    for dir in dirs
        isdir(dir) || continue
        for (root, _, fs) in walkdir(dir), f in fs
            endswith(f, ".jl") && push!(files, joinpath(root, f))
        end
    end
    return sort!(unique!(files))
end

"""
    src_tree_digest(dirs) -> UInt

A hash of the definitions under `dirs`. `SRC_DIGEST_EMPTY` when there is nothing to digest, so the
answer is deterministic rather than accidentally zero.
"""
const SRC_DIGEST_EMPTY = UInt(0x53726300)

function src_tree_digest(dirs)
    h = SRC_DIGEST_EMPTY
    try
        entries = Tuple{String,UInt}[]
        for dir in dirs
            isdir(dir) || continue
            for (root, _, fs) in walkdir(dir), f in fs
                endswith(f, ".jl") || continue
                p = joinpath(root, f)
                defs = file_defs(p)
                dh = UInt(0)
                for k in sort!(collect(keys(defs))); dh = hash((k, defs[k]), dh); end
                push!(entries, (relpath(p, dir), dh))
            end
        end
        sort!(entries)
        for e in entries; h = hash(e, h); end
    catch
    end
    return h
end
