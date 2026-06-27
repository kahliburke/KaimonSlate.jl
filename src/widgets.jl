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

# What an option widget (Radio/Select/MultiSelect built from `value => label` pairs) binds to:
# it carries BOTH the selected value and its display label. It behaves like the value for
# comparison, display, hashing and string interpolation — so `pick == "a"`, `Dict(opts)[pick]`,
# `"$(pick)"` and `{{ pick }}` all use the value — while `pick.label` gives the rendered text.
# Fields: `.value` / `.label` (short aliases `.v` / `.l`).
struct Choice{V}
    value::V
    label::String
    index::Int            # 1-based position in the widget's option list (0 = unknown)
end
Choice(value, label) = Choice(value, label, 0)
Base.getproperty(c::Choice, s::Symbol) = s === :v ? getfield(c, :value) : s === :l ? getfield(c, :label) :
                                         s === :i ? getfield(c, :index) : getfield(c, s)
Base.propertynames(::Choice) = (:value, :label, :index, :v, :l, :i)
Base.show(io::IO, c::Choice) = show(io, getfield(c, :value))
Base.print(io::IO, c::Choice) = print(io, getfield(c, :value))
Base.string(c::Choice) = string(getfield(c, :value))
Base.:(==)(a::Choice, b::Choice) = getfield(a, :value) == getfield(b, :value)
Base.:(==)(a::Choice, b) = getfield(a, :value) == b
Base.:(==)(a, b::Choice) = a == getfield(b, :value)
Base.hash(c::Choice, h::UInt) = hash(getfield(c, :value), h)
Base.isequal(a::Choice, b::Choice) = isequal(getfield(a, :value), getfield(b, :value))

# A multi-selection — an ordered, read-only `value => label` dict (emulates OrderedDict on Base
# alone). `keys(picks)` → values, `values(picks)` → labels, `picks[v]` → label, `haskey`,
# `for (v,l) in picks`, `length`; plus `indices(picks)` → each pick's position in the original
# option list. (`v in picks` checks pairs like any dict — use `v in keys(picks)` / `haskey`.)
struct Selection <: AbstractDict{Any,String}
    items::Vector{Choice}
end
Base.length(s::Selection) = length(s.items)
Base.iterate(s::Selection, i = 1) = i > length(s.items) ? nothing : (s.items[i].value => s.items[i].label, i + 1)
function Base.getindex(s::Selection, k)
    for c in s.items
        isequal(c.value, k) && return c.label
    end
    throw(KeyError(k))
end
Base.haskey(s::Selection, k) = any(c -> isequal(c.value, k), s.items)
indices(s::Selection) = Int[c.index for c in s.items]

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
# Returns (specs, labeled): specs is `[{value,label}]`; labeled is true if ANY option was a
# `value => label` pair (→ the widget binds a `Choice` so the label is reachable).
function _norm_options(options)
    specs = Dict{String,Any}[]; labeled = false
    for o in options
        if o isa Pair
            labeled = true
            push!(specs, Dict{String,Any}("value" => o.first, "label" => string(o.second)))
        else
            push!(specs, Dict{String,Any}("value" => o, "label" => string(o)))
        end
    end
    return specs, labeled
end
_opt_values(opts) = Any[o isa AbstractDict ? o["value"] : o for o in opts]
_opt_default(default, vals) = default === nothing ? (isempty(vals) ? nothing : first(vals)) :
                              (default isa Pair ? default.first : default)
_opt_params(label, specs, labeled) = begin
    p = merge(_wparams(label), Dict{String,Any}("options" => specs))
    labeled && (p["labeled"] = true)   # bind a Choice (value + label) rather than the bare value
    p
end
function Select(options, default = nothing; label = nothing)
    specs, labeled = _norm_options(options)
    return Widget("select", _opt_params(label, specs, labeled), _opt_default(default, _opt_values(specs)))
end
function Radio(options, default = nothing; label = nothing)
    specs, labeled = _norm_options(options)
    return Widget("radio", _opt_params(label, specs, labeled), _opt_default(default, _opt_values(specs)))
end
function MultiSelect(options, default = Any[]; label = nothing)   # compact multi-select dropdown (long lists)
    specs, labeled = _norm_options(options)
    return Widget("multiselect", _opt_params(label, specs, labeled), Any[d isa Pair ? d.first : d for d in default])
