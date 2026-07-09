# ── generate_tui_assets.jl — record the `slate` status TUI as a GIF for the docs ──
# Mirrors Kaimon's docs/generate_assets.jl: build a mock model, script a few
# keypresses, record with Tachikoma, export SVG + GIF into docs/src/assets/.
#
# Run from the repo root against the docs project (KaimonSlate + Tachikoma + FreeTypeAbstraction + ColorTypes):
#   julia --project=docs docs/generate_tui_assets.jl
#
# `record_app` renders headlessly (no `init!`), so SlateModel's live refresher never
# starts — the mock notebooks we set stay put. The scripted keys are navigation-only
# (↑/↓); enter/o/s/r are avoided so nothing tries to open a browser or touch a hub.

using KaimonSlate
using Tachikoma
import Tachikoma: record_app, enable_gif, export_gif_from_snapshots, load_tach, export_svg,
                  discover_mono_fonts, EventScript, key, pause, rep, set_theme!

set_theme!(:kokaku)

const ASSETS_DIR = joinpath(@__DIR__, "src", "assets")

function _find_font()
    fonts = discover_mono_fonts()
    for name in ["MesloLGL Nerd Font Mono", "JetBrains Mono", "MesloLGS NF", "Menlo"]
        norm = lowercase(replace(name, " " => ""))
        idx = findfirst(f -> occursin(norm, lowercase(replace(f.name, " " => ""))), fonts)
        idx !== nothing && return fonts[idx].path
    end
    isempty(fonts) ? "" : fonts[1].path
end

# A representative status TUI: attached to a Kaimon extension hub, three notebooks in
# different states (fresh · running+stale · errored). Fields match `_view_notebooks`.
function _build_model()
    m = KaimonSlate.SlateModel(:viewer)
    m.notebooks = Any[
        Dict("id" => "intro",     "title" => "Getting Started",   "cells" => 8,  "running" => 0, "stale" => 0, "errors" => 0, "port" => 39001),
        Dict("id" => "sales",     "title" => "Sales analysis",    "cells" => 14, "running" => 1, "stale" => 2, "errors" => 0, "port" => 39002),
        Dict("id" => "heat-eqn",  "title" => "The heat equation", "cells" => 11, "running" => 0, "stale" => 0, "errors" => 1, "port" => 39003),
    ]
    m.ok = true
    m.registered = true
    return m           # `view` builds the table from `notebooks`; DataTable selects row 1
end

# Navigation only — walk down the notebook list and back up (no enter/o/s/r).
const EVENTS = EventScript(
    pause(1.6),
    rep(key(:down), 2; gap = 0.7),
    pause(0.9),
    rep(key(:up), 2; gap = 0.6),
    pause(1.4),
)

function main()
    mkpath(ASSETS_DIR)
    font_path = _find_font()
    tach = joinpath(ASSETS_DIR, "slate-tui.tach")
    w, h, fps = 104, 18, 15

    println("recording slate-tui ($(w)×$(h))…")
    record_app(_build_model(), tach; width = w, height = h, frames = 105, fps = fps, events = EVENTS(fps))

    tw, th, cells, ts, sixels = load_tach(tach)
    try
        enable_gif()
        Base.invokelatest(export_gif_from_snapshots, joinpath(ASSETS_DIR, "slate-tui.gif"),
                          tw, th, cells, ts; pixel_snapshots = sixels, font_path,
                          cell_w = 10, cell_h = 20, font_size = 16)
        println("  → slate-tui.gif")
    catch e
        @warn "GIF export skipped" exception = (e, catch_backtrace())
    end
    rm(tach; force = true)   # intermediate — only the .gif is kept
    println("done — $(ASSETS_DIR)")
end

main()
