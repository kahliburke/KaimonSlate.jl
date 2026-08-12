#%% md id=title title
# A Month of Earth's Seismicity
## A data journey through the USGS live earthquake catalog
Kaimon Slate · DuckDB × DataFrames × Makie

#%% md id=abstract abstract
Every day, somewhere between one and two thousand earthquakes large enough to register are
recorded worldwide. Almost all pass unnoticed — but together they trace the seams of the
planet. In this notebook we pull the **last 30 days of the USGS earthquake catalog** (every
located event, all magnitudes), and let the data tell its story: where the Earth breaks, how
often, how deep, and what the aftermath of the month's largest shock looks like.

The expensive steps below (the download, the heavy wrangling) are **memoized to disk** — close
this notebook and reopen it, and the analysis reappears instantly, no refetch, no recompute.

#%% code id=deps
using DuckDB, DataFrames, Chain, CairoMakie, Dates, Statistics, Printf

#%% code id=theme hidecode
# Makie theme tuned to the notebook's dark UI: transparent canvas, soft grid, warm accent.
set_theme!(theme_dark();
    backgroundcolor = :transparent,
    figure_padding = 8,
    Axis = (backgroundcolor = :transparent,
            xgridcolor = (:white, 0.08), ygridcolor = (:white, 0.08),
            leftspinevisible = false, rightspinevisible = false,
            topspinevisible = false, bottomspinevisible = false,
            xtickcolor = (:white, 0.4), ytickcolor = (:white, 0.4)),
    Legend = (backgroundcolor = :transparent, framevisible = false));

#%% code id=fetch
import Downloads
# Snapshot the live USGS feed (~10 MB CSV, every located event of the last 30 days), then let
# DuckDB do the ingest + cleanup in one SQL pass. This cell is expensive, so Slate memoizes it:
# reopening the notebook restores the snapshot instantly. Press ▶ on this cell to force a fresh
# pull — the whole pipeline below recomputes from the new data.
# (The DB connection stays local to the `let` — a cell's cached globals must be serializable.)
feed = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_month.csv"
quakes = let csv = Downloads.download(feed), con = DBInterface.connect(DuckDB.DB)
    try
        DBInterface.execute(con, """
            SELECT CAST(time AS TIMESTAMP) AS time,
                   latitude, longitude,
                   greatest(depth, 0.0)    AS depth,      -- a few events carry tiny negative depths
                   mag, place
            FROM read_csv_auto('$csv')
            WHERE type = 'earthquake' AND mag IS NOT NULL
            ORDER BY time
        """) |> DataFrame
    finally
        DBInterface.close!(con)
    end
end
(events = nrow(quakes), from = Date(minimum(quakes.time)), to = Date(maximum(quakes.time)))

#%% code id=enrich
# Enrich: a coarse region (the catalog's place string ends ", Region"), the day, and the
# radiated seismic energy in joules — the Gutenberg–Richter energy relation log₁₀E ≈ 1.5M + 4.8.
region_of(p) = (i = findlast(',', coalesce(p, ""))) === nothing ? "open ocean" : strip(p[i+1:end])
df = @chain quakes begin
    transform(:place => ByRow(region_of) => :region,
              :time  => ByRow(Date)      => :day,
              :mag   => ByRow(m -> 10^(1.5m + 4.8)) => :energy_J)
end
biggest = df[argmax(df.mag), :]
@sprintf("Largest event: M%.1f — %s (%s)", biggest.mag, biggest.place, Date(biggest.time))

#%% md id=glance
## The month at a glance

The catalog holds **{{ nrow(df) }} earthquakes** between {{ Date(minimum(df.time)) }} and
{{ Date(maximum(df.time)) }} — about **{{ round(Int, nrow(df) / 30) }} per day**. They span
magnitudes {{ minimum(df.mag) }} to **{{ maximum(df.mag) }}**, and depths from the surface down to
**{{ round(Int, maximum(df.depth)) }} km**, deep inside a subducting slab.

