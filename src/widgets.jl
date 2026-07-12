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
# Dependency-light (Base + stdlib only) so it loads cleanly into the standalone worker.
import Base64   # stdlib — for WebPage(obscure=true) base64 packaging

# slate_fingerprint + memo-store introspection — shared notebook helpers injected below
# (one include here serves both namespaces, mirroring how this file itself is shared).
include(joinpath(@__DIR__, "fingerprint.jl"))

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
# Transparent in CONVERT/INDEX contexts too — typed struct fields, typed local assignment (`x::Int = c`),
# typed collections (`Int[c]`, `push!(::Vector{Int}, c)`), indexing (`arr[c]`), and explicit numeric
# construction (`Int(c)`) — so a labeled option's `Choice` works wherever its bare value would flow
# through a `convert`. `convert` is restricted to SCALAR targets so it can't shadow the Choice→Choice
# conversion that `Choice[…]` collections (e.g. `Selection`) depend on. NOTE: a typed *keyword/positional
# argument* (`f(; n::Int)`, `f(n::Int)`) ASSERTS/DISPATCHES rather than converting — Julia rejects even a
# `Float64` there — so it still needs `Int(c)`/`c.value`; no `Choice` method can change that.
Base.convert(::Type{T}, c::Choice) where {T<:Union{Number,AbstractString,AbstractChar,Symbol}} =
    convert(T, getfield(c, :value))
(::Type{T})(c::Choice) where {T<:Number} = T(getfield(c, :value))
Base.to_index(c::Choice) = Base.to_index(getfield(c, :value))

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
# A DRIVEN control: an animation player pushes its current 1-based frame index here (browser→Julia,
# throttled), so `@bind t playhead(anim)` lets other cells react to playback. It has no input of its
# own — the player IS the control. Links to its animation by the manifest's animId.
function playhead(anim; label = nothing)
    p = _wparams(label)
    p["animId"] = hasproperty(anim, :manifest) ? String(get(anim.manifest, "animId", "")) : ""
    return Widget("playhead", p, 1)
end

# A CLICKABLE table: renders `data` (a DataFrame / any Tables.jl source / columns+rows — anything
# `slate_table` accepts) and binds the CLICKED ROW as a NamedTuple with a field per column, so
# `@bind sel TableSelect(df)` gives `sel.colname` downstream. The wire/registry value is the 1-based
# row index (0 = nothing selected); the user-facing variable is the row NamedTuple, built in
# `_wrap_choice` (mirrors how a labeled Select stores the bare value but hands the user a `Choice`).
# `maxrows` caps the rendered/selectable rows so a huge frame stays snappy (truncation is flagged);
# `default` is an optional 1-based initial row.
function TableSelect(data; default = nothing, label = nothing, maxrows::Integer = 200)
    st = slate_table(data)   # accepts anything slate_table does (Tables.jl source, Vector{NamedTuple}, …)
    n = min(length(st.rows), Int(maxrows))
    p = _wparams(label)
    p["columns"] = Any[_col_wire(c) for c in st.columns]   # object-form columns (name/type/align/format)
    p["rows"] = st.rows[1:n]
    o = Dict{String,Any}("nrows" => get(st.opts, "nrows", length(st.rows)), "ncols" => length(st.columns))
    length(st.rows) > n && (o["truncated"] = true)
    p["opts"] = o
    return Widget("tableselect", p, default === nothing ? 0 : clamp(Int(default), 0, n))
end
# The clicked row of a TableSelect as a NamedTuple (field per column). `idx` is 1-based; 0 or
# out-of-range → `nothing` (no selection). Column names become the field Symbols (dot access works
# for identifier-like names); values are the JSON-safe cell values captured at construction.
function _row_namedtuple(w::Widget, idx::Integer)
    rows = get(w.params, "rows", Vector{Any}[])
    (idx < 1 || idx > length(rows)) && return nothing
    cols = get(w.params, "columns", Any[])
    row = rows[idx]
    _cname(c) = c isa AbstractDict ? String(get(c, "name", "")) : string(c)   # object-form columns → name
    names = Tuple(Symbol(_cname(c)) for c in cols)
    vals = Tuple(i <= length(row) ? row[i] : nothing for i in eachindex(cols))
    return NamedTuple{names}(vals)
end

const _WIDGET_CTORS = (:Slider, :NumberField, :Checkbox, :Toggle, :TextField, :TextArea,
                       :Select, :Radio, :MultiSelect, :MultiCheckBox, :ColorPicker, :DateField,
                       :TimeField, :Button, :playhead, :TableSelect)

