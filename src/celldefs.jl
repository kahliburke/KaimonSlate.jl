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

_toplevel_stmts(src::AbstractString) = begin
    top = try; Meta.parseall(String(src)); catch; return Any[]; end
    top isa Expr && top.head === :toplevel ? Any[a for a in top.args if !(a isa LineNumberNode)] : Any[]
end

# The global names a cell's definition statements bind: function and macro names, type names,
# anonymous-function globals, literal consts. Qualified extensions (`Base.show`) bind nothing here.
function _definition_names(src::AbstractString)
    out = Set{Symbol}()
    for s in _toplevel_stmts(src)
        _is_definition_stmt(s) || continue
        d = _unwrap_definition(s)
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
            n = d.args[2]
            n isa Expr && n.head === :(<:) && (n = n.args[1])
            n isa Expr && n.head === :curly && (n = n.args[1])
            n isa Symbol && push!(out, n)
        elseif d.head in (:abstract, :primitive)
            n = d.args[1]
            n isa Expr && n.head === :(<:) && (n = n.args[1])
            n isa Expr && n.head === :curly && (n = n.args[1])
            n isa Symbol && push!(out, n)
        elseif d.head === :const
            a = d.args[1].args[1]
            a isa Symbol && push!(out, a)
        end
    end
    return out
end

# The functions a cell adds methods to, as evaluable paths: `f`, `var"@m"`'s `Symbol("@m")`, or a
# qualified `Base.show`. Type constructors are left out: deleting a struct's default constructors
# breaks the type when its unchanged definition re-evaluates as a no-op.
function _defined_function_paths(src::AbstractString)
    out = Any[]
    for s in _toplevel_stmts(src)
        d = _unwrap_definition(s)
        d isa Expr || continue
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
