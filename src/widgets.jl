# Reactive input widgets (`@bind`) as REAL Julia — the SINGLE shared definition of
# a notebook's execution-namespace contract, included into BOTH the in-process
# kernel (ReportEngine, via eval.jl) and the per-notebook gate worker (SlateWorker,
# via worker.jl). Because both call `_populate_notebook_ns!`, the two namespaces are
# identical by construction — no drift (the bug class that left `@bind` undefined on
# workers).
#
# `@bind name W(args…)` expands to `name = __slate_bind(:name, W(args…))`. `W(args…)`
# is ORDINARY Julia evaluated in the live namespace, so dynamic args work:
# `Slider(1:0.5:fmax)`, `Select(sort(keys(d)))`, etc. `__slate_bind` reconciles the
# value against a per-notebook registry (preserve across re-runs unless the widget
# or its domain changed) and records the spec so the host can render the control.
#
# Dependency-light (Base only) so it loads cleanly into the standalone worker.

# A widget spec: its kind (UI tag), display params, and default value. Built by the
# constructors below at runtime — no syntactic parsing, no `Slider`-name matching.
struct Widget
    kind::String
    params::Dict{String,Any}
    default::Any
end

_wparams(label) = label === nothing ? Dict{String,Any}() : Dict{String,Any}("label" => String(label))

# ── Constructors (real functions; args are runtime values) ────────────────────
function Slider(r::AbstractRange; default = first(r), label = nothing)
    p = _wparams(label)
    p["min"] = first(r); p["max"] = last(r); p["step"] = step(r)
    return Widget("slider", p, default)
end
function Slider(lo::Real, hi::Real, default::Real = lo; step::Real = 1, label = nothing)
    p = _wparams(label); p["min"] = lo; p["max"] = hi; p["step"] = step
    return Widget("slider", p, default)
end
function NumberField(default::Real = 0; min = nothing, max = nothing, label = nothing)
    p = _wparams(label)
    min === nothing || (p["min"] = min); max === nothing || (p["max"] = max)
    return Widget("number", p, default)
end
NumberField(lo::Real, hi::Real, default::Real = lo; label = nothing) =
    Widget("number", merge(_wparams(label), Dict{String,Any}("min" => lo, "max" => hi)), default)
Checkbox(default::Bool = false; label = nothing) = Widget("checkbox", _wparams(label), default)
# `on`/`off` are the text shown for each state (e.g. `Toggle(false; on="Live", off="Paused")`);
# omit them to show the plain true/false value. `label` (like every widget) sets the display name.
function Toggle(default::Bool = false; label = nothing, on = nothing, off = nothing)
    p = _wparams(label)
    on  === nothing || (p["on"]  = String(on))
    off === nothing || (p["off"] = String(off))
    return Widget("toggle", p, default)
end
TextField(default::AbstractString = ""; label = nothing) = Widget("text", _wparams(label), String(default))
TextArea(default::AbstractString = ""; rows::Int = 3, label = nothing) =
    Widget("textarea", merge(_wparams(label), Dict{String,Any}("rows" => rows)), String(default))
# Options for Radio/Select/MultiSelect. Each entry is a bare value (shown as its string) OR a
# `value => label` pair — the bound variable takes `value`, while `label` is what's displayed (and
# may carry `$math$`/markdown, rendered for Radio). Stored as `[{value,label}]`; the value keeps
# its real Julia type so reconcile/coerce match on values, not the (possibly rich) labels.
function _norm_options(options)
    specs = Dict{String,Any}[]
    for o in options
        v, l = o isa Pair ? (o.first, o.second) : (o, o)
        push!(specs, Dict{String,Any}("value" => v, "label" => string(l)))
    end
    return specs
end
_opt_values(opts) = Any[o isa AbstractDict ? o["value"] : o for o in opts]
_opt_default(default, vals) = default === nothing ? (isempty(vals) ? nothing : first(vals)) :
                              (default isa Pair ? default.first : default)
function Select(options, default = nothing; label = nothing)
    specs = _norm_options(options)
    return Widget("select", merge(_wparams(label), Dict{String,Any}("options" => specs)), _opt_default(default, _opt_values(specs)))
end
function Radio(options, default = nothing; label = nothing)
    specs = _norm_options(options)
    return Widget("radio", merge(_wparams(label), Dict{String,Any}("options" => specs)), _opt_default(default, _opt_values(specs)))
end
function MultiSelect(options, default = Any[]; label = nothing)
    specs = _norm_options(options)
    return Widget("multiselect", merge(_wparams(label), Dict{String,Any}("options" => specs)),
                  Any[d isa Pair ? d.first : d for d in default])
end
ColorPicker(default::AbstractString = "#3aa0ff"; label = nothing) = Widget("color", _wparams(label), String(default))
DateField(default = ""; label = nothing) = Widget("date", _wparams(label), string(default))
TimeField(default = ""; label = nothing) = Widget("time", _wparams(label), string(default))
Button(label::AbstractString = "Click") = Widget("button", Dict{String,Any}("label" => String(label)), 0)

const _WIDGET_CTORS = (:Slider, :NumberField, :Checkbox, :Toggle, :TextField, :TextArea,
                       :Select, :Radio, :MultiSelect, :ColorPicker, :DateField, :TimeField, :Button)

