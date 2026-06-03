#%% md id=title
# 🎛️ Widget gallery — every control type

The **`controls`** group cell declares one of each supported `@bind` widget. The
**`plot`** cell surfaces them in four columns (`controls=[…],[…],[…],[…]`) right
next to the figure. Open the 🎛 **Controls** palette to drag any of them around,
stack them, make new columns, or drop one on the palette to remove it.

#%% code id=setup
using CairoMakie, Statistics, Random
CairoMakie.activate!(type = "png")
set_theme!(theme_dark())
"ready"

#%% code id=controls
@bind freq Slider(1:0.5:12)
@bind amp Slider(0.2:0.2:3.0)
@bind phase Slider(0:0.1:6.2)
@bind npts NumberField(50, 1000, 300)
@bind shape Radio(["sine", "square", "saw"], "sine")
@bind series MultiSelect(["wave", "envelope", "noise"], ["wave", "envelope"])
@bind shade Toggle(true)
@bind grid Checkbox(true)
@bind linecolor ColorPicker("#3aa0ff")
@bind title TextField("Signal")
@bind notes TextArea("annotations…")
@bind day DateField("2026-06-03")
@bind t0 TimeField("09:00")
@bind reseed Button("Re-roll noise")

#%% code id=signal
x = range(0, 2π; length = Int(round(npts)))
base = sin.(freq .* x .+ phase)
wave = amp .* (shape == "square" ? sign.(base) :
               shape == "saw"   ? (2 / π) .* asin.(clamp.(base, -1, 1)) : base)
noise = 0.15 .* randn(MersenneTwister(reseed), length(x))
(; n = length(x), peak = round(maximum(wave); digits = 3), shows = series)

#%% code id=plot controls=[freq,amp,phase],[shape,series],[linecolor,shade,grid],[title,reseed]
fig = Figure(size = (820, 360))
ax = Axis(fig[1, 1]; title = title, xlabel = "x", ylabel = "y")
ax.xgridvisible = grid; ax.ygridvisible = grid
if "wave" in series
    shade && band!(ax, x, zeros(length(x)), wave; color = linecolor, alpha = 0.13)
    lines!(ax, x, wave; color = linecolor, linewidth = 2, label = "wave")
end
"envelope" in series && lines!(ax, x, repeat([amp], length(x));
                               color = :gray, linestyle = :dash, label = "envelope")
"noise" in series && scatter!(ax, x, wave .+ noise; color = :white, alpha = 0.35,
                              markersize=10)
isempty(series) || axislegend(ax; position = :rt)
fig

#%% code id=meta
(; title, day, t0, notes, color = linecolor, points = Int(round(npts)))