# ── Value reconcile (the persistence policy) ──────────────────────────────────
# Re-running a bind cell updates the SPEC (range/params) but KEEPS the user's value
# unless it no longer fits: widget type changed, or value out of the new domain.
function _reconcile_bind(oldw::Widget, oldv, neww::Widget)
    # `oldw.kind == "?"` is the placeholder `_do_set_bind` fabricates when the browser sets a
    # value for a name the registry doesn't know yet (e.g. a control-change race before this
    # cell's first run this session). It's not a real "type changed" — coerce the pending value
    # against the REAL widget instead of discarding it to the default.
    oldw.kind == "?" && return coerce_bind(neww, oldv)
    oldw.kind == neww.kind || return neww.default          # type changed → reset
    if neww.kind == "slider" || neww.kind == "number"
        lo = get(neww.params, "min", -Inf); hi = get(neww.params, "max", Inf)
        return (oldv isa Number && lo <= oldv <= hi) ? oldv : neww.default
    elseif neww.kind == "tableselect"                      # keep the selected row index if still valid
        n = length(get(neww.params, "rows", ()))
        return (oldv isa Integer && 1 <= oldv <= n) ? oldv : neww.default
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
        # Key the int-vs-float coercion on the widget's DEFAULT type, not `step`: a Float64 slider
        # (`Slider(0.0, 10.0)`) defaults step to 1 (Integer), which previously truncated its values to Int.
        return (w.default isa Integer && isinteger(v)) ? Int(round(v)) : float(v)
    elseif w.kind == "checkbox" || w.kind == "toggle"
        return v === true || v == 1
    elseif w.kind == "button" || w.kind == "playhead"
        return v isa Number ? Int(round(v)) : v
    elseif w.kind == "tableselect"
        # The browser sends the clicked row's 1-based index; clamp to the known rows (0 = none).
        n = length(get(w.params, "rows", ()))
        i = v isa Number ? Int(round(v)) : 0
        return (1 <= i <= n) ? i : 0
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
    w.kind == "tableselect" && return _row_namedtuple(w, val isa Integer ? val : 0)   # index → row NamedTuple
    get(w.params, "labeled", false) === true || return val
    _is_multi(w.kind) && return Selection(Choice[_choice(w, v) for v in val])
    (w.kind == "select" || w.kind == "radio") && return _choice(w, val)
    return val
end

# The per-eval `@bind` sink is TASK-LOCAL, so cells evaluated CONCURRENTLY (the parallel batch) each
# collect their own controls instead of racing on one shared vector. `run_capture` seeds/reads it.
const _BIND_SINK_KEY = :__slate_binds

function _do_bind(reg::Dict{Symbol,Tuple{Widget,Any}}, reglock::ReentrantLock, name::Symbol, w::Widget)
    # The registry PERSISTS across evals and is shared, so a concurrent bind batch would resize the
    # Dict from two tasks at once — guard it. (The sink below is task-local, so it needs no lock.)
    val = lock(reglock) do
        prev = get(reg, name, nothing)
        v = prev === nothing ? w.default : _reconcile_bind(prev[1], prev[2], w)
        reg[name] = (w, v)
        v
    end
    s = get(task_local_storage(), _BIND_SINK_KEY, nothing)
    s === nothing || push!(s, (name = name, kind = w.kind, params = w.params, value = val))
    return _wrap_choice(w, val)        # user gets a Choice for labeled option widgets; bare value otherwise
end

# Host sets a control's value (browser change). Updates the registry so a later
# re-run of the bind cell preserves it; coerces against the known widget. Locked — a browser change
# can land while a parallel eval batch is mutating the same registry.
function _do_set_bind(reg::Dict{Symbol,Tuple{Widget,Any}}, reglock::ReentrantLock, name::Symbol, value)
    lock(reglock) do
        prev = get(reg, name, nothing)
        if prev === nothing
            reg[name] = (Widget("?", Dict{String,Any}(), value), value)
            return value
        end
        w = prev[1]; cv = coerce_bind(w, value)
        reg[name] = (w, cv)
        return cv
    end
end

