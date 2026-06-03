# Reactive input widgets (`@bind`, interactivity Layer 3). Included into
# `module ReportEngine`.
#
# A bind cell looks like `@bind temp Slider(0:100)`. It is NOT run as ordinary
# Julia; the engine parses the widget spec, assigns the variable in the module,
# and treats the cell as writing that variable — so the dependency graph and
# pruned recompute carry value changes to dependents exactly like a code edit.

export parse_bind, parse_binds, set_bind_value!, coerce_bind

# Evaluate a literal widget argument (number, string, bool, range, vector).
_lit(a) = Core.eval(Module(:_w), a)

# Map a `Widget(args…)` call to (widget_name, params, default_value).
function _widget_from_call(call::Expr)
    wtype = call.args[1]
    vals = Any[]
    for a in call.args[2:end]
        try; push!(vals, _lit(a)); catch; return nothing; end
    end
    if wtype === :Slider
        if length(vals) == 1 && vals[1] isa AbstractRange
            r = vals[1]
            return ("slider", Dict{String,Any}("min" => first(r), "max" => last(r), "step" => step(r)), first(r))
        elseif length(vals) >= 2
            lo, hi = vals[1], vals[2]
            def = length(vals) >= 3 ? vals[3] : lo
            return ("slider", Dict{String,Any}("min" => lo, "max" => hi, "step" => 1), def)
        end
    elseif wtype === :NumberField
        # NumberField(default) or NumberField(min, max [, default])
        if length(vals) >= 2
            lo, hi = vals[1], vals[2]
            def = length(vals) >= 3 ? vals[3] : lo
            return ("number", Dict{String,Any}("min" => lo, "max" => hi), def)
        end
        return ("number", Dict{String,Any}(), isempty(vals) ? 0 : vals[end])
    elseif wtype === :Checkbox
        return ("checkbox", Dict{String,Any}(), isempty(vals) ? false : vals[1])
    elseif wtype === :Toggle
        return ("toggle", Dict{String,Any}(), isempty(vals) ? false : vals[1])
    elseif wtype === :TextField
        return ("text", Dict{String,Any}(), isempty(vals) ? "" : vals[1])
    elseif wtype === :TextArea
        return ("textarea", Dict{String,Any}("rows" => 3), isempty(vals) ? "" : vals[1])
    elseif wtype === :Select
        isempty(vals) && return nothing
        opts = vals[1]
        return ("select", Dict{String,Any}("options" => collect(opts)), length(vals) >= 2 ? vals[2] : first(opts))
    elseif wtype === :Radio
        isempty(vals) && return nothing
        opts = vals[1]
        return ("radio", Dict{String,Any}("options" => collect(opts)), length(vals) >= 2 ? vals[2] : first(opts))
    elseif wtype === :MultiSelect
        isempty(vals) && return nothing
        opts = vals[1]
        def = length(vals) >= 2 ? collect(vals[2]) : Any[]
        return ("multiselect", Dict{String,Any}("options" => collect(opts)), def)
    elseif wtype === :ColorPicker
        return ("color", Dict{String,Any}(), isempty(vals) ? "#3aa0ff" : vals[1])
    elseif wtype === :DateField
        return ("date", Dict{String,Any}(), isempty(vals) ? "" : string(vals[1]))
    elseif wtype === :TimeField
        return ("time", Dict{String,Any}(), isempty(vals) ? "" : string(vals[1]))
    elseif wtype === :Button
        return ("button", Dict{String,Any}("label" => isempty(vals) ? "Click" : string(vals[1])), 0)
    end
    return nothing
end

# Parse an already-parsed expression as a `@bind name Widget(args…)`. → BindSpec | nothing.
function _parse_bind_expr(ex)
    (ex isa Expr && ex.head === :macrocall && ex.args[1] === Symbol("@bind")) || return nothing
    real = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    length(real) >= 2 || return nothing
    name, widget = real[1], real[2]
    (name isa Symbol && widget isa Expr && widget.head === :call) || return nothing
    w = _widget_from_call(widget)
    w === nothing && return nothing
    return BindSpec(name, w[1], w[2], w[3])
end

"""
    parse_bind(source) -> BindSpec | nothing

Parse a single `@bind name Widget(args…)`. Returns `nothing` if not a bind.
"""
function parse_bind(source::AbstractString)
    ex = try
        Meta.parse(strip(source))
    catch
        return nothing
    end
    return _parse_bind_expr(ex)
end

"""
    parse_binds(source) -> Vector{BindSpec}

Parse a *control-group* cell: a body whose every top-level statement is a
`@bind name Widget(…)`. Returns one `BindSpec` per line, in order. Returns an
empty vector if the cell is empty, unparseable, or mixes `@bind` with anything
else (such a cell is ordinary code — the injected `@bind` macro keeps it from
erroring; see `_new_module`).
"""
function parse_binds(source::AbstractString)
    top = try
        Meta.parseall(String(source))
    catch
        return BindSpec[]
    end
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
    specs = BindSpec[]
    for s in stmts
        s isa LineNumberNode && continue
        spec = _parse_bind_expr(s)
        spec === nothing && return BindSpec[]   # any non-@bind statement → not a group cell
        push!(specs, spec)
    end
    return specs
end

# The default value of a widget call (`Slider(1:0.5:12)` → 1.0), extracted
# syntactically. Backs the injected `@bind` macro so unrecognized bind cells
# evaluate to a sensible assignment instead of erroring.
function _bind_default(widget)
    (widget isa Expr && widget.head === :call) || return nothing
    w = _widget_from_call(widget)
    return w === nothing ? nothing : w[3]
end

"Coerce a value from the browser (JSON number/string/bool/array) to the widget's type."
function coerce_bind(spec::BindSpec, v)
    w = spec.widget
    if (w == "slider" || w == "number") && v isa Number
        st = get(spec.params, "step", 1)
        return (st isa Integer && isinteger(v)) ? Int(round(v)) : float(v)
    elseif w == "checkbox" || w == "toggle"
        return v === true || v == 1
    elseif w == "button"
        return v isa Number ? Int(round(v)) : v
    elseif w == "multiselect"
        return v isa AbstractVector ? String[string(x) for x in v] :
               v === nothing ? String[] : String[string(v)]
    end
    return v
end

"""
    set_bind_value!(report, cell, name, value, kernel=InProcessKernel()) -> cell

Set the bound variable `name` (one of `cell.binds`) to `value` and assign it into
the kernel's namespace. No-op if the cell has no such bind.
"""
function set_bind_value!(report::Report, cell::Cell, name::Symbol, value,
                         kernel::Kernel = InProcessKernel())
    i = findfirst(b -> b.name == name, cell.binds)
    i === nothing && return cell
    spec = cell.binds[i]
    spec.value = coerce_bind(spec, value)
    assign!(kernel, report, spec.name, spec.value)
    cell.state = FRESH
    return cell
end

"Convenience: set the sole bind of a single-control cell (errors if not exactly one)."
function set_bind_value!(report::Report, cell::Cell, value, kernel::Kernel = InProcessKernel())
    length(cell.binds) == 1 || return cell
    return set_bind_value!(report, cell, cell.binds[1].name, value, kernel)
end
