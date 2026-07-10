#%% md id=title title
# Widget Gauntlet — every control, live

*A QA notebook: every `@bind` widget, the async primitives, and an animation — all wired
into one reactive graph. If a control misbehaves, this is where it shows.*

#%% code id=deps
using CairoMakie, DataFrames, Dates

#%% code id=theme hidecode
set_theme!(merge(theme_dark(), Theme(backgroundcolor = :transparent,
    Axis = (backgroundcolor = :transparent,))))

#%% md id=sec_basic
## Numbers, booleans, text — one control strip

#%% code id=controls
@bind amp Slider(0.1:0.1:3.0; default = 1.0, label = "amplitude")
@bind freq NumberField(2; min = 1, max = 12, label = "frequency")
@bind markers Checkbox(true; label = "markers")
@bind live Toggle(false; on = "Live", off = "Paused")
@bind tag TextField("gauntlet"; label = "plot tag")

#%% md id=sec_choice
## Choices, colors, dates

#%% code id=choices
@bind fn Select(["sin" => "sine", "cos" => "cosine"]; label = "waveform")
@bind harmonics MultiCheckBox([1, 2, 3]; label = "harmonics")
@bind col ColorPicker("#56d364"; label = "wave color")
@bind day DateField("2026-07-09"; label = "as-of")
@bind at TimeField("09:00"; label = "time")

#%% code id=wave
## The mega-reader figure: amplitude, frequency, waveform, harmonics, color, markers, tag.
let f = fn == "sin" ? sin : cos
    xs = range(0, 4π; length = 400)
    fig = Figure(size = (760, 360))
    ax = Axis(fig[1, 1]; title = "$(tag): $(fn), f=$(freq), $(day) $(at)")
    for h in (isempty(harmonics) ? [1] : harmonics)
        ys = (amp / h) .* f.(h .* freq .* xs ./ 2)
        lines!(ax, xs, ys; color = col, alpha = 1 / h, linewidth = 3 / h,
               label = "h=$h")
        markers && h == 1 && scatter!(ax, xs[1:20:end], ys[1:20:end]; color = col, markersize = 5)
    end
    axislegend(ax; position = :rt)
    fig
end

#%% md id=sec_table
## Click a row (TableSelect)

#%% code id=tbl
@bind pick TableSelect(DataFrame(name = ["alpha", "beta", "gamma"],
                                 value = [1.5, 2.5, 3.5],
                                 note = ["first", "second", "third"]))

#%% code id=pick_out
pick === nothing ? "click a row above" : "picked $(pick.name): value=$(pick.value) ($(pick.note))"

#%% md id=sec_anim
## Animation + playhead

#%% code id=anim
anim = animate([[sin(x + t) * cos(y - t) for x in range(0, 2π; length = 64),
                                             y in range(0, 2π; length = 64)]
                for t in range(0, 2π; length = 48)];
               clim = :symmetric, fps = 24, title = "traveling wave")

#%% code id=ph
@bind frame playhead(anim)
"frame $frame / 48"

#%% md id=sec_async
## Async: button → handler → reactive meter

#%% code id=go_btn
@bind go Button("sweep 0 → 100")

#%% code id=meter_def
@reactive level = 0

#%% code id=handler
@onclick go begin
    for v in 0:5:100
        level[] = v
        pause(0.05)
    end
end

#%% code id=meter
echart(; series = [(type = "gauge", min = 0, max = 100, progress = (show = true,),
                    data = [(value = level[], name = "level")])], height = 260)

#%% code id=onchange_demo
## amp also drives the meter directly (no recompute of this cell — direct dispatch)
@onchange amp (level[] = round(Int, 33amp))

#%% md id=sec_echo
## The everything-reader

With {{ length(harmonics) }} harmonic(s) of **{{ fn }}** at amplitude {{ amp }},
frequency {{ freq }}, meter at **{{ level[] }}** — tagged "{{ tag }}",
{{ live ? "live" : "paused" }}, color {{ col }}.