# ── Value reconcile (the persistence policy) ──────────────────────────────────
# Re-running a bind cell updates the SPEC (range/params) but KEEPS the user's value
# unless it no longer fits: widget type changed, or value out of the new domain.
function _reconcile_bind(oldw::Widget, oldv, neww::Widget)
    oldw.kind == neww.kind || return neww.default          # type changed → reset
    if neww.kind == "slider" || neww.kind == "number"
        lo = get(neww.params, "min", -Inf); hi = get(neww.params, "max", Inf)
        return (oldv isa Number && lo <= oldv <= hi) ? oldv : neww.default
    elseif haskey(neww.params, "options")
        vals = _opt_values(neww.params["options"])
        if neww.kind == "multiselect"
            return oldv isa AbstractVector ? [v for v in oldv if v in vals] : neww.default
        end
        return oldv in vals ? oldv : neww.default
    end
    return oldv
end

# Coerce a value from the browser (JSON number/string/bool/array) to the widget's type.
function coerce_bind(w::Widget, v)
    if (w.kind == "slider" || w.kind == "number") && v isa Number
        st = get(w.params, "step", 1)
        return (st isa Integer && isinteger(v)) ? Int(round(v)) : float(v)
    elseif w.kind == "checkbox" || w.kind == "toggle"
        return v === true || v == 1
    elseif w.kind == "button"
        return v isa Number ? Int(round(v)) : v
    elseif w.kind == "select" || w.kind == "radio"
        # The browser sends the option's stringified value attribute; map it back to the real value.
        for v0 in _opt_values(get(w.params, "options", ()))
            string(v0) == string(v) && return v0
        end
        return v
    elseif w.kind == "multiselect"
        vals = _opt_values(get(w.params, "options", ()))
        sel = v isa AbstractVector ? v : (v === nothing ? Any[] : Any[v])
        ss = Set(string(s) for s in sel)
        return Any[v0 for v0 in vals if string(v0) in ss]
    end
    return v
end

# ── Per-notebook bind runtime ─────────────────────────────────────────────────
# `reg` is the notebook's registry (name => (widget, value)); `sink` collects the
# binds DECLARED during the current eval so `run_capture` can report them to the
# host. Both are created per-notebook in `_populate_notebook_ns!` and closed over,
# so each notebook is isolated and a module reset starts fresh (→ defaults).
function _do_bind(reg::Dict{Symbol,Tuple{Widget,Any}}, sink::Ref{Any}, name::Symbol, w::Widget)
    prev = get(reg, name, nothing)
    val = prev === nothing ? w.default : _reconcile_bind(prev[1], prev[2], w)
    reg[name] = (w, val)
    s = sink[]
    s === nothing || push!(s, (name = name, kind = w.kind, params = w.params, value = val))
    return val
end

# Host sets a control's value (browser change). Updates the registry so a later
# re-run of the bind cell preserves it; coerces against the known widget.
function _do_set_bind(reg::Dict{Symbol,Tuple{Widget,Any}}, name::Symbol, value)
    prev = get(reg, name, nothing)
    if prev === nothing
        reg[name] = (Widget("?", Dict{String,Any}(), value), value)
        return value
    end
    w = prev[1]; cv = coerce_bind(w, value)
    reg[name] = (w, cv)
    return cv
end

# ── The namespace contract ────────────────────────────────────────────────────
# Inject the COMPLETE, identical set of notebook-namespace names into module `m`.
# Context-specific helper *implementations* (echart/tables/refresh) are passed in;
# the SET of names, the widget constructors, and the `@bind` macro are defined here
# once. Returns the per-notebook bind sink Ref (run_capture toggles it per eval).
function _populate_notebook_ns!(m::Module; echart, EChart, slate_table, SlateTable,
                                slate_query, slate_refresh)
    Core.eval(m, :(const echart = $echart))
    Core.eval(m, :(const EChart = $EChart))
    Core.eval(m, :(const slate_table = $slate_table))
    Core.eval(m, :(const SlateTable = $SlateTable))
    Core.eval(m, :(const slate_query = $slate_query))
    Core.eval(m, :(const slate_refresh = $slate_refresh))
    Core.eval(m, :(const Widget = $Widget))
    for nm in _WIDGET_CTORS
        Core.eval(m, :(const $nm = $(getfield(@__MODULE__, nm))))
    end
    # Per-notebook bind state, closed over by the injected helpers.
    reg = Dict{Symbol,Tuple{Widget,Any}}()
    sink = Ref{Any}(nothing)
    Core.eval(m, :(const __slate_bind_registry = $reg))
    Core.eval(m, :(const __slate_bind_sink = $sink))
    Core.eval(m, :(const __slate_bind = $((name, w) -> _do_bind(reg, sink, name, w))))
    # Browser value change: coerce + update registry, then set the global so readers
    # see it (the closure captures `m`). Returns the coerced value for the host's state.
    Core.eval(m, :(const __slate_set_bind = $((name, value) -> begin
        cv = _do_set_bind(reg, name, value)
        Core.eval(m, Expr(:(=), name, cv))
        cv
    end)))
    # `@bind name W(args…)` → assign the reconciled value, then return `nothing` so a
    # bind cell shows no output (the assignment value isn't displayed).
    Core.eval(m, :(macro bind(name, widget)
        esc(Expr(:block, Expr(:(=), name, Expr(:call, :__slate_bind, QuoteNode(name), widget)), nothing))
    end))
    return sink
end

# (name::Symbol, widget_expr) if `ex` is `@bind name W(…)`, else nothing. Pure AST,
# no evaluation — used by the engine's dependency analysis: the bound name is a
# write, the widget call's free variables are reads (so dynamic ranges like
# `Slider(1:step:hi)` make the bind cell depend on `step`/`hi`).
function _bind_macrocall(ex)
    (ex isa Expr && ex.head === :macrocall && ex.args[1] === Symbol("@bind")) || return nothing
    real = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    length(real) >= 2 || return nothing
    real[1] isa Symbol || return nothing
    return (real[1], real[2])
end
