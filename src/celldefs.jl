# What a cell defines, and taking it back. Included into both the engine and the worker.
#
# A cell's methods carry the file Julia recorded when the cell was evaluated, `cell:<id>`, so the
# methods a cell defined can be found and deleted without knowing their signatures. That is what
# keeps a deleted or edited definition from outliving its source: re-running `sg(x::Int) = 1` as
# `sg(x::Integer) = 2` would otherwise leave the old, more specific method winning dispatch.

# Macros that wrap a definition without changing what it defines.
const _DEF_WRAPPERS = (Symbol("@doc"), Symbol("@inline"), Symbol("@noinline"), Symbol("@generated"),
                       Symbol("@kwdef"), Symbol("@nospecialize"), Symbol("@assume_effects"))

_macro_leaf(m::Symbol) = m
_macro_leaf(m::GlobalRef) = m.name
_macro_leaf(m::Expr) = m.head === :. && m.args[end] isa QuoteNode ? m.args[end].value : nothing
_macro_leaf(::Any) = nothing

# The definition a wrapper macro carries (`@inline f(x) = …`, a docstring), else the statement itself.
function _unwrap_definition(s)
    while s isa Expr && s.head === :macrocall && !isempty(s.args) && _macro_leaf(s.args[1]) in _DEF_WRAPPERS
        s = s.args[end]
    end
    return s
end

# The call signature of a function definition statement, or nothing.
function _def_signature(s)
    s isa Expr || return nothing
    (s.head === :function || s.head === :macro || s.head === :(=)) && !isempty(s.args) || return nothing
    sig = s.args[1]
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    return sig isa Expr && sig.head === :call ? sig : nothing
end

"""
    _is_definition_stmt(s) -> Bool

A top-level statement that DEFINES something rather than computing it: a function (long or short
form, possibly docstring- or `@inline`-wrapped), a global bound to an anonymous function, a type, a
macro, or a `const` bound to a literal. Such a statement is self-sufficient, establishing a name
without consuming another cell's data, so it can be replayed on another namespace or after a cache
restore. A `const` bound to an EXPRESSION does not qualify: `const N = size(data, 1)` reads upstream
data and is compute, not definition.

A definition may still REFERENCE a global in its body (`f(x) = x * SCALE`); Julia resolves it at call
time, so the definition stands on its own.
"""
function _is_definition_stmt(s)
    s = _unwrap_definition(s)
    s isa Expr || return false
    s.head in (:function, :macro, :struct, :abstract, :primitive) && return true
    if s.head === :(=) && length(s.args) == 2
        _def_signature(s) === nothing || return true
        # `name = (args) -> body`: the global holds a function the way a named definition does
        s.args[1] isa Symbol && s.args[2] isa Expr && s.args[2].head === :(->) && return true
        return false
    end
    if s.head === :const && length(s.args) == 1 && s.args[1] isa Expr && s.args[1].head === :(=)
        rhs = s.args[1].args[2]
        return rhs isa Union{Number,AbstractString,Char,Bool,QuoteNode} ||
               (rhs isa Expr && rhs.head === :call && rhs.args[1] === :(:) &&
                all(a -> a isa Number, rhs.args[2:end]))
    end
    return false
end

# A cell's top-level statements, each with the line node before it, `begin` blocks flattened: a
# `begin` opens no scope, so a definition inside one is a top-level definition.
function _flat_statements(src::AbstractString)
    out = Tuple{LineNumberNode,Any}[]
    top = try; Meta.parseall(String(src)); catch; return out; end
    (top isa Expr && top.head === :toplevel) || return out
    ln = Ref(LineNumberNode(1, :none))
    walk(args) = for a in args
        if a isa LineNumberNode
            ln[] = a
        elseif a isa Expr && a.head === :block
            walk(a.args)
        else
            push!(out, (ln[], a))
        end
    end
    walk(top.args)
    return out
end
_toplevel_stmts(src::AbstractString) = Any[s for (_, s) in _flat_statements(src)]

function _type_name(n)
    n isa Expr && n.head === :(<:) && (n = n.args[1])
    n isa Expr && n.head === :curly && (n = n.args[1])
    return n isa Symbol ? n : nothing
