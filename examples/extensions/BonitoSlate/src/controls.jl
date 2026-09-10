# ── Slate controls, drawn natively inside a figure ────────────────────────────────────────────────
#
# `bonito_controls(:decay, :freq)` builds a real Bonito widget per named `@bind` control and returns
# a DOM node you compose into an App — so the knobs live in the figure card, next to the thing they
# drive, instead of in the notebook's control strip above it.
#
# The Slate control stays authoritative. These widgets are a second VIEW of it, not a second copy:
# the value still lives in Slate's registry, still coerces against the declared widget, still fires
# `@onchange`, still feeds `bind_observable`, and is still a parameter in a static export. Pair with
# `hidden(…)` at the `@bind` site to suppress the notebook's own widget, so a reader sees one
# control rather than two that can drift.

"""
    bonito_controls(session, names...; layout = :column, labels = true) -> Bonito.DOM node

Native Bonito widgets for the named Slate `@bind` controls, for placing inside a figure.

`session` is the one an `App` hands its body — the write-back is installed on it, which is how a
widget change reaches Slate without a Julia round trip.

```julia
@bind decay hidden(Slider(0.0:0.05:1.5))     # no notebook chrome — drawn below instead

App() do session
    DOM.div(bonito_controls(session, :decay), fig)
end
```

`bonito_controls(session, :all)` takes every control the notebook declares.

Each widget is built from the control's OWN declared spec (its range, options, labels), so the two
cannot disagree about what values are legal. Changes are written back through Slate's normal path,
which is what keeps every other reader of the variable — cells, `@onchange`, the persisted value,
the export — in step.
"""
function bonito_controls(session, names::Symbol...; layout::Symbol = :column, labels::Bool = true)
    ctx = SlateExtensionsBase.slate_context()
    ctx === nothing && error("bonito_controls must run inside a Slate cell (no execution context)")
    isempty(names) && error("bonito_controls: name at least one control, e.g. bonito_controls(:decay)")

    # `:all` — every control the notebook declares, in name order. Convenient for a scratch figure;
    # name them explicitly once the notebook has controls that belong elsewhere.
    wanted = (length(names) == 1 && names[1] === :all) ? _slate_bind_names() : collect(names)
    isempty(wanted) && error("bonito_controls(:all): this notebook declares no @bind controls")

    rows = Any[]
    for nm in wanted
        w = _slate_widget(nm)
        w === nothing &&
            error("bonito_controls(:$nm): no such control — declare it first with `@bind $nm …`")
        push!(rows, _control_row(session, nm, w, labels))
    end

    style = layout === :row ?
        "display:flex;flex-direction:row;gap:14px;align-items:center;flex-wrap:wrap;margin-bottom:8px" :
        "display:flex;flex-direction:column;gap:6px;margin-bottom:8px"
    return Bonito.DOM.div(rows...; style = style, class = "bonito-slate-controls")
end

# The bind surface comes off the Slate execution context, which carries the capability rather than
# the namespace: `bind_widget` / `bind_value` / `on_bind` / `bind_observable` / `bind_names`. Reading
# `__slate_bind_registry` directly would work today and tie this extension to a private name.
_ctx_call(f::Symbol, args...; default = nothing) = begin
    g = SlateExtensionsBase._ctx_field(f)
    g === nothing ? default : g(args...)
end

"The Slate `Widget` (kind + params + default) behind a bound name; `nothing` if undeclared."
_slate_widget(name::Symbol) = _ctx_call(:bind_widget, name)

"A control's current value, so a rebuilt widget opens where the reader left it."
_slate_value(name::Symbol) = _ctx_call(:bind_value, name)

"Every control declared in this notebook, for `bonito_controls(:all)`."
_slate_bind_names() = _ctx_call(:bind_names; default = Symbol[])

# One labelled widget row.
function _control_row(session, name::Symbol, w, labels::Bool)
    widget = _build_widget(name, w)
    _wire_writeback!(session, name, widget)
    lbl = String(get(w.params, "label", string(name)))
    return labels ?
        Bonito.DOM.div(
            Bonito.DOM.span(lbl; style = "color:var(--dim,#6a7090);font:12px monospace;min-width:7em"),
            widget;
            style = "display:flex;flex-direction:row;gap:8px;align-items:center",
        ) : widget
end

