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
# The @bind CONTRACT (Widget/Choice/Selection/WebPage + the per-kind value-lifecycle registry) lives
# in the lean SlateExtensionsBase SDK, so an external package can build controls against it without
# depending on KaimonSlate. This file supplies the built-in widget CONSTRUCTORS + `@bind` macro and
# registers the built-in kinds through the SAME `register_kind!` seam a third party uses. SEB reaches
# both namespaces: the engine via KaimonSlate's Project.toml dep, the standalone worker via the
# slate-owned worker_infra env on LOAD_PATH.
import Markdown # stdlib — `@md` renders a standalone-run markdown cell (see `_populate_notebook_ns!`)
using SlateExtensionsBase: SlateExtensionsBase, Widget, Choice, Selection, indices, WebPage,
                           to_widget, register_kind!, coerce_bind, reconcile_bind, wrap_value

# The SlateExtensionsBase extension manifest for THIS process — the front-end scripts (and, in time,
# other package registrations) that the loaded packages declared, for the hub to mirror into the page.
# Defined here because widgets.jl is included into both ReportEngine (the in-process kernel reads it
# directly) and the standalone SlateWorker (the `__slate_extension_manifest` gate tool returns it).
#
# `ns` is the notebook namespace (`_NS[]` in a worker, `report_module(nb.report)` in-process): reading the
# manifest is also when Slate fires each loaded package's PACKAGE-GLOBAL front-end hook
# (`M.__slate_frontend(slate_on)` — editor extensions + JS→Julia handlers with no bind to trigger them),
# handing it that namespace's injected `slate_on`. So a package's editor-ext + handlers register lazily
# from the once-per-drain manifest pull, no `__init__` and no boot cell. Idempotent (see the hook).
function inprocess_extension_manifest(ns::Union{Module,Nothing} = nothing)
    if ns !== nothing && Base.invokelatest(isdefined, ns, :slate_on)
        try
            # `invokelatest`: `slate_on` is `Core.eval`'d into `ns`, possibly in a newer world than
            # here — reading it directly warns under Julia 1.12's global world-age rules.
            SlateExtensionsBase.ensure_module_frontends!(Base.invokelatest(getglobal, ns, :slate_on))
        catch
        end
    end
    return SlateExtensionsBase.extension_manifest()
end

# slate_fingerprint + memo-store introspection — shared notebook helpers injected below
# (one include here serves both namespaces, mirroring how this file itself is shared).
include(joinpath(@__DIR__, "fingerprint.jl"))

# Markdown variable interpolation: `{{ expr }}` blocks are captured (rich) and spliced into the
# rendered prose; the md cell reads their free variables so it re-renders reactively. The scan is
# brace-balanced and string-aware, so the closing `}}` is never confused with braces inside the
# expression — e.g. `Dict(:a=>1)`, `NamedTuple{(:a,)}(…)`, or a LaTeXString `L"\frac{a}{b}"`.
# `_md_template` (template-with-tokens + exprs) is shared by deps (reads), the renderer
# (substitution), AND the injected `@md` macro (standalone rendering) — so captures line up
# positionally. Lives HERE, not in engine.jl, because widgets.jl is included into BOTH ReportEngine
# and the standalone SlateWorker; the `@md` macro built in `_populate_notebook_ns!` needs it in both.
_interp_token(i::Int) = "xslateinterpx" * string(i; pad = 5) * "x"

function _md_template(src::AbstractString)
    s = String(src); out = IOBuffer(); exprs = String[]
    i = firstindex(s); n = lastindex(s)
    while i <= n
        c = s[i]
        if c == '{' && (i2 = nextind(s, i)) <= n && s[i2] == '{'
            k = nextind(s, i2); depth = 0; instr = false; closeat = 0
            while k <= n
                ck = s[k]
                if instr
                    if ck == '\\'
                        k = nextind(s, k); k <= n && (k = nextind(s, k)); continue
                    end
                    ck == '"' && (instr = false)
                    k = nextind(s, k)
                elseif ck == '"'
                    instr = true; k = nextind(s, k)
                elseif ck == '{'
                    depth += 1; k = nextind(s, k)
                elseif ck == '}'
                    if depth > 0
                        depth -= 1; k = nextind(s, k)
                    else
                        nk = nextind(s, k)
                        (nk <= n && s[nk] == '}') ? (closeat = k; break) : (k = nextind(s, k))
                    end
                else
                    k = nextind(s, k)
                end
            end
            if closeat > 0
                push!(exprs, String(strip(s[nextind(s, i2):prevind(s, closeat)])))
                print(out, _interp_token(length(exprs)))
                i = nextind(s, nextind(s, closeat))
                continue
            end
        end
        print(out, c); i = nextind(s, i)
    end
    return String(take!(out)), exprs