One number puts the month in perspective: of all the seismic energy radiated by these
{{ nrow(df) }} events, the single largest — *{{ biggest.place }}* —
released **{{ round(Int, 100 * biggest.energy_J / sum(df.energy_J)) }}%** of it.
That extreme concentration is the signature of earthquake statistics, and it's where our
journey starts.

#%% md id=hitters_md
## The heavy hitters
Every event at **M6.0 or above** this month — sortable and filterable:

#%% code id=hitters
strongest = @chain df begin
    subset(:mag => ByRow(>=(6.0)))
    sort(:mag; rev = true)
    select(:time, :mag, :depth => ByRow(d -> round(d; digits = 1)) => :depth_km, :place)
end
slate_table(strongest)

#%% md id=map_md
## Where the Earth breaks

Every mark below is an earthquake — pan and zoom (scroll) to explore. A single month of
seismicity traces the plate boundaries on its own: the Pacific **Ring of Fire**, the
**Mid-Atlantic Ridge** threading the ocean floor, the **Alpide belt** across southern Asia.
**Color is depth** — the darker events trace subducting slabs plunging beneath island arcs.
The rippling markers are this month's **M ≥ 6** events.

#%% code id=worldmap
let pt(r) = (value = [r.longitude, r.latitude, r.depth, r.mag], name = r.place)
    small  = [pt(r) for r in eachrow(df) if r.mag < 4.5]
    medium = [pt(r) for r in eachrow(df) if 4.5 <= r.mag < 6.0]
    major  = [pt(r) for r in eachrow(df) if r.mag >= 6.0]
    echart(;
        height = 760,                       # a world map earns a tall canvas
        registerMap = (name = "world", url = "/assets/maps/world.json"),
        # silent must be EXPLICITLY false: an ECharts merge never unsets an omitted key, and a silent
        # geo swallows the mouse — roam (scroll-zoom / drag-pan) goes dead.
        geo = (map = "world", roam = true, silent = false,
               itemStyle = (areaColor = "#16202f", borderColor = "#31415c", borderWidth = 0.6),
               emphasis = (disabled = true,), select = (disabled = true,)),
        tooltip = (trigger = "item", formatter = "{b}"),
        visualMap = (min = 0, max = 300, dimension = 2, calculable = true,
                     inRange = (color = ["#7dd3fc", "#facc15", "#fb7185", "#7c3aed"],),
                     text = ["deep", "shallow"], left = 8, bottom = 8,
                     textStyle = (color = "#8b949e",)),
        legend = (bottom = 8, right = 10, orient = "vertical",),
        series = [
            (type = "scatter", coordinateSystem = "geo", name = "M < 4.5",
             data = small, symbolSize = 2.5, itemStyle = (opacity = 0.45,)),
            (type = "scatter", coordinateSystem = "geo", name = "M 4.5 – 6",
             data = medium, symbolSize = 7, itemStyle = (opacity = 0.85,)),
            (type = "effectScatter", coordinateSystem = "geo", name = "M ≥ 6",
             data = major, symbolSize = 13, zlevel = 1,
             rippleEffect = (brushType = "stroke", scale = 10),
             label = (show = false,)),
        ])
end

#%% md id=gr_md
## How earthquakes size up

Seismicity obeys one of geophysics' cleanest empirical laws: each unit step down in
magnitude brings roughly **ten times more earthquakes** (Gutenberg–Richter). The slope
*b* is usually near 1 — and the bend at the low end isn't physics, it's *detection*:
below ~M4.5 the global network simply misses events far from a seismometer.

