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

# One state of a slide figure: the build step it belongs to, a still (`:png`) or a clip (`:video`) with
# the still it ends on as its poster, and the math terms it lights while it is the current step.
const SlideLayer = @NamedTuple{step::Int, kind::Symbol, path::String, poster::String, terms::Vector{String}}

struct SlideFigure
    w::Int
    h::Int
    base::String                           # asset path of the figure before any step (PNG)
    layers::Vector{SlideLayer}
end

# An orbit drawn along its points as a step plays: `t` (0 to 1) is how far along it is.
struct SlideTrace
    t::Any
    plots::Vector{Any}
end

_mk() = _need_makie()
_mkcall(f, args...; kw...) = Base.invokelatest(f, args...; kw...)

_plots_of(x) = x === nothing ? Any[] : x isa Union{AbstractVector,Tuple} ? collect(Any, Iterators.flatten(_plots_of.(x))) : Any[x]
_plots_of(x::SlideTrace) = x.plots
_traces_of(x) = x === nothing ? SlideTrace[] : x isa SlideTrace ? [x] : SlideTrace[x...]
_terms_of(x) = x === nothing ? String[] : x isa Union{AbstractString,Symbol} ? [String(x)] : String[String(t) for t in x]

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

# A figure whose background lets the slide show through. Its clips are VP9 WebM with an alpha channel,
# which an MP4 cannot carry.
_transparent(fig) = try
    _mkcall(_mk().to_color, fig.scene.backgroundcolor[]).alpha < 1
catch
    false
end

function _mp4_clip(fig, frame, n, fps)
    path = tempname() * ".mp4"
    try
        Base.invokelatest(_mk().record, frame, fig, path, 1:n; framerate = fps)
        return read(path)
    finally
        rm(path; force = true)
    end
end

function _webm_clip(fig, frame, n, fps, ppu)
    Mk = _mk()
    dir = mktempdir()
    try
        for k in 1:n
            frame(k)
            _mkcall(Mk.save, joinpath(dir, "f" * lpad(k, 4, '0') * ".png"), fig; px_per_unit = ppu)
        end
        out = joinpath(dir, "clip.webm")
        ff = Base.invokelatest(() -> Mk.FFMPEG_jll.ffmpeg())
        run(pipeline(`$ff -y -loglevel error -framerate $fps -i $(joinpath(dir, "f%04d.png")) -c:v libvpx-vp9
                      -pix_fmt yuva420p -b:v 0 -crf 30 -deadline good -cpu-used 4 -row-mt 1 $out`))
        return read(out)
    finally
        rm(dir; recursive = true, force = true)
    end
end

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

# Interpolated axis limits (four values for an `Axis`, six for an `Axis3`) and camera angles, `t` in
# [0, 1], eased in and out.
_ease(t) = t < 0.5 ? 4t^3 : 1 - (-2t + 2)^3 / 2
_lerp(from, to, t) = (s = _ease(t); ntuple(i -> from[i] + (to[i] - from[i]) * s, length(to)))
function _current_limits(ax)
    r = ax.finallimits[]
    o, w = r.origin, r.widths
    return Tuple(Iterators.flatten((o[i], o[i] + w[i]) for i in eachindex(o)))
end
# `view = (ax3, (azimuth, elevation))`, or `(ax3, azimuth)` to turn about the vertical only.
_view_target(ax, v) = v isa Number ? (Float64(v), ax.elevation[]) : (Float64(v[1]), Float64(v[2]))
function _set_view!(ax, az_el)
    ax.azimuth[] = az_el[1]
    ax.elevation[] = az_el[2]
end