end

_md_interp_exprs(src::AbstractString) = _md_template(src)[2]

# ── Web cell: `{{ }}` interpolation, per-section escaping, and the `@web` skin ──────────────────
# A web cell is authored as tagged sections — `html"…"`, `css"…"`, `js"…"` — whose PREFIX names the
# language (the editor keys its CM6 mode off it). Notebook data reaches them ONLY through `{{ expr }}`
# (the same brace-balanced scanner markdown uses, so `$`/`${}` stay literal for JS), and the engine
# escapes each interpolated value for the section's language so a value can never break out of its
# context: HTML → entity-escaped text; CSS → a validated token; JS → a JSON literal. Values that
# "stringify easily" (String/Real/Bool/nothing, and Vector/Tuple/Dict/NamedTuple of those) round-trip
# faithfully; anything else falls back to its `string(...)` form as a safe JS/HTML string (the binary /
# large-array path is `save_asset`, not this). `_slate_json` is a tiny stdlib-only encoder (no JSON dep)
# so it works identically in the engine AND the Base+stdlib standalone worker, and it escapes `<`/`>`/
# U+2028/9 so a value is safe to embed inside a `<script>`.

function _slate_json_string(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"';       print(io, "\\\"")
        elseif c == '\\';  print(io, "\\\\")
        elseif c == '\n';  print(io, "\\n")
        elseif c == '\r';  print(io, "\\r")
        elseif c == '\t';  print(io, "\\t")
        elseif c == '<';   print(io, "\\u003c")   # so a value can't spell `</script>` and break out
        elseif c == '>';   print(io, "\\u003e")
        elseif UInt32(c) == 0x2028 || UInt32(c) == 0x2029   # JS line terminators — invalid raw in a JS string
            print(io, "\\u", string(UInt32(c); base = 16, pad = 4))
        elseif c < ' '
            print(io, "\\u", string(UInt16(c); base = 16, pad = 4))
        else               print(io, c)
        end
    end
    print(io, '"')
end

function _slate_json_to(io::IO, x)
    if x === nothing || x === missing
        print(io, "null")
    elseif x isa Bool                       # before Real — Bool <: Integer
        print(io, x ? "true" : "false")
    elseif x isa Integer
        print(io, x)
    elseif x isa Real
        isfinite(x) ? print(io, Float64(x)) : print(io, "null")   # NaN/Inf aren't valid JSON
    elseif x isa AbstractString
        _slate_json_string(io, x)
    elseif x isa Symbol
        _slate_json_string(io, string(x))
    elseif x isa NamedTuple
        print(io, '{')
        first = true
        for k in keys(x)
            first || print(io, ','); first = false
            _slate_json_string(io, string(k)); print(io, ':'); _slate_json_to(io, x[k])
        end
        print(io, '}')
    elseif x isa AbstractDict
        print(io, '{')
        first = true
        for (k, v) in x
            first || print(io, ','); first = false
            _slate_json_string(io, string(k)); print(io, ':'); _slate_json_to(io, v)
        end
        print(io, '}')
    elseif x isa Union{AbstractVector,Tuple,AbstractSet}
        print(io, '[')
        first = true
        for v in x
            first || print(io, ','); first = false
            _slate_json_to(io, v)
        end
        print(io, ']')
    else
        _slate_json_string(io, string(x))   # not JSON-shaped → its string form, as a safe JS/HTML string
    end
end

"Minimal stdlib-only JSON encoding of a `{{ }}` value, safe to embed inside a `<script>`."
_slate_json(x)::String = (io = IOBuffer(); _slate_json_to(io, x); String(take!(io)))