end
function MultiCheckBox(options, default = Any[]; label = nothing)  # checkbox list (small discrete sets)
    specs, labeled = _norm_options(options)
    return Widget("multicheck", _opt_params(label, specs, labeled), Any[d isa Pair ? d.first : d for d in default])
end
_is_multi(kind) = kind == "multiselect" || kind == "multicheck"
ColorPicker(default::AbstractString = "#3aa0ff"; label = nothing) = Widget("color", _wparams(label), String(default))
DateField(default = ""; label = nothing) = Widget("date", _wparams(label), string(default))
TimeField(default = ""; label = nothing) = Widget("time", _wparams(label), string(default))
Button(label::AbstractString = "Click") = Widget("button", Dict{String,Any}("label" => String(label)), 0)

const _WIDGET_CTORS = (:Slider, :NumberField, :Checkbox, :Toggle, :TextField, :TextArea,
                       :Select, :Radio, :MultiSelect, :MultiCheckBox, :ColorPicker, :DateField, :TimeField, :Button)

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
        if _is_multi(neww.kind)
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
    elseif _is_multi(w.kind)
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
# (label, 1-based index) for value `v` in an option widget's specs (label falls back to v's string).
function _lookup_option(w::Widget, v)
    for (i, o) in enumerate(get(w.params, "options", ()))
        if o isa AbstractDict
            isequal(get(o, "value", nothing), v) && return (String(o["label"]), i)
        elseif isequal(o, v)
            return (string(o), i)
        end
    end
    return (string(v), 0)
end
_choice(w::Widget, v) = (li = _lookup_option(w, v); Choice(v, li[1], li[2]))
# Wrap a LABELED option widget's value for the user namespace: a single Choice (Radio/Select) or a
# `Selection` (multi). The registry, wire and frontend keep the bare value(s); non-labeled
# widgets pass through unchanged.
function _wrap_choice(w::Widget, val)
    get(w.params, "labeled", false) === true || return val
    _is_multi(w.kind) && return Selection(Choice[_choice(w, v) for v in val])
    (w.kind == "select" || w.kind == "radio") && return _choice(w, val)
    return val
end