"""
    slide_figure(fig; steps, fps = 30, px_per_unit = 1.5) -> SlideFigure

A Makie figure that builds on a slide, one state per build step. `steps` is a vector; each entry is a
NamedTuple saying what changes on that step:

- `show = plots` — those plots appear (they are hidden until their step);
- `hide = plots` — those plots go;
- `focus = plots` — every other plot dims until the next step that sets `focus`; `focus = nothing` undims.
  A plot shown later while the rest is dimmed joins the focus;
- `limits = (ax, (x1, x2, y1, y2))` — the axis moves to that window (smoothly, with `frames`); six
  values `(x1, x2, y1, y2, z1, z2)` for an `Axis3`;
- `view = (ax3, (azimuth, elevation))` — an `Axis3` camera turns to those angles (radians);
  `(ax3, azimuth)` turns about the vertical only. `azimuth + 2π` is a full turn;
- `trace = tr` — a `trace!` orbit draws itself along its points (one clip, 60 frames unless `frames`
  says otherwise); several traces given together draw at once;
- `terms = "name"` — while this is the current step, the math terms `\\term{name}{…}` on the slide light
  up, so the plot and its symbol in an equation are picked out together (a vector for several);
- `animate = t -> …` — called with `t` from 0 to 1 to change the figure, typically setting observables
  (`n[] = round(Int, t * N)` to draw a section point by point);
- `update = () -> …` — any other change, made once;
- `frames = n` — render the step as an `n`-frame clip at `fps` instead of one image. The moves of one
  step (`limits`, `view`, `trace`, `animate`) run together in its clip.

A plot is anything Makie returns from `lines!`, `scatter!`, `callout!`, `trace!`, …; pass several as a
vector.
The steps share the slide's step counter with its other builds (step `i` here is build step `i`).
Rendering mutates `fig`, which ends in its final state. A figure with a transparent background
(`backgroundcolor = :transparent` on the figure and its axes, e.g. through `update_theme!`) is drawn
on the slide's own background; its clips are WebM with an alpha channel (VP9), which Chrome and Firefox
play.

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
        for tr in _traces_of(get(st, :trace, nothing))
            append!(shown, tr.plots)
            tr.t[] = 0.0
        end
    end
    foreach(p -> _setvis!(p, false), shown)
    w, h = Int.(round.(_mkcall(size, fig.scene)))
    clear = _transparent(fig)
    save(name, bytes, mime) = _save_asset(name, bytes; mime).path
    base = save("slidefig-0.png", _png_bytes(fig, px_per_unit), "image/png")
    alphas = IdDict{Any,Any}()             # plots dimmed by the current focus → their own alpha
    layers = SlideLayer[]
    for (i, st) in enumerate(steps)
        traces = _traces_of(get(st, :trace, nothing))
        arriving = vcat(_plots_of(get(st, :show, nothing)), Any[p for tr in traces for p in tr.plots])
        for p in arriving
            _setvis!(p, true)
            # A plot that arrives while others are dimmed is the new subject: it joins the focus.
            haskey(alphas, p) && (_setalpha!(p, alphas[p]); delete!(alphas, p))
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
        terms = _terms_of(get(st, :terms, nothing))
        n = Int(get(st, :frames, isempty(traces) ? 0 : 60))
        lim = get(st, :limits, nothing)
        view = get(st, :view, nothing)
        anim = get(st, :animate, nothing)
        lim_from = lim === nothing ? nothing : _current_limits(lim[1])
        view_from = view === nothing ? nothing : (view[1].azimuth[], view[1].elevation[])
        view_to = view === nothing ? nothing : _view_target(view[1], view[2])
        frame = t -> begin
            lim === nothing || _mkcall(Mk.limits!, lim[1], _lerp(lim_from, lim[2], t)...)
            view === nothing || _set_view!(view[1], _lerp(view_from, view_to, t))
            for tr in traces; tr.t[] = t; end
            anim === nothing || Base.invokelatest(anim, t)
        end
        moves = lim !== nothing || view !== nothing || anim !== nothing || !isempty(traces)
        if n > 1 && moves
            at = k -> frame((k - 1) / (n - 1))
            name, bytes, mime = clear ? ("slidefig-$i.webm", _webm_clip(fig, at, n, fps, px_per_unit), "video/webm") :
                                        ("slidefig-$i.mp4", _mp4_clip(fig, at, n, fps), "video/mp4")
            push!(layers, (; step = i, kind = :video, path = save(name, bytes, mime),
                           poster = save("slidefig-$i-end.png", _png_bytes(fig, px_per_unit), "image/png"), terms))
        else
            moves && frame(1.0)
            push!(layers, (; step = i, kind = :png, path = save("slidefig-$i.png", _png_bytes(fig, px_per_unit), "image/png"),
                           poster = "", terms))
        end
    end
    return SlideFigure(w, h, base, layers)
end

_attr(x) = replace(String(x), '&' => "&amp;", '"' => "&quot;", '<' => "&lt;")

function Base.show(io::IO, ::MIME"text/html", sf::SlideFigure)
    print(io, "<div class=\"slidefig\" style=\"--sf-ar:", round(sf.w / sf.h; digits = 4), ";max-width:", sf.w,
              "px;aspect-ratio:", sf.w, "/", sf.h, "\">")
    print(io, "<img class=\"sf-base\" alt=\"\" data-slate-src=\"", _attr(sf.base), "\">")
    for l in sf.layers
        terms = isempty(l.terms) ? "" : string(" data-terms=\"", _attr(join(l.terms, ' ')), "\"")
        if l.kind === :png
            print(io, "<img class=\"step fade sf-layer\" step=\"", l.step, "\"", terms, " alt=\"\" data-slate-src=\"",
                      _attr(l.path), "\">")
        else
            print(io, "<video class=\"step fade sf-layer sf-anim\" step=\"", l.step, "\"", terms,
                      " muted playsinline preload=\"auto\" data-slate-poster=\"", _attr(l.poster), "\" data-slate-src=\"",
                      _attr(l.path), "\"></video>")
        end
    end
    print(io, "</div>")
end

# A label as Makie takes it: a LaTeX string (`L"W^u"`) keeps its math.
_label(x) = x isa Symbol ? String(x) : x

"""
    callout!(ax, (x, y), label; offset = (40, 40), color = :white, fontsize = 26) -> plots
    callout!(ax3, (x, y, z), label; …)