# Per-section escapers — chosen by the section's language so an interpolated value stays confined.
_web_esc_html(x)::String =
    replace(string(x), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;")
_web_esc_js(x)::String = _slate_json(x)
# CSS has no string-literal quoting for a bare value; keep numbers verbatim and drop the characters that
# could close a declaration/rule/comment so a value can't inject a new rule.
_web_esc_css(x)::String = x isa Real ? string(x) : replace(string(x), r"[{}();:<>\"'\\@]" => "")

const _WEB_SECTION_MACROS = (Symbol("@html_str") => :html,
                             Symbol("@css_str")  => :css,
                             Symbol("@js_str")   => :js)
_web_section_lang(nm) = (for (m, l) in _WEB_SECTION_MACROS; nm === m && return l; end; nothing)

# The tagged sections `(lang => raw)` of a `@web(...)` macrocall AST, in order — the shared reader for
# BOTH the editor (split into panes) and dependency analysis (harvest `{{ }}` reads). Returns `nothing`
# for anything that isn't a `@web` call. Tolerates a `:block`/`:toplevel` wrapper (parsed source).
function _web_macrocall_sections(ex)
    if ex isa Expr && ex.head in (:block, :toplevel)
        for a in ex.args
            s = _web_macrocall_sections(a)
            s === nothing || return s
        end
        return nothing
    end
    (ex isa Expr && ex.head === :macrocall && ex.args[1] === Symbol("@web")) || return nothing
    out = Tuple{Symbol,String}[]
    for a in ex.args[2:end]
        a isa LineNumberNode && continue
        (a isa Expr && a.head === :macrocall) || continue
        lang = _web_section_lang(a.args[1])
        raw = a.args[end]
        (lang === nothing || !(raw isa AbstractString)) && continue
        push!(out, (lang, String(raw)))
    end
    return out
end

# Every `{{ expr }}` string across a web cell's sections — used to compute the cell's reads (deps).
function _web_interp_exprs(src::AbstractString)
    ex = try; Base.Meta.parse(String(src)); catch; nothing; end
    secs = ex === nothing ? nothing : _web_macrocall_sections(ex)
    secs === nothing && return String[]
    exprs = String[]
    for (_, raw) in secs; append!(exprs, _md_interp_exprs(raw)); end
    return exprs
end

# Split a web cell's `@web(...)` source into its three panes for the editor. RAW text extraction (not
# `Base.Meta.parse`, which would triple-quote-DEDENT the sections) using the same regex + strip-one-
# leading/trailing-newline convention as `_web_skin` and the browser's `_webSkin`/`_webSections`, so the
# panes reassemble to the exact stored source — otherwise the reassembly drifts and the cell reads as
# spuriously "edited". Non-`@web` source (e.g. a freshly-converted code cell) falls back to the HTML pane.
function _web_sections(src::AbstractString)
    s = String(src)
    grab(tag) = begin
        m = match(Regex(tag * "\"\"\"([\\s\\S]*?)\"\"\""), s)
        m === nothing ? "" : replace(replace(String(m.captures[1]), r"^\n" => ""), r"\n$" => "")
    end
    html, css, js = grab("html"), grab("css"), grab("js")
    # No tagged sections at all → treat the whole body as HTML (the convert-to-web landing pane).
    (isempty(html) && isempty(css) && isempty(js) && !occursin("\"\"\"", s)) && (html = s)
    return (html = html, css = css, js = js)
end

# Assemble a runnable `@web(...)` skin from editor panes — the on-disk source of a web cell. Parenthesized
# and comma-separated so the sections (triple-quoted, multi-line) parse as one expression. Only non-empty
# sections are emitted; an entirely empty cell keeps an empty html section so it still parses.
function _web_skin(; html::AbstractString = "", css::AbstractString = "", js::AbstractString = "")
    secs = String[]
    for (tag, body) in (("html", html), ("css", css), ("js", js))
        isempty(strip(String(body))) && continue
        push!(secs, string(tag, "\"\"\"\n", body, "\n\"\"\""))
    end
    isempty(secs) && push!(secs, "html\"\"\"\"\"\"")
    return string("@web(", join(secs, ",\n"), ")")
end

# `Widget` (kind/params/default), `Choice`, `Selection` and `WebPage` are defined in
# SlateExtensionsBase (imported above) — the shared contract. The built-in constructors below build
# `Widget`s at runtime (no syntactic parsing, no `Slider`-name matching); the value lifecycle for
# each built-in kind is registered via `register_kind!` further down.

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

# A generic widget of a THIRD-PARTY kind — the Julia half of the widget extension point.
# Pair it with a front-end `slateRegisterWidget("<kind>", …)` (assets/js/view.js) that renders
# and wires the control in the browser. `params` cross to the browser as the spec's params; the
# value round-trips through `coerce_bind`'s identity default (unknown kinds pass through), so a
# string-valued custom widget needs no server-side coercion. Example:
#   @bind ans custom_widget("mathfield"; label = "your answer")
custom_widget(kind::AbstractString, default = ""; kwargs...) =
    Widget(String(kind), Dict{String,Any}(String(k) => v for (k, v) in kwargs), default)

const _WIDGET_CTORS = (:Slider, :NumberField, :Checkbox, :Toggle, :TextField, :TextArea,
                       :Select, :Radio, :MultiSelect, :MultiCheckBox, :ColorPicker, :DateField,
                       :TimeField, :Button, :playhead, :TableSelect, :custom_widget)

# ── Value lifecycle ───────────────────────────────────────────────────────────
# `coerce_bind` (browser value → Julia value), `reconcile_bind` (persistence across a bind-cell
# re-run) and `wrap_value` (registry value → user-facing value) are SlateExtensionsBase's per-kind
# registry (imported above). The built-in kinds register their hooks in `_register_builtin_kinds!()`
# below (after the option/label helpers), through the SAME `register_kind!` seam a third party uses —
# so a built-in widget is not privileged over an extension one.

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

# Register the value lifecycle for each built-in kind through SlateExtensionsBase's `register_kind!`
# — the SAME seam a third-party widget uses. Hooks: coerce(w, v) (browser value → Julia value),
# reconcile(ow, ov, nw) (bind-cell re-run, SAME kind — the kind-changed reset is generic, in
# `reconcile_bind`), wrap(w, v) (registry value → user-facing value). Runs once at module load.
function _register_builtin_kinds!()
    # Slider / Number — numeric. Key the int-vs-float coercion on the widget's DEFAULT type, not
    # `step`: a Float64 slider (`Slider(0.0, 10.0)`) defaults step to 1 (Integer), which would else
    # truncate its values to Int. Reconcile keeps the value while still within [min,max].
    numcoerce(w, v) = v isa Number ? ((w.default isa Integer && isinteger(v)) ? Int(round(v)) : float(v)) : v
    function numrecon(ow, ov, nw)
        lo = get(nw.params, "min", -Inf); hi = get(nw.params, "max", Inf)
        (ov isa Number && lo <= ov <= hi) ? ov : nw.default
    end
    for k in ("slider", "number")
        register_kind!(k; coerce = numcoerce, reconcile = numrecon)
    end
    # Checkbox / Toggle — boolean (reconcile keeps the value: the default).
    for k in ("checkbox", "toggle")
        register_kind!(k; coerce = (w, v) -> v === true || v == 1)
    end
    # Button / playhead — an integer counter / frame index.
    for k in ("button", "playhead")
        register_kind!(k; coerce = (w, v) -> v isa Number ? Int(round(v)) : v)
    end
    # TableSelect — the browser sends the clicked row's 1-based index; clamp to the known rows
    # (0 = none). The user-facing value is that row as a NamedTuple.
    register_kind!("tableselect";
        coerce = function (w, v)
            n = length(get(w.params, "rows", ()))
            i = v isa Number ? Int(round(v)) : 0
            (1 <= i <= n) ? i : 0
        end,
        reconcile = function (ow, ov, nw)
            n = length(get(nw.params, "rows", ()))
            (ov isa Integer && 1 <= ov <= n) ? ov : nw.default
        end,
        wrap = (w, v) -> _row_namedtuple(w, v isa Integer ? v : 0))
    # Select / Radio — the browser sends the option's stringified value; map it back to the real
    # value. A labeled option binds a `Choice` (value + label); a bare option stays its value.
    for k in ("select", "radio")
        register_kind!(k;
            coerce = function (w, v)
                for v0 in _opt_values(get(w.params, "options", ()))
                    string(v0) == string(v) && return v0
                end
                return v
            end,
            reconcile = (ow, ov, nw) -> (ov in _opt_values(get(nw.params, "options", ()))) ? ov : nw.default,
            wrap = (w, v) -> get(w.params, "labeled", false) === true ? _choice(w, v) : v)
    end
    # MultiSelect / MultiCheckBox — a set of stringified values; keep those still in the option set.
    # Labeled → a `Selection` (value+label dict); bare → the value vector.
    for k in ("multiselect", "multicheck")
        register_kind!(k;
            coerce = function (w, v)
                vals = _opt_values(get(w.params, "options", ()))
                sel = v isa AbstractVector ? v : (v === nothing ? Any[] : Any[v])
                ss = Set(string(s) for s in sel)
                Any[v0 for v0 in vals if string(v0) in ss]
            end,
            reconcile = function (ow, ov, nw)
                vals = _opt_values(get(nw.params, "options", ()))
                ov isa AbstractVector ? [v for v in ov if v in vals] : nw.default
            end,
            wrap = (w, v) -> get(w.params, "labeled", false) === true ? Selection(Choice[_choice(w, x) for x in v]) : v)
    end
    return nothing
end
_register_builtin_kinds!()

# The per-eval `@bind` sink is TASK-LOCAL, so cells evaluated CONCURRENTLY (the parallel batch) each
# collect their own controls instead of racing on one shared vector. `run_capture` seeds/reads it.
const _BIND_SINK_KEY = :__slate_binds

function _do_bind(reg::Dict{Symbol,Tuple{Widget,Any}}, reglock::ReentrantLock, name::Symbol, w0)
    # Lazily load this widget type's front-end the first time it's bound (dispatch on the type — a
    # package needs no `__init__`; a no-op for built-ins and any type with no `required_assets` method).
    SlateExtensionsBase.ensure_widget_assets!(typeof(w0))
    w = to_widget(w0)   # accept a Widget OR any value with a `to_widget` method (the extension seam)
    # The registry PERSISTS across evals and is shared, so a concurrent bind batch would resize the
    # Dict from two tasks at once — guard it. (The sink below is task-local, so it needs no lock.)
    val = lock(reglock) do
        prev = get(reg, name, nothing)
        v = if prev === nothing
            w.default
        elseif prev[1].kind == "?"
            # `"?"` is the placeholder `_do_set_bind` fabricates when the browser sets a value for a
            # name the registry doesn't know yet (a control-change race before this cell's first run).
            # Not a real "type changed" — coerce the pending value against the REAL widget.
            coerce_bind(w, prev[2])
        else
            reconcile_bind(prev[1], prev[2], w)   # keeps the value unless the new spec rejects it
        end
        reg[name] = (w, v)
        v
    end
    s = get(task_local_storage(), _BIND_SINK_KEY, nothing)
    s === nothing || push!(s, (name = name, kind = w.kind, params = w.params, value = val))
    return wrap_value(w, val)        # user gets a Choice for labeled option widgets; bare value otherwise
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
        w = prev[1]
        # A VALUELESS set on a button is a "click": increment its count server-side. A button's
        # value IS its click count, so this lets a caller (an agent / a script) press the button
        # without knowing — or racing — the current count. The browser always sends an explicit
        # value, so its path is unchanged.
        cv = value === nothing && w.kind == "button" ?
             (prev[2] isa Integer ? prev[2] : 0) + 1 :
             coerce_bind(w, value)
        reg[name] = (w, cv)
        return cv
    end
end

# `WebPage` (compose a self-contained HTML page from CSS/HTML/JS, rendering to ONE `text/html`
# output that works live and in a static export) is defined in SlateExtensionsBase and imported
# above — so an extension package can build one from its own module. It's injected into the notebook
# namespace by `_populate_notebook_ns!` below.

# Normalize call args to NAMED-TUPLE shape so a handler reads `args.n` (not `args["n"]`): a JSON object
# → NamedTuple (Symbol keys), arrays stay Vectors (recursing into elements so nested objects convert
# too), scalars pass through. Applied at BOTH handler boundaries (the WS `__slate_call` and `slate_call`),
# so a handler written against `args.field` works from JS and from Julia alike. `get(args, :n, default)`
# and `haskey` work as usual; a non-identifier JSON key lands as `var"my-key"` (reach it via
# `getproperty(args, Symbol("my-key"))`). Type-unstable by construction — fine for the fixed arg shapes
# a given call uses (the field names ARE the type); don't route huge dynamic key-sets through it.
_slate_args(x::AbstractDict) = NamedTuple{Tuple(Symbol.(keys(x)))}(Tuple(_slate_args(v) for v in values(x)))
_slate_args(x::AbstractVector) = Any[_slate_args(v) for v in x]
# A raw byte buffer (a `slateCall` binary buffer, delivered as `args.__slate_buffers`) is already a plain
# Base type — pass it through WHOLE. Without this it would hit the `AbstractVector` clause above and explode
# into a boxed `Vector{Any}` of `UInt8`, defeating the point of the binary transport.
_slate_args(x::Vector{UInt8}) = x
_slate_args(x) = x

# Invoke a `slate_on` handler with the (NamedTuple-shaped) call args. A 2-parameter handler
# `(args, progress) -> …` ALSO receives a `progress` closure it calls to stream progress frames back to
# the JS caller (framework-side, correlated to THIS call — the handler never sees a token or channel); a
# 1-parameter handler `args -> …` is called with just the args, so the 1-arg form keeps working. Arity is
# read from the handler's first method (an anonymous handler has exactly one).
_slate_handler_nparams(f) = try; first(methods(f)).nargs - 1; catch; 1; end
_invoke_slate_handler(f, sargs, progress) =
    _slate_handler_nparams(f) >= 2 ? Base.invokelatest(f, sargs, progress) : Base.invokelatest(f, sargs)

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
    Core.eval(m, :(const slate_theme = $slate_theme))             # shared ECharts/Makie look → a Makie Theme (slate_look.jl)
    Core.eval(m, :(const use_slate_theme! = $use_slate_theme!))   # apply it globally (needs Makie loaded)
    Core.eval(m, :(const animate = $animate))     # animate(frames;…) → Animation (animation.jl)
    Core.eval(m, :(const slate_table = $slate_table))
    Core.eval(m, :(const SlateTable = $SlateTable))
    Core.eval(m, :(const slate_matrix = $slate_matrix))   # explicit override — bare Matrix returns auto-render (capture.jl)
    Core.eval(m, :(const slate_query = $slate_query))
    Core.eval(m, :(const slate_refresh = $slate_refresh))
    Core.eval(m, :(const slate_progress = $slate_progress))   # slate_progress(frac; msg) → live cell progress
    Core.eval(m, :(const slate_emit = $slate_emit))           # slate_emit(channel, data) → live push to a cell's custom JS (cellstream:)
    # code→Slate cell-effects channel: a cell (or a package it calls) DECLARES an effect, attributed to the
    # executing statement, harvested into the wire (`CellOutput.effects`). `slate_effect` is transport-free
    # (task-local push, same impl everywhere — unlike slate_emit). Ergonomic sugar `slate_everywhere(names…)`
    # marks the current statement's registration as an `:everywhere` effect — the notebook/region analogue
    # of `Distributed.@everywhere` (Slate re-establishes it on every worker). Call it from INSIDE the
    # registering statement so the attribution lands there (a package's registrar self-declaring is the
    # zero-overhead path). No `@everywhere` MACRO is injected — it would clash with `Distributed.@everywhere`.
    Core.eval(m, :(const slate_effect = $_slate_effect))      # slate_effect(kind; names=…, data...) → declare a cell effect
    Core.eval(m, :(const save_asset = $_save_asset))          # save_asset(name, data) → AssetRef (write-side dual of @asset)
    Core.eval(m, :(slate_everywhere(names::Symbol...) = slate_effect(:everywhere; names = collect(names))))
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
        # NamedTuple-shape args (same as the JS call path — `args.field`); a 2-arg handler gets a no-op
        # progress here (in-process test invoke has no browser to stream to).
        return $(_invoke_slate_handler)(f, $(_slate_args)(args), (p) -> nothing)
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
    # The Slate execution context a fired @onclick/@onchange handler runs under, so it can STREAM
    # (`slate_emit`/`afm_emit`) just like a cell or a `slate_on` handler — same shape as `_build_slate_ctx`.
    # The fire path (`__slate_set_bind` → `__on_fire!`) runs on a server task with no context; this supplies it.
    bind_ctx = (; region = nothing, notebook = "", side = "", emit = slate_emit,
                  regions = Symbol[], effect = _slate_effect, on = getfield(m, :slate_on))
    Core.eval(m, :(const __slate_bind_registry = $reg))
    Core.eval(m, :(const __slate_bind = $((name, w) -> _do_bind(reg, reglock, name, w))))
    # Browser value change: coerce + update registry, set the global so readers see it, then
    # DISPATCH to any registered @onclick handler (so a button is an event — the handler fires
    # here, NOT by recomputing a cell that reads the button). Returns the coerced value for the host.
    Core.eval(m, :(const __slate_set_bind = $((name, value) -> begin
        cv = _do_set_bind(reg, reglock, name, value)
        w = lock(reglock) do; reg[name][1]; end
        wv = wrap_value(w, cv)
        Core.eval(m, Expr(:(=), name, wv))                    # user var is a Choice (labeled); host gets bare cv
        h = get(handlers, name, nothing)
        h === nothing || __on_fire!(tokens, name, h, wv, bind_ctx)   # dispatch @onclick/@onchange (streaming-capable)
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
    # `@md\"\"\"…\"\"\"` — render a markdown cell on a STANDALONE run (`julia notebook.jl`). Parses the
    # markdown (stdlib `Markdown`) and evaluates each `{{ expr }}` in the run scope, substituting its
    # string form back in — the SAME interpolation the engine does (`_md_template`), so a cell reads the
    # same live or standalone. In the Slate engine this macro is never reached: `parse_report` unwraps
    # the `@md` skin and the markdown pipeline handles the cell. Returns a `Markdown.MD` (renders in a
    # display context; the value is discarded — hence inert — in a plain `julia file.jl` script run).
    Core.eval(m, :(macro md(str)
        str isa AbstractString ||
            error("@md expects a string literal (e.g. @md\"\"\"# Title\"\"\")")
        tmpl, exprs = $(_md_template)(String(str))
        tokfn = $(_interp_token)
        mdparse = $(Markdown.parse)
        blk = Expr(:block, :(local __md_s = $tmpl))
        for (i, e) in enumerate(exprs)
            tok = tokfn(i)
            push!(blk.args, :(__md_s = replace(__md_s, $tok => string($(esc(Base.Meta.parse(e)))))))
        end
        push!(blk.args, Expr(:call, $(_standalone_show_md), Expr(:call, mdparse, :__md_s)))
        blk
    end))
    # ── Web cell (`@web html"…" css"…" js"…"`) ────────────────────────────────────
    # A web cell's SOURCE is a `@web(...)` call, so it evaluates like any code cell → a `WebPage`
    # (captured as HTML), live and standalone alike. The section macros name the language (the editor's
    # CM6 mode reads the prefix); `@web` expands each section's `{{ expr }}` into a per-language-escaped
    # substitution — HTML entity-escaped, CSS token-validated, JS as a JSON literal — so an interpolated
    # value can't break out of its context. `$`/`${}` are untouched (only `{{ }}` interpolates). The
    # bare section macros return their raw text, so `html"…"` used alone is just the string.
    Core.eval(m, :(macro html_str(s); s; end))
    Core.eval(m, :(macro css_str(s);  s; end))
    Core.eval(m, :(macro js_str(s);   s; end))
    Core.eval(m, :(macro web(args...)
        tmplfn = $(_md_template)
        tokfn  = $(_interp_token)
        langfn = $(_web_section_lang)
        escs   = (html = $(_web_esc_html), css = $(_web_esc_css), js = $(_web_esc_js))
        parts = Tuple{Symbol,String}[]
        for a in args
            a isa LineNumberNode && continue
            (a isa Expr && a.head === :macrocall) ||
                error("@web sections must be tagged string literals — html\"\"\"…\"\"\", css\"\"\"…\"\"\", js\"\"\"…\"\"\"")
            lang = langfn(a.args[1])
            lang === nothing && error("@web: unknown section $(a.args[1]) — use html/css/js")
            raw = a.args[end]
            raw isa AbstractString || error("@web section must be a string literal")
            push!(parts, (lang, String(raw)))
        end
        # Build the string-valued expr for one language: concatenate its (possibly repeated) sections,
        # each with its `{{ }}` tokens replaced by the escaped, evaluated value.
        secexpr = function (lang)
            escfn = getfield(escs, lang)
            chunks = Any[]
            for (l, raw) in parts
                l === lang || continue
                tmpl, exprs = tmplfn(raw)
                blk = Expr(:block, :(local __w = $tmpl))
                for (i, e) in enumerate(exprs)
                    push!(blk.args, :(__w = replace(__w, $(tokfn(i)) => $(escfn)($(esc(Base.Meta.parse(e)))))))
                end
                push!(blk.args, :__w)
                push!(chunks, blk)
            end
            isempty(chunks) ? "" : length(chunks) == 1 ? chunks[1] : Expr(:call, :string, chunks...)
        end
        # Hand the JS off to the frontend runtime `Slate.runFragment` (core.js — the mirror lives in the
        # static export too). It gives the fragment its own `root` (the cell's output element), an
        # `echo(...)` printer, a private scope (so a top-level `const`/`let` can't collide across the
        # re-runs of a reactive render), top-level `await` (`await import(…)`, `await Slate.asset(…)`), and
        # renders any thrown/rejected error ONTO the cell. The macro emits just the CALL — the runtime is
        # real, maintainable JS, not a string blob. (A JS *syntax* error can't be caught — the script never
        # parses — so it stays a console error.)
        jsx = secexpr(:js)
        jsx = (jsx isa AbstractString && isempty(jsx)) ? "" :
              Expr(:call, :string,
                   "Slate.runFragment(document.currentScript, async function(root, echo){\n", jsx, "\n});")
        Expr(:call, :WebPage, Expr(:parameters,
            Expr(:kw, :html, secexpr(:html)),
            Expr(:kw, :css,  secexpr(:css)),
            Expr(:kw, :js,   jsx)))
    end))
    return m
end

# ── Standalone runnability ────────────────────────────────────────────────────
# Standalone document output: on a non-interactive run (`julia notebook.jl`) a markdown cell's value
# is otherwise discarded, so print its rendered form to stdout — the notebook reads as a document, not
# just its code side-effects. In a REPL / `include` session the value displays normally, so skip (no
# double-render). `KAIMONSLATE_QUIET_MD=1` suppresses it entirely (code-only run). Only ever fires on a
# genuine standalone run — the Slate engine unwraps the `@md` skin at parse time and never calls it.
function _standalone_show_md(md)
    (isinteractive() || strip(get(ENV, "KAIMONSLATE_QUIET_MD", "")) in ("1", "true")) && return md
    try
        show(stdout, MIME("text/plain"), md)
        println(stdout)
    catch
    end
    return md
end

"""
    standalone!(m::Module = @__MODULE__; dir = nothing) -> Module

Inject the notebook-namespace contract into `m` so a Slate `.jl` runs as **plain Julia**
(`julia notebook.jl` / `include`), Pluto-style. This is the single lever that makes a
notebook runnable outside the Slate server: the same `_populate_notebook_ns!` contract is
installed, but the live-only features degrade to no-ops.

- `@bind x W(…)` → `x = W`'s default (empty registry, no browser wiring) — the real bind
  path, so it works with no special-casing.
- `echart` / `slate_table` / `slate_query` build their display objects as usual (pure
  constructors); they render via `show`/MIME if the run is display-capable, else are inert.
- `slate_refresh` / `slate_progress` / `slate_emit` / reactive fires → no-op.
- `@asset` / `readfile` / `datadir` / `@sfile` resolve against `dir` (the notebook file's
  directory), defaulting to `pwd()`.

Idempotent: a second call — or the Slate engine re-populating the same module — is a no-op
(guarded on the `__slate_standalone` marker), so the emitted preamble never double-injects.
"""
function standalone!(m::Module = Main; dir::Union{Nothing,AbstractString} = nothing)
    isdefined(m, :__slate_standalone) && return m
    base = dir === nothing ? "" : String(dir)
    _populate_notebook_ns!(m;
        echart = echart, EChart = EChart, slate_table = slate_table, SlateTable = SlateTable,
        slate_query = slate_query,
        slate_refresh = (vars...) -> nothing,        # reactive recompute is the engine's job — inert here
        assetbase = () -> base)                       # asset/data paths anchor on the notebook's dir
    Core.eval(m, :(const __slate_standalone = true))
    return m
end

# (name::Symbol, widget_expr) if `ex` is `@bind name W(…)`, else nothing. Pure AST,
# no evaluation — used by the engine's dependency analysis: the bound name is a
# write, the widget call's free variables are reads (so dynamic ranges like
# `Slider(1:step:hi)` make the bind cell depend on `step`/`hi`).
# (first::Symbol, second_expr) if `ex` is `@<name> first second` — LineNumberNodes stripped, ≥2 real
# args, first a Symbol — else nothing. The shared AST shape of the two-arg reactive macros below; each
# thin wrapper's own comment explains how its two args feed the dependency analysis.
function _two_arg_macrocall(ex, name::Symbol)
    (ex isa Expr && ex.head === :macrocall && ex.args[1] === name) || return nothing
    real = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    length(real) >= 2 || return nothing
    real[1] isa Symbol || return nothing
    return (real[1], real[2])
end

_bind_macrocall(ex) = _two_arg_macrocall(ex, Symbol("@bind"))

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
_onclick_macrocall(ex) = _two_arg_macrocall(ex, Symbol("@onclick"))

# (control::Symbol, body_expr) if `ex` is `@onchange ctrl body`, else nothing. The control is the
# handler PARAMETER (the new value), not a read of the global — so the cell doesn't recompute on
# change; only `body`'s OTHER free vars are reads, and `ctrl[]=`-style mutations are writes.
_onchange_macrocall(ex) = _two_arg_macrocall(ex, Symbol("@onchange"))
