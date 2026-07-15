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

# Every Slate UI theme's palette — MIRRORS the `:root` + `html[data-slate-theme="…"]` blocks in
# notebook.css (kept in sync by the golden test). Makie runs SERVER-side and can't read the CSS, so
# this is the server-side mirror: `slate_theme(theme=…)` / `use_slate_theme!(theme=…)` selects one so a
# rendered plot matches the ACTIVE UI theme (or an explicitly named one), not just the dark default.
const SLATE_PALETTES = Dict{String,NamedTuple}(
    "midnight"        => (bg="#0d1120", bg2="#141828", bg3="#1a1e2e", border="#2a2e40", text="#d4d8e8", dim="#6a7090",
                          accent="#569cd6", green="#56d364", red="#e57575", gold="#ffd700", orange="#ce9178", purple="#c586c0", teal="#4ec9b0"),
    "graphite"        => (bg="#15171c", bg2="#1c1f26", bg3="#23262e", border="#33373f", text="#d7dae1", dim="#828b9c",
                          accent="#6cb6ff", green="#57d364", red="#e5797b", gold="#e3b341", orange="#e0a071", purple="#c89be8", teal="#54c7b8"),
    "nord"            => (bg="#2e3440", bg2="#3b4252", bg3="#434c5e", border="#4c566a", text="#e5e9f0", dim="#8893a8",
                          accent="#88c0d0", green="#a3be8c", red="#bf616a", gold="#ebcb8b", orange="#d08770", purple="#b48ead", teal="#8fbcbb"),
    "dracula"         => (bg="#282a36", bg2="#2f3242", bg3="#383b4d", border="#44475a", text="#f8f8f2", dim="#7081ad",
                          accent="#bd93f9", green="#50fa7b", red="#ff5555", gold="#f1fa8c", orange="#ffb86c", purple="#ff79c6", teal="#8be9fd"),
    "solarized-dark"  => (bg="#002b36", bg2="#073642", bg3="#0a4250", border="#13515f", text="#93a1a1", dim="#5d737e",
                          accent="#268bd2", green="#859900", red="#dc322f", gold="#b58900", orange="#cb4b16", purple="#6c71c4", teal="#2aa198"),
    "daylight"        => (bg="#ffffff", bg2="#f5f7fa", bg3="#eaeef3", border="#d5dbe3", text="#222730", dim="#6b7480",
                          accent="#0969da", green="#1a7f37", red="#cf222e", gold="#9a6700", orange="#bc4c00", purple="#8250df", teal="#0a7b83"),
    "solarized-light" => (bg="#fdf6e3", bg2="#eee8d5", bg3="#e4ddc8", border="#d3cbb0", text="#586e75", dim="#93a1a1",
                          accent="#268bd2", green="#859900", red="#dc322f", gold="#b58900", orange="#cb4b16", purple="#6c71c4", teal="#2aa198"),
)
# The default ("Midnight") palette — back-compat alias; the golden test pins this to notebook.css `:root`.
const SLATE_PALETTE = SLATE_PALETTES["midnight"]

# Resolve a theme NAME to its palette; "" (or an unknown name) → the Midnight default. Pass the active
# UI theme in explicitly — e.g. bind it (`@bind ui_theme …; use_slate_theme!(theme = ui_theme)`) so the
# choice flows through the dependency graph and re-themes every figure on change (see the parity example).
_resolve_palette(theme::AbstractString) = get(SLATE_PALETTES, isempty(theme) ? "midnight" : theme, SLATE_PALETTES["midnight"])

# The categorical series cycle — a legible, well-separated ordering of the brand hues. The SAME order
# is used for the ECharts `color` array (client-side, from the matching CSS vars) so a 3-series chart
# picks the same three colours in ECharts and Makie.
slate_series_cycle(p::NamedTuple = SLATE_PALETTE) = [p.accent, p.green, p.orange, p.purple, p.teal, p.gold, p.red]

# The Slate Makie theme AS PLAIN DATA — a NamedTuple of Makie attributes (no Makie types), so it's
# testable without Makie and `slate_theme`/`use_slate_theme!` just splat it. Transparent backgrounds
# (the cell/page shows through, matching ECharts' `backgroundColor:"transparent"`); grid/axis/label
# colours from the palette; title/label sizes and a default figure height (≈ the 340px ECharts cell)
# chosen so a Makie figure and an ECharts figure sit at the same scale in the column.
function slate_theme_attrs(p::NamedTuple = SLATE_PALETTE)
    return (
        backgroundcolor = :transparent,
        textcolor = p.text,
        fontsize = 14,
        figure_padding = 10,
        size = (680, 340),                          # aligns Makie's default figure height with the ECharts cell
        palette = (color = slate_series_cycle(p), patchcolor = slate_series_cycle(p)),
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
        Legend = (framecolor = p.border, backgroundcolor = :transparent, labelcolor = p.text, titlecolor = p.dim),
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
    slate_theme(; theme="") -> Makie.Theme

The shared **Slate look** as a Makie `Theme`, built from the same brand palette the interactive
ECharts figures use — transparent background, the Slate series colours, palette-toned grid/axes, and
a default figure size that matches the ECharts cell height. Needs Makie loaded (`using CairoMakie`).

`theme` selects a palette by name (`"midnight"`, `"nord"`, `"daylight"`, …); the default `""` follows
the ACTIVE UI theme, so a rendered plot matches whatever Slate theme is on. Compose extra styling on
top with Makie's own `update_theme!`/`set_theme!(base, overlay)`.

```julia
using CairoMakie
set_theme!(slate_theme())              # follow the active UI theme
set_theme!(slate_theme(theme="nord"))  # or pin a specific palette
# or just:  use_slate_theme!()
```
"""
slate_theme(; theme::AbstractString = "") =
    Base.invokelatest(_need_makie().Theme; slate_theme_attrs(_resolve_palette(theme))...)

"""
    use_slate_theme!(; theme="") -> nothing

Apply the [`slate_theme`](@ref) globally (`Makie.set_theme!`) so every Makie figure in the notebook
matches the interactive ECharts look. `theme` names a palette; `""` follows the active UI theme. Needs
Makie loaded. Call it once in a setup cell (re-run it after switching the UI theme to re-render).
"""
function use_slate_theme!(; theme::AbstractString = "")
    Mk = _need_makie()
    Base.invokelatest(Mk.set_theme!, Base.invokelatest(Mk.Theme; slate_theme_attrs(_resolve_palette(theme))...))
    return nothing
end
