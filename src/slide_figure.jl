# ── A Makie figure that builds on a slide ─────────────────────────────────────────────────────────
# `slide_figure(fig; steps)` renders a figure in successive states: each step changes the figure (plots
# appear, the rest dims, the camera moves, an observable sweeps) and the result is rendered with the
# notebook's own Makie backend. A step without `frames` is one image the deck crossfades to; a step
# with `frames` is a short clip rendered frame by frame, so camera moves and fills are smooth. The
# states are stacked in one HTML block, each tagged with its build step, so the deck's step counter
# reveals them in turn; in the notebook the last state is what shows. The images and clips are saved as
# cell assets (`save_asset`): they ride with the cell's cached result and an export, and the HTML holds
# only their paths, which the page resolves (core.js `_hydrateAssetMedia`).
#
# Makie is reached at runtime through whatever backend the notebook loaded (as `slate_look.jl` does),
# so neither the engine nor the worker depends on it.

# The colours of named math terms (`\termc{name}{red}{…}`, core.js `SLATE_TERM_PALETTE`), for a figure
# to use the same red as the equation beside it.
const SLATE_COLORS = (blue = "#58c4dd", yellow = "#f4d345", red = "#fc6255", green = "#83c167",
                      purple = "#a98bd8", orange = "#f39c4b", teal = "#4fd1c5", pink = "#e879b9",
                      lime = "#c5e063", sky = "#8ab4ff")

"""
    slate_color(name) -> String

A colour from the palette the slide math uses for terms (`blue yellow red green purple orange teal pink
lime sky`), as a hex string Makie accepts. `\\termc{unstable}{red}{W^u}` in an equation and
`color = slate_color(:red)` in a figure are the same red.
"""
slate_color(name) = getproperty(SLATE_COLORS, Symbol(name))

struct SlideFigure
    w::Int
    h::Int
    base::String                           # asset path of the figure before any step (PNG)
    layers::Vector{Tuple{Int,Symbol,String,String}}   # (step, :png | :mp4, asset path, poster PNG path or "")
end

_mk() = _need_makie()
_mkcall(f, args...; kw...) = Base.invokelatest(f, args...; kw...)

_plots_of(x) = x === nothing ? Any[] : x isa Union{AbstractVector,Tuple} ? collect(Any, Iterators.flatten(_plots_of.(x))) : Any[x]

function _png_bytes(fig, ppu)
    Mk = _mk()
    path = tempname() * ".png"
    try
        _mkcall(Mk.save, path, fig; px_per_unit = ppu)
        return read(path)
    finally
        rm(path; force = true)
    end
end

function _setvis!(p, v::Bool)
    try; p.visible[] = v; catch; end
end
_getalpha(p) = try; p.alpha[]; catch; nothing; end
_setalpha!(p, a) = try; p.alpha[] = a; catch; end

# Every plot drawn in the figure's axes, for `focus` to dim the rest.
function _all_plots(fig)
    Mk = _mk()
    out = Any[]
    for c in fig.content
        (c isa Mk.Axis || (isdefined(Mk, :Axis3) && c isa Mk.Axis3)) || continue
        append!(out, c.scene.plots)
    end
    return out
end

# Interpolated axis limits, `t` in [0, 1], eased in and out.
_ease(t) = t < 0.5 ? 4t^3 : 1 - (-2t + 2)^3 / 2
function _limits_at(from, to, t)
    s = _ease(t)
    return ntuple(i -> from[i] + (to[i] - from[i]) * s, 4)
end
function _current_limits(ax)
    r = ax.finallimits[]
    o, w = r.origin, r.widths
    return (o[1], o[1] + w[1], o[2], o[2] + w[2])
end