#%% code id=gr_fig
## Frequency–magnitude with a least-squares b-value over the complete range (M ≥ 4.5).
let mags = 2.0:0.1:maximum(df.mag)
    counts = [count(>=(m), df.mag) for m in mags]
    fit = [4.5 <= m <= 6.5 for m in mags]
    A = [ones(count(fit)) collect(mags)[fit]]
    c0, slope = A \ log10.(counts[fit])
    fig = Figure(size = (760, 420))
    ax = Axis(fig[1, 1]; yscale = log10,
              xlabel = "magnitude M", ylabel = "events ≥ M (30 days)",
              title = @sprintf("Gutenberg–Richter: b ≈ %.2f", -slope))
    scatter!(ax, collect(mags), counts; markersize = 7, color = (:deepskyblue, 0.8),
             label = "observed")
    lines!(ax, collect(mags)[fit], 10 .^ (c0 .+ slope .* collect(mags)[fit]);
           color = :orange, linewidth = 2.5,
           label = @sprintf("fit: log₁₀N = %.1f − %.2f·M", c0, -slope))
    axislegend(ax; position = :rt)
    fig
end

#%% md id=aftershock_md
## Anatomy of the big one

A great earthquake never travels alone. Everything within ~150 km of the
**{{ @sprintf("M%.1f", biggest.mag) }}** mainshock traces the classic sequence: a burst of
aftershocks that decays by the day (Omori's law), with magnitudes thinning as it fades.

#%% code id=aftershock_fig
## The mainshock's neighbourhood (±1.5°), from the moment it struck.
let m = biggest
    near = sort(filter(r -> r.time >= m.time &&
                            abs(r.latitude - m.latitude) < 1.5 &&
                            abs(r.longitude - m.longitude) < 1.5, df), :time)
    days = [Dates.value(t - m.time) / 86_400_000 for t in near.time]   # ms → days
    fig = Figure(size = (860, 400))
    ax1 = Axis(fig[1, 1]; xlabel = "days since the mainshock", ylabel = "cumulative events",
               title = @sprintf("%d aftershocks — %s", nrow(near) - 1, near.region[1]))
    stairs!(ax1, days, 1:length(days); color = :orange, linewidth = 2)
    ax2 = Axis(fig[1, 2]; xlabel = "days since the mainshock", ylabel = "magnitude",
               title = "the sequence thins as it decays")
    scatter!(ax2, days, near.mag; markersize = 6, color = near.depth, colormap = :plasma)
    fig
end

#%% md id=depth_md
## Reading depth like a geologist

Depth sorts earthquakes into stories: crustal events (< 70 km) happen everywhere plates
grind; intermediate and deep ones (below the dashed lines) only occur inside **subducting
slabs** — cold ocean floor sinking into the mantle. The deep band is where the big
outliers live.

#%% code id=depth_fig
## Depth–magnitude scatter; dashed lines mark the crustal/intermediate/deep bands.
let fig = Figure(size = (760, 460))
    ax = Axis(fig[1, 1]; xlabel = "magnitude", ylabel = "depth (km)", yreversed = true,
              title = "one month of rupture, by depth")
    scatter!(ax, df.mag, df.depth; markersize = 4, alpha = 0.45,
             color = df.depth, colormap = :plasma)
    hlines!(ax, [70, 300]; color = (:white, 0.35), linestyle = :dash)
    fig
end

#%% md id=energy_md
## Who carries the energy?

Counting events hides the real story — radiated energy scales as **10^1.5M**, so one
magnitude step is ~32× the energy. Drag the slider: almost the entire month's energy
budget sits in a handful of the largest events.

#%% code id=energy_bind
@bind min_mag Slider(3.0:0.25:7.0, default = 5.0, label = "min magnitude")

#%% code id=energy_stats
let sel = df[df.mag .>= min_mag, :]
    tot, part = sum(df.energy_J), sum(sel.energy_J)
    @sprintf("M ≥ %.2f — %d events (%.2f%% of the catalog) release %.1f%% of the month's radiated energy",
             min_mag, nrow(sel), 100nrow(sel) / nrow(df), 100part / tot)
end

# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   Chain 1.0.0 8be319e6-bccf-4806-a6f7-6fae938471bc
# ╚═╡