end

_is_function_value(x) = x isa Expr && x.head in (:(->), :function)

# The global names one definition statement binds: a function or macro name, a type name, an
# anonymous-function global, a literal const. A qualified extension (`Base.show`) binds nothing.
function _stmt_definition_names!(out::Set{Symbol}, s)
    d = _unwrap_definition(s)
    d isa Expr || return out
    if d.head === :macro
        sig = _def_signature(d); sig === nothing || (sig.args[1] isa Symbol && push!(out, Symbol("@", sig.args[1])))
    elseif d.head in (:function, :(=))
        sig = _def_signature(d)
        if sig !== nothing
            sig.args[1] isa Symbol && push!(out, sig.args[1])
        elseif d.args[1] isa Symbol
            push!(out, d.args[1])
        end
    elseif d.head === :struct
        n = _type_name(d.args[2]); n === nothing || push!(out, n)
    elseif d.head in (:abstract, :primitive)
        n = _type_name(d.args[1]); n === nothing || push!(out, n)
    elseif d.head === :const
        a = d.args[1].args[1]
        a isa Symbol && push!(out, a)
    end
    return out
end

# What a top-level `let` makes global: `(functions, all)`. `functions` are the globals it defines as
# functions (`global f(x) = …`, `global function f … end`, `global g = x -> …`, or a `function f` the
# block declared `global f` for); `all` adds the plain globals it assigns. Function bodies inside the
# block are not entered: a `global` there binds when the function is called.
function _let_globals(s)
    fns = Set{Symbol}(); all = Set{Symbol}(); declared = Set{Symbol}(); localdefs = Set{Symbol}()
    function decl!(a)
        if a isa Symbol
            push!(declared, a); push!(all, a)
        elseif a isa Expr && a.head === :function
            sig = _def_signature(a); sig !== nothing && sig.args[1] isa Symbol && (push!(fns, sig.args[1]); push!(all, sig.args[1]))
        elseif a isa Expr && a.head === :(=)
            sig = _def_signature(a)
            if sig !== nothing
                sig.args[1] isa Symbol && (push!(fns, sig.args[1]); push!(all, sig.args[1]))
            elseif a.args[1] isa Symbol
                push!(all, a.args[1])
                _is_function_value(a.args[2]) && push!(fns, a.args[1])
            end
        end
    end
    function walk(ex)
        ex isa Expr || return
        if ex.head === :global
            foreach(decl!, ex.args)
        elseif (sig = _def_signature(ex)) !== nothing
            sig.args[1] isa Symbol && push!(localdefs, sig.args[1])
        else
            foreach(walk, ex.args)
        end
    end
    foreach(walk, s.args)
    union!(fns, intersect(localdefs, declared))
    return (fns, all)
end

# `name = let … end` whose value is a function (its last statement is one).
function _let_function_assignment(s)
    (s isa Expr && s.head === :(=) && length(s.args) == 2 && s.args[1] isa Symbol) || return nothing
    rhs = s.args[2]
    (rhs isa Expr && rhs.head === :let && length(rhs.args) == 2 && rhs.args[2] isa Expr) || return nothing
    body = [a for a in rhs.args[2].args if !(a isa LineNumberNode)]
    return !isempty(body) && _is_function_value(body[end]) ? s.args[1] : nothing
end

"""
    _replay_plan(src) -> (; stmts, idx, names)

Which of a cell's statements re-establish its definitions on a cache restore, and the globals they
bind, so a memo entry stores everything else. `stmts` are the flattened top-level statements with
their line nodes; `idx` indexes the ones to replay, in source order:

- definition statements (`_is_definition_stmt`), including those inside a top-level `begin`;
- a top-level `let` that defines a global function, replayed whole, since the function may close
  over the block's locals;
- `name = let … end` whose value is a function, for the same reason.

A replayed `let` costs what running it costs; it is the only way its function can come back. The hub
and the worker both call this, so the entry's contents and the restore agree.
"""
function _replay_plan(src::AbstractString)
    stmts = _flat_statements(src)
    idx = Int[]; names = Set{Symbol}()
    for (i, (_, s)) in enumerate(stmts)
        if _is_definition_stmt(s)
            push!(idx, i); _stmt_definition_names!(names, s)
        elseif s isa Expr && s.head === :let
            fns, all = _let_globals(s)
            isempty(fns) && continue
            push!(idx, i); union!(names, all)
        elseif (n = _let_function_assignment(s)) !== nothing
            push!(idx, i); push!(names, n)
        end
    end
    return (; stmts, idx, names)