# ── WebPage: compose a self-contained HTML page from CSS/HTML/JS ──────────────
# A first-class replacement for the ad-hoc `HTMLDoc` + base64 `<img onload>` boot pattern (see the
# Portfolio front page). Pass the pieces as strings — typically via `@asset` so the source files are
# TRACKED (edit → the cell re-runs; the memo won't serve stale): `WebPage(css=@asset("app.css"),
# js=@asset("app.js"), html=@asset("app.html"))`. Renders to ONE `text/html` output — `<style>` +
# body + `<script>` — that works both in the live notebook (its `<script>` is revived by the
# frontend's `runScripts`) and in a static export/publish (self-contained, no external requests, no
# `<img onload>` smuggling needed since a static page runs `<script>` natively).
#
# `obscure=true` base64-encodes the JS behind a tiny decode-and-run bootstrap ("curtains" — trivial
# to peel, but it doesn't spill the source to a casual View-Source), for when a published page should
# keep the magic behind the curtain. The source files on disk stay plain and debuggable regardless.
struct WebPage
    html::String
    css::String
    js::String
    obscure::Bool
end
WebPage(; html::AbstractString = "", css::AbstractString = "", js::AbstractString = "", obscure::Bool = false) =
    WebPage(String(html), String(css), String(js), obscure)
function Base.show(io::IO, ::MIME"text/html", w::WebPage)
    isempty(w.css) || print(io, "<style>", replace(w.css, "</style>" => "<\\/style>"), "</style>")
    print(io, w.html)
    if !isempty(w.js)
        if w.obscure
            # Decode the base64'd UTF-8 (atob → latin-1 bytes; TextDecoder reassembles multi-byte
            # chars) and run it. A plain `<script>` (no image hack) — revived live by runScripts,
            # native in a static export.
            print(io, "<script>Function(new TextDecoder().decode(Uint8Array.from(atob('",
                  Base64.base64encode(w.js), "'),c=>c.charCodeAt(0))))()</script>")
        else
            print(io, "<script>", replace(w.js, "</script>" => "<\\/script>"), "</script>")
        end
    end
    return nothing
end

# Normalize call args to NAMED-TUPLE shape so a handler reads `args.n` (not `args["n"]`): a JSON object
# → NamedTuple (Symbol keys), arrays stay Vectors (recursing into elements so nested objects convert
# too), scalars pass through. Applied at BOTH handler boundaries (the WS `__slate_call` and `slate_call`),
# so a handler written against `args.field` works from JS and from Julia alike. `get(args, :n, default)`
# and `haskey` work as usual; a non-identifier JSON key lands as `var"my-key"` (reach it via
# `getproperty(args, Symbol("my-key"))`). Type-unstable by construction — fine for the fixed arg shapes
# a given call uses (the field names ARE the type); don't route huge dynamic key-sets through it.
_slate_args(x::AbstractDict) = NamedTuple{Tuple(Symbol.(keys(x)))}(Tuple(_slate_args(v) for v in values(x)))
_slate_args(x::AbstractVector) = Any[_slate_args(v) for v in x]
_slate_args(x) = x