function _do_bind(reg::Dict{Symbol,Tuple{Widget,Any}}, sink::Ref{Any}, name::Symbol, w::Widget)
    prev = get(reg, name, nothing)
    val = prev === nothing ? w.default : _reconcile_bind(prev[1], prev[2], w)
    reg[name] = (w, val)
    s = sink[]
    s === nothing || push!(s, (name = name, kind = w.kind, params = w.params, value = val))
    return _wrap_choice(w, val)        # user gets a Choice for labeled option widgets; bare value otherwise
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
                                slate_query, slate_refresh, slate_progress = (frac; msg = "") -> nothing)
    Core.eval(m, :(const echart = $echart))
    Core.eval(m, :(const EChart = $EChart))
    Core.eval(m, :(const series = $series))       # ECharts DSL series builder (echarts_dsl.jl)
    Core.eval(m, :(const slate_table = $slate_table))
    Core.eval(m, :(const SlateTable = $SlateTable))
    Core.eval(m, :(const slate_query = $slate_query))
    Core.eval(m, :(const slate_refresh = $slate_refresh))
    Core.eval(m, :(const slate_progress = $slate_progress))   # slate_progress(frac; msg) → live cell progress
    Core.eval(m, :(const Widget = $Widget))
    Core.eval(m, :(const Choice = $Choice))
    Core.eval(m, :(const Selection = $Selection))
    Core.eval(m, :(const indices = $indices))
    for nm in _WIDGET_CTORS
        Core.eval(m, :(const $nm = $(getfield(@__MODULE__, nm))))
    end
    # Per-notebook bind state, closed over by the injected helpers.
    reg = Dict{Symbol,Tuple{Widget,Any}}()
    sink = Ref{Any}(nothing)
    handlers = Dict{Symbol,Any}()                 # @onclick: button name → handler closure (event model)
    tokens = Dict{Symbol,Base.RefValue{Bool}}()   # button name → running handler's cancel token
    Core.eval(m, :(const __slate_bind_registry = $reg))
    Core.eval(m, :(const __slate_bind_sink = $sink))
    Core.eval(m, :(const __slate_bind = $((name, w) -> _do_bind(reg, sink, name, w))))
    # Browser value change: coerce + update registry, set the global so readers see it, then
    # DISPATCH to any registered @onclick handler (so a button is an event — the handler fires
    # here, NOT by recomputing a cell that reads the button). Returns the coerced value for the host.
    Core.eval(m, :(const __slate_set_bind = $((name, value) -> begin
        cv = _do_set_bind(reg, name, value)
        w = reg[name][1]
        wv = _wrap_choice(w, cv)
        Core.eval(m, Expr(:(=), name, wv))                    # user var is a Choice (labeled); host gets bare cv
        h = get(handlers, name, nothing)
        h === nothing || __on_fire!(tokens, name, h, wv)      # dispatch @onclick/@onchange with the new value
        cv
    end)))
    # `@bind name W(args…)` → assign the reconciled value, then return `nothing` so a
    # bind cell shows no output (the assignment value isn't displayed).
    Core.eval(m, :(macro bind(name, widget)
        esc(Expr(:block, Expr(:(=), name, Expr(:call, :__slate_bind, QuoteNode(name), widget)), nothing))
    end))
    # `@trace begin … end` — rewrite the block to record each assignment into `__slate_trace_sink`
    # while the cell STILL RETURNS ITS REAL LAST VALUE (so the output is normal; the trace shows in
    # the inspector popup). `run_capture` reads the sink into the wire `trace` field. The sink is
    # per-notebook (like `__slate_bind_sink`); `_trace_transform` is spliced as an object (trace.jl).
    trace_sink = Ref{Any}(nothing)
    Core.eval(m, :(const __slate_trace_sink = $trace_sink))
    Core.eval(m, :(macro trace(blk)
        esc($(_trace_transform)(blk))
    end))
    # ── Reactive async primitives (reactive.jl) ──────────────────────────────────
    Core.eval(m, :(const Reactive = $Reactive))
    Core.eval(m, :(const pause = $pause))
    # `reactive(:name, init)` — a live value bound to THIS notebook's slate_refresh.
    Core.eval(m, :(const reactive = $((nm, init) -> Reactive(nm, init, slate_refresh))))
    # `@onclick`/`@onchange` REGISTER `body` as the handler for a control (they do NOT read the
    # control, so a change doesn't recompute this cell — see __slate_set_bind for the dispatch).
    # Re-running the cell just re-registers (capturing the latest closure); it never fires.
    Core.eval(m, :(const __on_register = $((nm, f) -> (handlers[nm] = f; nothing))))
    # `cancel(:ctrl)` — stop the running handler for a control (e.g. from a Stop button).
    Core.eval(m, :(const cancel = $((nm::Symbol) -> __on_cancel!(tokens, nm))))
    # `@onclick btn body` — fire `body` on a click (the click count value is ignored).
    Core.eval(m, :(macro onclick(btn, body)
        esc(Expr(:call, :__on_register, QuoteNode(btn), Expr(:(->), Expr(:tuple, :_), body)))
    end))
    # `@onchange ctrl body` — fire `body` whenever `ctrl` changes; inside the body `ctrl` is the NEW
    # value (a handler parameter, so the cell doesn't read the global → no recompute on change).
    Core.eval(m, :(macro onchange(ctrl, body)
        esc(Expr(:call, :__on_register, QuoteNode(ctrl), Expr(:(->), Expr(:tuple, ctrl), body)))
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

# (button::Symbol, body_expr) if `ex` is `@onclick btn body`, else nothing. Like `_bind_macrocall`,
# this lets the dependency analysis see through the macro: the button is a READ (so a click
# recomputes the handler cell) and the body is analysed normally (so `level[] = v` registers as a
# write of `level`, excluding the handler from its own refresh).
function _onclick_macrocall(ex)
    (ex isa Expr && ex.head === :macrocall && ex.args[1] === Symbol("@onclick")) || return nothing
    real = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    length(real) >= 2 || return nothing
    real[1] isa Symbol || return nothing
    return (real[1], real[2])
end

# (control::Symbol, body_expr) if `ex` is `@onchange ctrl body`, else nothing. The control is the
# handler PARAMETER (the new value), not a read of the global — so the cell doesn't recompute on
# change; only `body`'s OTHER free vars are reads, and `ctrl[]=`-style mutations are writes.
function _onchange_macrocall(ex)
    (ex isa Expr && ex.head === :macrocall && ex.args[1] === Symbol("@onchange")) || return nothing
    real = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    length(real) >= 2 || return nothing
    real[1] isa Symbol || return nothing
    return (real[1], real[2])
end