end

# The global names a cell's replayed statements bind (see `_replay_plan`).
_definition_names(src::AbstractString) = _replay_plan(src).names

# The functions a cell adds methods to, as evaluable paths: `f`, `var"@m"`'s `Symbol("@m")`, a
# qualified `Base.show`, or a function a `let` block defines globally. Type constructors are left out:
# deleting a struct's default constructors breaks the type when its unchanged definition re-evaluates
# as a no-op.
function _defined_function_paths(src::AbstractString)
    out = Any[]
    for (_, s) in _flat_statements(src)
        d = _unwrap_definition(s)
        d isa Expr || continue
        if d.head === :let
            for f in _let_globals(d)[1]; f in out || push!(out, f); end
            continue
        end
        sig = _def_signature(d)
        sig === nothing && continue
        f = sig.args[1]
        p = d.head === :macro ? (f isa Symbol ? Symbol("@", f) : nothing) :
            (f isa Symbol || (f isa Expr && f.head === :.)) ? f : nothing
        p === nothing || p in out || push!(out, p)
    end
    return out
end

# Module → cell id → the function paths that cell's last evaluation defined methods on.
const _CELL_DEFS = IdDict{Module,Dict{String,Vector{Any}}}()
const _CELL_DEFS_LOCK = ReentrantLock()

function _delete_cell_methods!(mod::Module, cid::AbstractString, paths)
    isempty(paths) && return 0
    tag = Symbol("cell:", cid)
    n = 0
    for p in paths
        f = try; Base.invokelatest(Core.eval, mod, p); catch; continue; end
        f isa Function || continue
        for m in collect(Base.invokelatest(methods, f))
            m.file === tag || continue
            try
                Base.delete_method(m); n += 1
            catch e
                @debug "slate: could not delete a cell's method" cell = cid method = m exception = e
            end
        end
    end
    return n
end

"""
    _redefine_cell!(mod, cid, source) -> Int

Delete the methods this cell defined last time, before it defines them again from `source`. A
renamed or re-signatured method would otherwise survive the edit that removed it. Returns the
number of methods deleted.
"""
function _redefine_cell!(mod::Module, cid::AbstractString, source::AbstractString)
    isempty(cid) && return 0
    now = _defined_function_paths(source)
    before = lock(_CELL_DEFS_LOCK) do
        d = get!(Dict{String,Vector{Any}}, _CELL_DEFS, mod)
        prev = get(d, String(cid), Any[])
        d[String(cid)] = now
        prev
    end
    return _delete_cell_methods!(mod, cid, unique!(vcat(before, now)))
end

"Delete the methods a removed cell defined and forget it. Returns the number deleted."
function _forget_cell!(mod::Module, cid::AbstractString)
    paths = lock(_CELL_DEFS_LOCK) do
        d = get(_CELL_DEFS, mod, nothing)
        d === nothing ? Any[] : pop!(d, String(cid), Any[])
    end
    return _delete_cell_methods!(mod, cid, paths)
end

"""
    _unbind_globals!(mod, names) -> Vector{Symbol}

Remove globals that no cell defines any more, so reading one throws `UndefVarError` the way a fresh
run would, instead of serving the value of a deleted or renamed definition. Only bindings the
namespace owns are removed; an imported name is left alone. A no-op on a Julia without
`Base.delete_binding`.
"""
function _unbind_globals!(mod::Module, names)
    out = Symbol[]
    isdefined(Base, :delete_binding) || return out
    for n in names
        s = Symbol(n)
        Base.invokelatest(isdefinedglobal, mod, s) || continue
        Base.binding_module(mod, s) === mod || continue
        try
            Base.delete_binding(mod, s); push!(out, s)
        catch e
            @debug "slate: could not remove a global" name = s exception = e
        end
    end
    return out
end
