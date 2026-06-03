# Reactive input widgets (`@bind`, interactivity Layer 3). Included into
# `module ReportEngine`.
#
# A bind cell looks like `@bind temp Slider(0:100)`. It is NOT run as ordinary
# Julia; the engine parses the widget spec, assigns the variable in the module,
# and treats the cell as writing that variable — so the dependency graph and
# pruned recompute carry value changes to dependents exactly like a code edit.

export parse_bind, set_bind_value!, coerce_bind

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
        return ("number", Dict{String,Any}(), isempty(vals) ? 0 : vals[end])
    elseif wtype === :Checkbox
        return ("checkbox", Dict{String,Any}(), isempty(vals) ? false : vals[1])
    elseif wtype === :TextField
        return ("text", Dict{String,Any}(), isempty(vals) ? "" : vals[1])
    elseif wtype === :Select
        isempty(vals) && return nothing
        opts = vals[1]
        return ("select", Dict{String,Any}("options" => collect(opts)), length(vals) >= 2 ? vals[2] : first(opts))
    end
    return nothing
end

"""
    parse_bind(source) -> BindSpec | nothing

Parse `@bind name Widget(args…)`. Returns `nothing` if the source isn't a bind.
"""
function parse_bind(source::AbstractString)
    ex = try
        Meta.parse(strip(source))
    catch
        return nothing
    end
    (ex isa Expr && ex.head === :macrocall && ex.args[1] === Symbol("@bind")) || return nothing
    real = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    length(real) >= 2 || return nothing
    name, widget = real[1], real[2]
    (name isa Symbol && widget isa Expr && widget.head === :call) || return nothing
    w = _widget_from_call(widget)
    w === nothing && return nothing
    return BindSpec(name, w[1], w[2], w[3])
end

"Coerce a value from the browser (JSON number/string/bool) to the widget's type."
function coerce_bind(spec::BindSpec, v)
    if (spec.widget == "slider" || spec.widget == "number") && v isa Number
        st = get(spec.params, "step", 1)
        return (st isa Integer && isinteger(v)) ? Int(round(v)) : float(v)
    elseif spec.widget == "checkbox"
        return v === true || v == 1
    end
    return v
end

"Set a bound variable's value and assign it into the kernel's namespace."
function set_bind_value!(report::Report, cell::Cell, value, kernel::Kernel = InProcessKernel())
    cell.bind === nothing && return cell
    cell.bind.value = coerce_bind(cell.bind, value)
    assign!(kernel, report, cell.bind.name, cell.bind.value)
    cell.state = FRESH
    return cell
end