"""
    slide_figure(fig; steps, fps = 30, px_per_unit = 1.5) -> SlideFigure

A Makie figure that builds on a slide, one state per build step. `steps` is a vector; each entry is a
NamedTuple saying what changes on that step:

- `show = plots` — those plots appear (they are hidden until their step);
- `hide = plots` — those plots go;
- `focus = plots` — every other plot dims until the next step that sets `focus`; `focus = nothing` undims.
  A plot shown later while the rest is dimmed joins the focus;
- `limits = (ax, (x1, x2, y1, y2))` — the axis moves to that window (smoothly, with `frames`);
- `animate = t -> …` — called with `t` from 0 to 1 to change the figure, typically setting observables
  (`n[] = round(Int, t * N)` to draw a section point by point);
- `update = () -> …` — any other change, made once;
- `frames = n` — render the step as an `n`-frame clip at `fps` instead of one image.

A plot is anything Makie returns from `lines!`, `scatter!`, `callout!`, …; pass several as a vector.
The steps share the slide's step counter with its other builds (step `i` here is build step `i`).
Rendering mutates `fig`, which ends in its final state.

```julia
fig = Figure(); ax = Axis(fig[1, 1])
sec = scatter!(ax, R, Z; markersize = 1, color = :gray70)
wu = lines!(ax, Ru, Zu; color = slate_color(:red))
xp = callout!(ax, (RX, ZX), "X-point")
slide_figure(fig; steps = [(show = wu,), (show = xp, focus = [wu, xp]),
                           (limits = (ax, (RX - w, RX + w, ZX - w, ZX + w)), frames = 45)])
```
"""
function slide_figure(fig; steps = NamedTuple[], fps::Integer = 30, px_per_unit::Real = 1.5)
    Mk = _mk()
    shown = Any[]
    for st in steps
        haskey(st, :show) && append!(shown, _plots_of(st.show))
    end
    foreach(p -> _setvis!(p, false), shown)
    w, h = Int.(round.(_mkcall(size, fig.scene)))
    save(name, bytes, mime) = _save_asset(name, bytes; mime).path
    base = save("slidefig-0.png", _png_bytes(fig, px_per_unit), "image/png")
    alphas = IdDict{Any,Any}()             # plots dimmed by the current focus → their own alpha
    layers = Tuple{Int,Symbol,String,String}[]
    for (i, st) in enumerate(steps)
        if haskey(st, :show)
            for p in _plots_of(st.show)
                _setvis!(p, true)
                # A plot that arrives while others are dimmed is the new subject: it joins the focus.
                haskey(alphas, p) && (_setalpha!(p, alphas[p]); delete!(alphas, p))
            end
        end
        haskey(st, :hide) && foreach(p -> _setvis!(p, false), _plots_of(st.hide))
        if haskey(st, :focus)
            for (p, a) in alphas; _setalpha!(p, a); end
            empty!(alphas)
            keep = _plots_of(st.focus)
            if !isempty(keep)
                for p in _all_plots(fig)
                    any(k -> k === p, keep) && continue
                    a = _getalpha(p); a === nothing && continue
                    alphas[p] = a
                    _setalpha!(p, a * 0.22)
                end
            end
        end
        haskey(st, :update) && Base.invokelatest(st.update)
        n = Int(get(st, :frames, 0))
        lim = get(st, :limits, nothing)
        anim = get(st, :animate, nothing)
        if n > 1 && (lim !== nothing || anim !== nothing)
            from = lim === nothing ? nothing : _current_limits(lim[1])
            path = tempname() * ".mp4"
            try
                frame = k -> begin
                    t = (k - 1) / (n - 1)
                    lim === nothing || _mkcall(Mk.limits!, lim[1], _limits_at(from, lim[2], t)...)
                    anim === nothing || Base.invokelatest(anim, t)
                end
                Base.invokelatest(Mk.record, frame, fig, path, 1:n; framerate = fps)
                push!(layers, (i, :mp4, save("slidefig-$i.mp4", read(path), "video/mp4"),
                               save("slidefig-$i-end.png", _png_bytes(fig, px_per_unit), "image/png")))
            finally
                rm(path; force = true)
            end
        else
            lim === nothing || _mkcall(Mk.limits!, lim[1], lim[2]...)
            anim === nothing || Base.invokelatest(anim, 1.0)
            push!(layers, (i, :png, save("slidefig-$i.png", _png_bytes(fig, px_per_unit), "image/png"), ""))
        end
    end
    return SlideFigure(w, h, base, layers)
end

_attr(x) = replace(String(x), '&' => "&amp;", '"' => "&quot;", '<' => "&lt;")

function Base.show(io::IO, ::MIME"text/html", sf::SlideFigure)
    print(io, "<div class=\"slidefig\" style=\"--sf-ar:", round(sf.w / sf.h; digits = 4), ";max-width:", sf.w,
              "px;aspect-ratio:", sf.w, "/", sf.h, "\">")
    print(io, "<img class=\"sf-base\" alt=\"\" data-slate-src=\"", _attr(sf.base), "\">")
    for (i, kind, path, poster) in sf.layers
        if kind === :png
            print(io, "<img class=\"step fade sf-layer\" step=\"", i, "\" alt=\"\" data-slate-src=\"", _attr(path), "\">")
        else
            print(io, "<video class=\"step fade sf-layer sf-anim\" step=\"", i, "\" muted playsinline preload=\"auto\" ",
                      "data-slate-poster=\"", _attr(poster), "\" data-slate-src=\"", _attr(path), "\"></video>")
        end
    end
    print(io, "</div>")
end

"""
    callout!(ax, (x, y), label; offset = (40, 40), color = :white, fontsize = 26) -> plots

A label pinned to a point of the data: a dot, a fine leader line, and the label `offset` pixels away.
The leader keeps its length on screen as the axis zooms. Returns its plots, so a step can `show` it.
"""
function callout!(ax, pt, label; offset = (40, 40), color = :white, fontsize = 26, linewidth = 1.5)
    Mk = _mk()
    x, y = Float64(pt[1]), Float64(pt[2])
    ox, oy = Float64(offset[1]), Float64(offset[2])
    dot = _mkcall(Mk.scatter!, ax, [x], [y]; color, markersize = 7)
    # Pixels → data units from the axis's current window, so the leader follows a zoom.
    lead = (lims, vp) -> begin
        sx = lims.widths[1] / max(vp.widths[1], 1); sy = lims.widths[2] / max(vp.widths[2], 1)
        [Mk.Point2f(x, y), Mk.Point2f(x + 0.85 * ox * sx, y + 0.85 * oy * sy)]
    end
    ends = Base.invokelatest(Mk.lift, lead, ax.finallimits, ax.scene.viewport)
    seg = _mkcall(Mk.lines!, ax, ends; color = (color, 0.85), linewidth)
    lbl = _mkcall(Mk.text!, ax, x, y; text = String(label), color, fontsize, offset = (Float32(ox), Float32(oy)),
                  align = (ox >= 0 ? :left : :right, oy >= 0 ? :bottom : :top))
    return Any[dot, seg, lbl]
end
