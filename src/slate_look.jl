# ── The shared "Slate look" — one palette for ECharts (client) and Makie (server) ─────────────
# Charts should read as ONE system whether they're an interactive ECharts figure or a rendered
# Makie plot. The canonical brand palette lives in the CSS custom properties (notebook.css `:root`,
# the "Midnight" default) — the ECharts side is registered client-side straight from those vars
# (see `_slateEchartsTheme` in core.js), so charts follow whatever Slate theme is active. Makie
# runs SERVER-side and can't read CSS, so it mirrors the SAME default-dark hexes here in Julia;
# a golden test (`test_slate_look.jl`) pins this mirror to the CSS `:root` so the two can't drift.
#
# Base-only (no deps): Makie is a USER dependency, never Slate's. `slate_theme()`/`use_slate_theme!()`
# find the user's loaded Makie at CALL time (via `Base.loaded_modules`) and build the theme through
# it with `invokelatest` — so this file loads into any worker env, and the helpers only need Makie
# to be present when the user actually calls them.

# The default-dark ("Midnight") palette — MIRRORS notebook.css `:root` (kept in sync by the golden test).
const SLATE_PALETTE = (
    bg     = "#0d1120", bg2    = "#141828", bg3    = "#1a1e2e",
    border = "#2a2e40", text   = "#d4d8e8", dim    = "#6a7090",
    accent = "#569cd6", green  = "#56d364", red    = "#e57575", gold = "#ffd700",
    orange = "#ce9178", purple = "#c586c0", teal   = "#4ec9b0",
)
# The categorical series cycle — a legible, well-separated ordering of the brand hues. The SAME order
# is used for the ECharts `color` array (client-side, from the matching CSS vars) so a 3-series chart
# picks the same three colours in ECharts and Makie.
slate_series_cycle() = [SLATE_PALETTE.accent, SLATE_PALETTE.green, SLATE_PALETTE.orange,
                        SLATE_PALETTE.purple, SLATE_PALETTE.teal, SLATE_PALETTE.gold, SLATE_PALETTE.red]

# The Slate Makie theme AS PLAIN DATA — a NamedTuple of Makie attributes (no Makie types), so it's
# testable without Makie and `slate_theme`/`use_slate_theme!` just splat it. Transparent backgrounds
# (the cell/page shows through, matching ECharts' `backgroundColor:"transparent"`); grid/axis/label
# colours from the palette; title/label sizes and a default figure height (≈ the 340px ECharts cell)
# chosen so a Makie figure and an ECharts figure sit at the same scale in the column.
function slate_theme_attrs()
    p = SLATE_PALETTE
    return (
        backgroundcolor = :transparent,
        textcolor = p.text,
        fontsize = 14,
        figure_padding = 10,
        size = (680, 340),                          # aligns Makie's default figure height with the ECharts cell
        palette = (color = slate_series_cycle(), patchcolor = slate_series_cycle()),
        Axis = (
            backgroundcolor = :transparent,
            xgridcolor = (p.border, 0.5), ygridcolor = (p.border, 0.5),
            xgridwidth = 0.8, ygridwidth = 0.8,
            topspinevisible = false, rightspinevisible = false,
            bottomspinecolor = p.border, leftspinecolor = p.border,
            xtickcolor = p.dim, ytickcolor = p.dim,
            xticklabelcolor = p.dim, yticklabelcolor = p.dim,
            xlabelcolor = p.text, ylabelcolor = p.text,
            titlecolor = p.text, titlesize = 16,
        ),
        Legend = (framecolor = p.border, bgcolor = :transparent, labelcolor = p.text, titlecolor = p.dim),
        Colorbar = (tickcolor = p.dim, ticklabelcolor = p.dim, labelcolor = p.text, spinecolor = p.border),
    )
end

# The user's loaded Makie module (CairoMakie/GLMakie/WGLMakie all load `Makie`), or nothing.
function _loaded_makie()
    for m in values(Base.loaded_modules)
        try; nameof(m) === :Makie && return m; catch; end
    end
    return nothing
end
_need_makie() = (m = _loaded_makie(); m === nothing &&
    error("slate_theme() needs Makie loaded — add `using CairoMakie` (or GLMakie/WGLMakie) first."); m)

"""
    slate_theme() -> Makie.Theme

The shared **Slate look** as a Makie `Theme`, built from the same brand palette the interactive
ECharts figures use — transparent background, the Slate series colours, palette-toned grid/axes, and
a default figure size that matches the ECharts cell height. Needs Makie loaded (`using CairoMakie`).

```julia
using CairoMakie
set_theme!(slate_theme())        # apply for the rest of the notebook
# or just:  use_slate_theme!()
```
"""
slate_theme() = Base.invokelatest(_need_makie().Theme; slate_theme_attrs()...)

"""
    use_slate_theme!() -> nothing

Apply the [`slate_theme`](@ref) globally (`Makie.set_theme!`) so every Makie figure in the notebook
matches the interactive ECharts look. Needs Makie loaded. Call it once in a setup cell.
"""
function use_slate_theme!()
    Mk = _need_makie()
    Base.invokelatest(Mk.set_theme!, Base.invokelatest(Mk.Theme; slate_theme_attrs()...))
    return nothing
end