# Slate widget kind → the closest Bonito widget, built from the SAME declared domain so the two
# cannot disagree about what is legal. Kinds with no faithful Bonito equivalent are refused by name
# rather than silently approximated — a control that looks right and edits the wrong thing is worse
# than one that says it is unsupported.
function _build_widget(name::Symbol, w)
    p = w.params
    cur = _slate_value(name)
    kind = w.kind

    if kind == "slider"
        lo, hi = Float64(get(p, "min", 0)), Float64(get(p, "max", 1))
        st = Float64(get(p, "step", (hi - lo) / 100))
        st <= 0 && (st = (hi - lo) / 100)
        vals = collect(lo:st:hi)
        isempty(vals) && (vals = [lo])
        return Bonito.Slider(vals; value = _clamp_to(vals, cur))
    elseif kind in ("checkbox", "toggle")
        return Bonito.Checkbox(cur === nothing ? Bool(w.default) : Bool(cur))
    elseif kind == "number"
        return Bonito.NumberInput(cur === nothing ? Float64(w.default) : Float64(cur))
    elseif kind in ("text", "textarea", "color", "date", "time")
        return Bonito.TextField(cur === nothing ? string(w.default) : string(cur))
    elseif kind in ("select", "radio")
        opts = _option_values(p)
        isempty(opts) && error("bonito_controls(:$name): the control declares no options")
        idx = something(findfirst(==(cur), opts), 1)
        return Bonito.Dropdown(opts; index = idx)
    elseif kind == "button"
        return Bonito.Button(String(get(p, "label", "Click")))
    end
    error("bonito_controls(:$name): no native Bonito widget for a '$kind' control — " *
          "leave this one to Slate's own chrome (drop the `hidden(…)`)")
end

# The option VALUES of a select/radio, in declared order. Slate stores them as `opts` entries that
# are either bare values or {value,label} pairs.
function _option_values(p)
    raw = get(p, "options", get(p, "opts", Any[]))
    out = Any[]
    for o in raw
        if o isa AbstractDict
            push!(out, get(o, "value", get(o, :value, o)))
        elseif o isa NamedTuple && hasproperty(o, :value)
            push!(out, o.value)
        else
            push!(out, o)
        end
    end
    return out
end

# Nearest legal value, so a control whose current value is not exactly on the widget's grid (a float
# range rarely contains a stored value bit-exactly) opens on the closest tick instead of throwing.
function _clamp_to(vals, cur)
    cur === nothing && return first(vals)
    cur in vals && return cur
    (cur isa Real && eltype(vals) <: Real) || return first(vals)
    return vals[argmin(abs.(vals .- cur))]
end

# ── Write-back, and the echo guard ────────────────────────────────────────────────────────────────
#
# A widget change drives Slate through `window.slateSetBind`, the SAME path a native Slate widget
# takes — so the registry, the global, `@onchange`, the notebook's chrome and the persisted value
# all move together. Doing it in JS rather than round-tripping through Julia keeps a drag at browser
# speed and means the authoritative write happens in one place.
#
# THE ECHO. Reflection is the other direction: when the control changes elsewhere (another widget, a
# cell, `set_bind` from an agent), Slate pushes the new value into this widget so it does not sit
# there showing a stale position. That push fires the widget's own change handler, which would write
# straight back to Slate, which would push again. The guard is to compare against what Slate already
# holds — `window.slateBindValue(name)` — and write only on a genuine difference. A reflected value
# is by definition equal to it, so the echo stops at the first hop, while a real drag (which differs)
# always gets through. No timers, no suppression flags to leak, and nothing to get stuck "on".
function _wire_writeback!(session, name::Symbol, widget)
    obs = _widget_value_observable(widget)
    obs === nothing && return nothing
    nm = String(name)
    Bonito.onjs(session, obs, Bonito.js"""
    (v) => {
        if (!window.slateSetBind) return;                       // core too old / not a Slate page
        const cur = window.slateBindValue ? window.slateBindValue($(nm)) : undefined;
        if (cur === v) return;                                  // reflected value — not a user edit
        window.slateSetBind($(nm), v);
    }
    """)
    return nothing
end

# The Observable carrying a Bonito widget's value, across the widget types we build.
function _widget_value_observable(widget)
    for f in (:value, :index, :content)
        hasproperty(widget, f) || continue
        v = getproperty(widget, f)
        v isa Observables.AbstractObservable && return v
    end
    return nothing
end