A label pinned to a point of the data: a dot, a fine leader line, and the label `offset` pixels away.
The label may be math: `callout!(ax, pt, L"W^u")`.
The leader keeps its length on screen as the axis zooms, and on an `Axis3` follows the point as the
camera turns. Returns its plots, so a step can `show` it.
"""
function callout!(ax, pt, label; offset = (40, 40), color = :white, fontsize = 26, linewidth = 1.5)
    length(pt) == 3 && return _callout3!(ax, pt, label; offset, color, fontsize, linewidth)
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
    lbl = _mkcall(Mk.text!, ax, x, y; text = _label(label), color, fontsize, offset = (Float32(ox), Float32(oy)),
                  align = (ox >= 0 ? :left : :right, oy >= 0 ? :bottom : :top))
    return Any[dot, seg, lbl]
end

# In 3-D the leader and label are drawn in the axis's pixel space, from the point projected through the
# current camera, so they stay upright and the same size as the view turns. The point goes through the
# dot's model matrix first (an `Axis3` scales its data into its box there), and the pixel-space plots
# take no clip planes, which are set in data space and would cut them away.
function _callout3!(ax, pt, label; offset, color, fontsize, linewidth)
    Mk = _mk()
    P = Mk.Point3f(pt[1], pt[2], pt[3])
    o = Mk.Vec2f(offset[1], offset[2])
    dot = _mkcall(Mk.scatter!, ax, [P]; color, markersize = 9)
    at = Base.invokelatest(Mk.lift, (_, _, _) -> begin
        q = dot.model[] * Mk.Vec4f(P[1], P[2], P[3], 1)
        r = Mk.project(ax.scene, :data, :pixel, Mk.Point3f(q[1], q[2], q[3]))
        Mk.Point2f(r[1], r[2])
    end, ax.finallimits, ax.scene.camera.projectionview, ax.scene.viewport)
    ends = Base.invokelatest(Mk.lift, a -> [a, a + 0.85f0 * o], at)
    noclip = Mk.Plane3f[]
    seg = _mkcall(Mk.lines!, ax.scene, ends; space = :pixel, clip_planes = noclip, color = (color, 0.85), linewidth)
    pos = Base.invokelatest(Mk.lift, a -> a + o, at)
    lbl = _mkcall(Mk.text!, ax.scene, pos; space = :pixel, clip_planes = noclip, text = _label(label), color, fontsize,
                  align = (o[1] >= 0 ? :left : :right, o[2] >= 0 ? :bottom : :top))
    return Any[dot, seg, lbl]
end

"""
    trace!(ax, xs, ys[, zs]; color = :white, linewidth = 3, markers = false, head = true) -> trace

An orbit that draws itself along its points when a `slide_figure` step names it (`trace = tr`): the
line grows point by point with a bright head at its tip and a soft glow on the stretch just behind it
(`tail`, a fraction of the orbit; `0` for none), at an even pace per point, so a sampled flow runs
smoothly and a map's orbit hops from iterate to iterate (`markers = true` leaves a dot at each one).
The glow is gone once the orbit has closed. Give `zs` on an `Axis3`. Close a periodic orbit by repeating its first point at the end. Before
its step it is hidden; `tr.t[]` (0 to 1) sets how far along it is for any other use, and a step can
`show`, `hide` or `focus` it like a plot.
"""
function trace!(ax, xs, ys, zs = nothing; color = :white, linewidth = 3, markers = false, markersize = 10,
                head = true, headsize = 18, tail = 0.08)
    Mk = _mk()
    P = zs === nothing ? [Mk.Point2f(x, y) for (x, y) in zip(xs, ys)] :
                         [Mk.Point3f(x, y, z) for (x, y, z) in zip(xs, ys, zs)]
    N = length(P)
    N >= 2 || throw(ArgumentError("trace! needs at least two points"))
    t = Mk.Observable(1.0)
    reached(t) = min(floor(Int, clamp(t, 0, 1) * (N - 1)) + 1, N)
    upto = t -> begin
        s = clamp(t, 0, 1) * (N - 1); i = reached(t); f = s - (i - 1)
        pts = P[1:i]
        i < N && f > 0 && push!(pts, P[i] + Float32(f) * (P[i+1] - P[i]))
        pts
    end
    path = Base.invokelatest(Mk.lift, upto, t)
    plots = Any[]
    if tail > 0
        k = max(2, ceil(Int, tail * N))
        recent = Base.invokelatest(Mk.lift, p -> (0 < t[] < 1 ? p[max(1, end - k):end] : p[end:end]), path)
        push!(plots, _mkcall(Mk.lines!, ax, recent; color = (color, 0.5), linewidth = 2.8 * linewidth,
                             linecap = :round, joinstyle = :round))
    end
    push!(plots, _mkcall(Mk.lines!, ax, path; color, linewidth))
    if markers
        dots = Base.invokelatest(Mk.lift, t -> P[1:reached(t)], t)
        push!(plots, _mkcall(Mk.scatter!, ax, dots; color, markersize))
    end
    if head
        tip = Base.invokelatest(Mk.lift, p -> [p[end]], path)
        push!(plots, _mkcall(Mk.scatter!, ax, tip; color, markersize = headsize, strokewidth = 2,
                             strokecolor = (:white, 0.85)))
    end
    return SlideTrace(t, plots)
end