# ── The namespace contract ────────────────────────────────────────────────────
# Inject the COMPLETE, identical set of notebook-namespace names into module `m`.
# Context-specific helper *implementations* (echart/tables/refresh) are passed in;
# the SET of names, the widget constructors, and the `@bind` macro are defined here
# once. The per-eval `@bind` sink is task-local (run_capture seeds it); returns the populated module.
function _populate_notebook_ns!(m::Module; echart, EChart, slate_table, SlateTable,
                                slate_query, slate_refresh, slate_progress = (frac; msg = "", id = "", done = false) -> nothing,
                                slate_emit = (channel, data) -> nothing,
                                assetbase = () -> "")
    Core.eval(m, :(const echart = $echart))
    Core.eval(m, :(const EChart = $EChart))
    Core.eval(m, :(const WebPage = $WebPage))     # compose a self-contained HTML page (CSS/HTML/JS)
    Core.eval(m, :(const series = $series))       # ECharts DSL series builder (echarts_dsl.jl)
    Core.eval(m, :(const animate = $animate))     # animate(frames;…) → Animation (animation.jl)
    Core.eval(m, :(const slate_table = $slate_table))
    Core.eval(m, :(const SlateTable = $SlateTable))
    Core.eval(m, :(const slate_query = $slate_query))
    Core.eval(m, :(const slate_refresh = $slate_refresh))
    Core.eval(m, :(const slate_progress = $slate_progress))   # slate_progress(frac; msg) → live cell progress
    Core.eval(m, :(const slate_emit = $slate_emit))           # slate_emit(channel, data) → live push to a cell's custom JS (cellstream:)
    # JS→Julia CALLS — the request/response counterpart to `slate_emit`'s push. A cell registers
    # `slate_on("channel", args -> result)`; browser JS calls `await window.slateCall("channel", args)`.
    # The `__slate_call` worker tool (dispatched off the page WebSocket on the interactive thread) looks
    # the handler up in this per-namespace registry and invokes it. Fresh dict per namespace, so a
    # rebuild drops stale closures; a cell re-run just replaces its channel's handler.
    Core.eval(m, :(const __slate_handlers = $(Dict{String,Any}())))
    Core.eval(m, :(const slate_on = (channel, f) -> (__slate_handlers[string(channel)] = f; nothing)))
    # Invoke a `slate_on` handler FROM Julia (same as `window.slateCall` does from JS, but in-process —
    # no round-trip). For testing a handler in a cell, or wiring one to a control:
    # `@onclick go slate_call("compute", (n = n_slider,))`. Errors if the channel isn't registered.
    Core.eval(m, :(function slate_call(channel, args = nothing)
        f = get(__slate_handlers, string(channel), nothing)
        f === nothing && error("no slate_on handler registered for channel '" * string(channel) * "'")
        return f($(_slate_args)(args))   # NamedTuple-shape, same as the JS call path — `args.field`
    end))
    Core.eval(m, :(const slate_fingerprint = $slate_fingerprint))   # canonical value hash (fingerprint.jl)
    Core.eval(m, :(const slate_memo_stats = $slate_memo_stats))     # durable memo store: shape
    Core.eval(m, :(const slate_memo_entries = $slate_memo_entries)) # durable memo store: entry listing
    Core.eval(m, :(const Widget = $Widget))
    Core.eval(m, :(const Choice = $Choice))
    Core.eval(m, :(const Selection = $Selection))
    Core.eval(m, :(const indices = $indices))
    for nm in _WIDGET_CTORS
        Core.eval(m, :(const $nm = $(getfield(@__MODULE__, nm))))
    end
    # Per-notebook bind state, closed over by the injected helpers. `reglock` serializes registry
    # mutation across concurrently-evaluated cells (the parallel batch); the per-eval sink is
    # task-local (seeded by run_capture), so it needs no lock.
    reg = Dict{Symbol,Tuple{Widget,Any}}()
    reglock = ReentrantLock()
    handlers = Dict{Symbol,Any}()                 # @onclick: button name → handler closure (event model)
    tokens = Dict{Symbol,Base.RefValue{Bool}}()   # button name → running handler's cancel token
    Core.eval(m, :(const __slate_bind_registry = $reg))
    Core.eval(m, :(const __slate_bind = $((name, w) -> _do_bind(reg, reglock, name, w))))
    # Browser value change: coerce + update registry, set the global so readers see it, then
    # DISPATCH to any registered @onclick handler (so a button is an event — the handler fires
    # here, NOT by recomputing a cell that reads the button). Returns the coerced value for the host.
    Core.eval(m, :(const __slate_set_bind = $((name, value) -> begin
        cv = _do_set_bind(reg, reglock, name, value)
        w = lock(reglock) do; reg[name][1]; end
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
    # `@reactive name = init` — sugar for `name = reactive(:name, init)`. Derives the reactive's NAME
    # from the binding, so the name (which routes the refresh to the cells that read `name`) can never
    # drift from the variable — removing the `reactive(:name, …)` double-spell footgun.
    Core.eval(m, :(macro reactive(ex)
        (ex isa Expr && ex.head === :(=) && ex.args[1] isa Symbol) ||
            error("@reactive expects `name = init` (e.g. `@reactive level = 0`)")
        nm = ex.args[1]
        esc(Expr(:(=), nm, Expr(:call, :reactive, QuoteNode(nm), ex.args[2])))
    end))
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
    # ── Asset inclusion (`@asset` / `readfile`) ───────────────────────────────────
    # `@asset "portfolio.js"` reads a file (resolved relative to the notebook's PROJECT dir via
    # `assetbase`, or an absolute path) and returns its contents. Because the path is a source
    # LITERAL, the dependency analyzer records it statically (deps.jl `_collect_asset_paths!`), so
    # editing the file invalidates the cell's memo entry (and, with the watcher, re-runs the cell).
    # `@asset bytes "logo.png"` → `Vector{UInt8}`. `readfile(path)` is the runtime escape hatch for a
    # COMPUTED path — not statically tracked (the documented dynamic caveat).
    Core.eval(m, :(const __slate_assetbase = $assetbase))
    Core.eval(m, :(function __slate_readfile(p::AbstractString; bytes::Bool = false)
        base = __slate_assetbase()
        ap = isabspath(p) ? String(p) : joinpath(isempty(base) ? pwd() : base, String(p))
        ap = expanduser(ap)   # a remote worker's asset base is `~/.cache/…` (tilde) — `read`/`open` don't expand it
        return bytes ? read(ap) : read(ap, String)
    end))
    Core.eval(m, :(const readfile = __slate_readfile))
    Core.eval(m, :(macro asset(args...)
        bytes = false; path = nothing
        for a in args
            a === :bytes ? (bytes = true) : (path = a)
        end
        path === nothing && error("@asset needs a path, e.g. @asset \"file.js\" (or @asset bytes \"logo.png\")")
        return esc(:(__slate_readfile($(path); bytes = $(bytes))))
    end))
    # ── Portable data storage (`datadir()` / `@sfile`) ────────────────────────────
    # `datadir()` is the notebook's canonical DATA directory — `<project>/data`, created on demand.
    # A stable place to read AND write data files without hardcoding a machine path, so the notebook
    # stays portable between machines. `@sfile "data.csv"` returns a PATH under it — contrast
    # `@asset`, which reads a file's CONTENTS; `@sfile` is big-file / read-write friendly:
    # `CSV.read(@sfile("data.csv"), DataFrame)` · `CSV.write(@sfile("out.csv"), result)`.
    # (v2: a referenced blob transfers content-addressed over the data channel to remote workers.)
    Core.eval(m, :(function datadir()
        # A region/worker can PIN its data root via `KAIMONSLATE_DATADIR` (a fast scratch disk, a
        # shared mount that already holds the data, …); otherwise it's `<project>/data`. Resolves
        # PER SITE, which is what lets `@sfile` follow the compute across a region boundary.
        r = strip(get(ENV, "KAIMONSLATE_DATADIR", ""))
        b = __slate_assetbase()
        d = !isempty(r) ? String(r) : (isempty(b) ? joinpath(pwd(), "data") : joinpath(b, "data"))
        try
            mkpath(d)
            gi = joinpath(d, ".gitignore")
            isfile(gi) || write(gi, "*\n")   # a data dir isn't source — self-ignore so a DB never gets tracked
        catch
        end
        return d
    end))
    # Resolve a name (which MAY contain subdirs, `joinpath`-style: `@sfile("raw/2025/x.duckdb")`)
    # under `datadir()`, ensuring the parent dir exists so a WRITE target is usable immediately. This
    # is the portable way to build paths — anchor on `datadir()`, never `homedir()`/an absolute path,
    # which resolve differently (or not at all) on a remote site.
    Core.eval(m, :(function __slate_dpath(name::AbstractString)
        p = joinpath(datadir(), String(name))
        try; mkpath(dirname(p)); catch; end
        return p
    end))
    Core.eval(m, :(macro sfile(parts...)
        # `@sfile "a" "b" "c.csv"` OR `@sfile "a/b/c.csv"` — join the parts, then resolve under datadir.
        return esc(:(__slate_dpath(joinpath($(parts...)))))
    end))
    # `@use "d3" => "https://esm.sh/d3@7"` — DECLARE a browser ES-module import at the NOTEBOOK level.
    # A runtime no-op: it's a declaration, statically extracted by the engine (deps.jl `_scan_imports!`)
    # and merged into the page's `<script type="importmap">` in the shell `<head>` (live) and the export
    # `<head>` — so notebook front-end JS can `import * as d3 from "d3"`. The import map is fixed at
    # document load, so adding/changing a `@use` needs a page reload to take effect (editing JS content
    # stays instant). Literal string args so the declaration is visible without running the cell.
    Core.eval(m, :(macro use(args...)
        return :(nothing)
    end))
    return m
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

# (name::Symbol, init_expr) if `ex` is `@reactive name = init`, else nothing. Lets the dependency
# analysis see through the sugar: `name` is a WRITE (this cell DEFINES the reactive producer — readers
# depend on it and its refresh routes here by that name); `init`'s free vars are reads.
function _reactive_macrocall(ex)
    (ex isa Expr && ex.head === :macrocall && ex.args[1] === Symbol("@reactive")) || return nothing
    real = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    (length(real) == 1 && real[1] isa Expr && real[1].head === :(=) && real[1].args[1] isa Symbol) || return nothing
    return (real[1].args[1], real[1].args[2])
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
