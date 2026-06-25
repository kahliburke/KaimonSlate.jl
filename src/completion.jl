# Shared cell completion. Runs WHERE the bindings live — the engine module for the
# in-process kernel, the worker's `NB` namespace for a gate kernel — so identifiers from
# `using`'d packages and already-evaluated cells complete, not just `Base` globals. This is
# why it must be shared (engine + worker), exactly like `capture.jl`: the server process
# can't see a remote worker's bindings, so completion is forwarded to where they exist.
#
# Pure reflection: `REPLCompletions` + a guarded `getglobal` for the icon kind. No `@doc`
# eval (that's the lazy doc-preview's job), so this stays fast enough to run per keystroke.

import REPL

# Text to insert for a completion. `completion_text` throws on `BslashCompletion`
# (Julia ≥1.12 — the LaTeX/emoji `\pi`→π path), so fall back to the struct's symbol
# field. Robust across Julia versions: normal path first, field access on throw.
function _comp_text(c)
    try
        return REPL.REPLCompletions.completion_text(c)::AbstractString
    catch
        for f in (:completion, :name)               # BslashCompletion holds the symbol here
            hasproperty(c, f) && return String(getfield(c, f))
        end
        return ""
    end
end

# Refine a global binding into module/type/function/const for the completion icon. Cheap
# (a guarded `getglobal` — no `@doc`, no getproperty side effects). Undefined/erroring → "var".
function _binding_kind(parent::Module, name::AbstractString)
    sym = Symbol(name)
    (parent isa Module && isdefined(parent, sym)) || return "var"
    v = try; getglobal(parent, sym); catch; return "var"; end
    v isa Module ? "module" :
    v isa Type ? "type" :
    (v isa Function || v isa Base.Callable) ? "function" : "const"
end

# A dead generic-function stub: a name bound to a non-builtin Function with NO methods — e.g. a
# function whose only method Revise removed when its def was deleted from /src (Julia can't unbind
# the name, so it lingers as `f (generic function with 0 methods)`). Excludes builtins (whose
# `methods` is empty) so getfield/tuple/etc. aren't dropped. (Note: this also hides an intentional
# empty interface stub `function f end`, which is uncommon and still typeable.)
function _dead_stub(parent::Module, name::AbstractString)
    sym = Symbol(name)
    (parent isa Module && isdefined(parent, sym)) || return false
    v = try; getglobal(parent, sym); catch; return false; end
    return v isa Function && !(v isa Core.Builtin) && isempty(methods(v))
end

# Coarse kind for a completion → the UI's icon + ranking. Pure type-dispatch plus the
# binding refinement above; robust across Julia versions (unknown structs fall through).
function _comp_kind(c)
    RC = REPL.REPLCompletions
    c isa RC.ModuleCompletion           && return _binding_kind(c.parent, c.mod)
    c isa RC.KeywordCompletion          && return "keyword"
    c isa RC.KeywordArgumentCompletion  && return "kwarg"
    (c isa RC.PropertyCompletion || c isa RC.FieldCompletion) && return "field"
    c isa RC.MethodCompletion           && return "method"
    c isa RC.BslashCompletion           && return "latex"  # see latex_symbol below for name→char
    c isa RC.PathCompletion             && return "path"
    c isa RC.PackageCompletion          && return "module"
    (c isa RC.DictCompletion || c isa RC.KeyvalCompletion) && return "key"
    return "text"
end

# REPLCompletions strips kwarg TYPES from a method's signature text (it shows `freq, decay`).
# Recover them by reflection: the body method's signature is `(closure, kwtypes…, typeof(f),
# postypes…)`, so the kwarg types sit right after the closure in `kwarg_decl` order. Returns
# `name => type-string`; empty on any reflection failure (best-effort, version-tolerant).
function _kwarg_types(m::Method)
    out = Dict{Symbol,String}()
    try
        names = Base.kwarg_decl(m); isempty(names) && return out
        bf = Base.bodyfunction(m); bf === nothing && return out
        ps = first(methods(bf)).sig.parameters
        for (i, nm) in enumerate(names)
            j = 1 + i; j > length(ps) && continue
            ts = string(ps[j])
            ts == "Any" || (out[nm] = ts)          # an untyped (`::Any`) kwarg adds only noise — skip it
        end
    catch
    end
    return out
end

# Rewrite the `; …)` kwarg section of a method signature text, typing each bare kwarg name
# from `kt` (so `damped_wave(n::Integer; freq, decay)` → `…; freq::Real, decay::Real)`).
function _retype_kwargs(txt::AbstractString, kt::Dict{Symbol,String})
    isempty(kt) && return txt
    at = findfirst(" @ ", txt)
    sig = at === nothing ? txt : txt[1:prevind(txt, first(at))]
    tail = at === nothing ? "" : txt[first(at):end]
    semi = findfirst(';', sig); semi === nothing && return txt
    close = findlast(')', sig); (close === nothing || close < semi) && return txt
    pre = sig[1:semi]; kwseg = sig[nextind(sig, semi):prevind(sig, close)]
    typed = map(split(kwseg, ',')) do p
        nm = strip(split(strip(p), r"[=:]")[1]); t = get(kt, Symbol(nm), "")
        isempty(t) ? strip(p) : nm * "::" * t
    end
    return pre * " " * join(typed, ", ") * ")" * tail
end

"""
    latex_symbol(name) -> String

Resolve a LaTeX/emoji completion command (`"\\alpha"`, `"\\:smile:"`) to its character; `""` if
unknown. A PARTIAL latex query (`\\alph`) comes back from REPLCompletions as the NAME, not the
symbol — so the UI displays the name (it must, to filter by what the user typed) but resolves the
symbol via this to APPLY in one step (else accepting inserts the literal `\\alpha`).
"""
function latex_symbol(name::AbstractString)
    RC = REPL.REPLCompletions
    s = String(name)
    sym = get(RC.latex_symbols, s, "")
    (isempty(sym) && isdefined(RC, :emoji_symbols)) && (sym = get(RC.emoji_symbols, s, ""))
    return sym
end

"""
    slate_completions(mod, code, pos) -> (; items, from, to)

REPLCompletions against `mod` at byte offset `pos`. `items` is a `Vector{Tuple{String,String}}`
of `(text, kind)`; `from`/`to` are 0-based byte offsets of the range the completion replaces
(CodeMirror-ready). Returns a NamedTuple so it rides the gate wire to the server unchanged.
"""
function slate_completions(mod::Module, code::AbstractString, pos::Integer)
    s = String(code); p = clamp(Int(pos), 0, ncodeunits(s))
    items = Tuple{String,String}[]
    from = p; to = p
    try
        comps, range, _ = REPL.REPLCompletions.completions(s, p, mod)
        from = first(range) - 1; to = last(range)
        for c in comps
            t = _comp_text(c)
            isempty(t) && continue
            c isa REPL.REPLCompletions.ModuleCompletion && _dead_stub(c.parent, t) && continue
            k = _comp_kind(c)
            # A string-macro completion (`colorant"`, `r"`, …) — an identifier ending in a lone
            # `"` (not a quoted dict key, which starts with `"`). Tag it so the UI shows a proper
            # icon and auto-closes the quote instead of leaving a stray `"`.
            (endswith(t, '"') && !startswith(t, '"')) && (k = "str")
            k == "method" && (t = try; _retype_kwargs(t, _kwarg_types(c.method)); catch; t; end)
            push!(items, (t, k))
        end
    catch
    end
    return (items = items, from = from, to = to)
end
