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

# True when `name` is a global OWNED by the notebook namespace `mod` — a binding the reader made
# in a cell, NOT a name reached through `using` (Base / a package). `binding_module` returns the
# module a binding is defined in: for the reader's own `df = …` that's `mod`; for an imported `sin`
# it's `Base`. Guarded — an odd/undefined binding just isn't "owned". Used to FAVOR the reader's own
# variables in the completion popup (they rank with cell-locals, above library symbols).
function _owned_by(mod::Module, name::AbstractString)
    sym = Symbol(name)
    try
        return isdefined(mod, sym) && Base.binding_module(mod, sym) === mod
    catch
        return false
    end
end

# A dead generic-function stub: a name bound to a non-builtin Function with NO methods — e.g. a
# function whose only method Revise removed when its def was deleted from /src (Julia can't unbind
# the name, so it lingers as `f (generic function with 0 methods)`). Excludes builtins (whose
# `methods` is empty) so getfield/tuple/etc. aren't dropped. (Note: this also hides an intentional
# empty interface stub `function f end`, which is uncommon and still typeable.)
# Is the completion being asked for AFTER a dot (`Mod.foo`) rather than for a bare identifier?
# Scan back over the identifier being typed and look at what precedes it.
function _is_dotted(s::AbstractString, p::Integer)
    cu = codeunits(s); i = Int(p)
    isid(b) = (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) ||
              (UInt8('0') <= b <= UInt8('9')) || b == UInt8('_') || b == UInt8('!')
    while i > 0 && isid(cu[i]); i -= 1; end
    return i >= 1 && cu[i] == UInt8('.')
end

# For `Mod.<tab>`, is `name` part of what `Mod` actually offers?
#
# `names(M; all=true, imported=true)` — what REPLCompletions enumerates — also returns everything M
# reached through its OWN `using Base`. For a small module that is two of its own functions against
# roughly eleven hundred inherited ones, so the names someone opened `Mod.` to find sort in past
# every operator in Base. True for what M defines and what M exports (the latter so a module that
# re-exports another package's API, via Reexport or plain `export`, still counts as offering it).
# These are ordered FIRST rather than filtered, so `Mod.sin` stays reachable, just not in the way.
# Anything we cannot judge counts as API: mis-sorting a name is cheaper than burying it.
function _module_api(parent::Module, name::AbstractString)
    # `_comp_text` renders a macro as `@foo` and a STRING macro as `foo"`, but the binding behind the
    # latter is `@foo_str` — without this the lookup below can't resolve one and every inherited
    # string macro counts as API.
    sym = endswith(name, '"') && !startswith(name, '"') ? Symbol("@", chop(name), "_str") : Symbol(name)
    try
        isdefined(parent, sym) || return true
        Base.binding_module(parent, sym) === parent && return true      # defined here
        Base.isexported(parent, sym) && return true                     # re-exported here
        return isdefined(Base, :ispublic) ? Base.ispublic(parent, sym) : false
    catch
        return true
    end
end

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
    dotted = _is_dotted(s, p)
    # `Mod.<tab>` should lead with what Mod provides rather than everything Mod itself imported.
    # Inherited names go to `tail` and are appended after, which the route's stable re-rank then
    # preserves within a kind tier. Only for a DOTTED completion into some OTHER module: a bare
    # identifier resolves in the notebook's own namespace, where inherited Base names are the point.
    tail = Tuple{String,String}[]
    try
        comps, range, _ = REPL.REPLCompletions.completions(s, p, mod)
        from = first(range) - 1; to = last(range)
        for c in comps
            t = _comp_text(c)
            isempty(t) && continue
            c isa REPL.REPLCompletions.ModuleCompletion && _dead_stub(c.parent, t) && continue
            demote = dotted && c isa REPL.REPLCompletions.ModuleCompletion &&
                     c.parent !== mod && !_module_api(c.parent, t)
            k = _comp_kind(c)
            # A string-macro completion (`colorant"`, `r"`, …) — an identifier ending in a lone
            # `"` (not a quoted dict key, which starts with `"`). Tag it so the UI shows a proper
            # icon and auto-closes the quote instead of leaving a stray `"`.
            (endswith(t, '"') && !startswith(t, '"')) && (k = "str")
            k == "method" && (t = try; _retype_kwargs(t, _kwarg_types(c.method)); catch; t; end)
            # Favor the reader's OWN variables: a DATA binding (a value — kind "const"/"var", not a
            # function/type/module) OWNED by the notebook namespace (bound in a cell, not imported) is
            # tagged "notebook" so it ranks ABOVE general Base/package names. Functions/types are left
            # alone — that keeps injected Slate helpers (echart, Slider, …) out of the promotion. The
            # CURRENT cell's own bindings are lifted a further tier ("local") by the /complete route.
            (k == "const" || k == "var") && c isa REPL.REPLCompletions.ModuleCompletion &&
                c.parent === mod && _owned_by(mod, t) && (k = "notebook")
            push!(demote ? tail : items, (t, k))
        end
    catch
    end
    append!(items, tail)
    return (items = items, from = from, to = to)
end
