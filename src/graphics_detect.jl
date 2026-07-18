# Shared lexical detection of Makie graphics / global-theme cells (engine + worker + scheduler).
#
# Makie (and most plotting) touches PROCESS-GLOBAL state — the theme observable, the current
# scene/figure, the display stack — invisible to dataflow analysis (library internals, not notebook
# bindings). Two consumers of this fact live in different modules, so the detection is defined once
# here and included by both:
#
# • parsched.jl (worker + server): every graphics cell gets a synthetic shared WRITE
#   (`_GRAPHICS_SENTINEL`) so the write-write rule serialises any two of them — Observables'
#   listener vectors resize non-atomically, and two concurrent plot cells race into
#   `ConcurrencyViolationError`. Over-approximate on purpose: a false positive costs a little
#   overlap, a miss risks a crash.
#
# • deps.jl (ReportEngine): a cell that SETS the global theme (`set_theme!`/`update_theme!`)
#   writes nothing a plot cell reads, so without help the dependency graph has NO theme→plot edge —
#   editing the theme cell re-runs it alone and every figure keeps the OLD theme (dead reactivity),
#   and a memo-restored figure can resurrect a stale theme. Inference gives theme-setting cells a
#   synthetic write of `_THEME_SENTINEL` (as a MUTATION, so consecutive theme cells chain and it
#   never counts as a multidef collision) and every graphics cell a synthetic read — the
#   most-recent-prior-writer rule then wires real theme→plot edges: theme edits restale figures,
#   scheduling follows deps, and plot memo keys digest the theme cell's source.
#
# High-signal tokens — scene/figure/theme constructors + display, and the `!` plotting verbs
# (rarely variable names) — each as a CALL `(`.
const _GRAPHICS_SENTINEL = Symbol("##slate_graphics##")
const _GRAPHICS_RE = r"\b(?:Figure|Axis3?|LScene|Scene|PolarAxis|Colorbar|Legend|set_theme!|update_theme!|use_slate_theme!|with_theme|set_window_config!|record|current_figure|current_axis|display|(?:lines|scatter|scatterlines|heatmap|surface|contour|contourf|band|poly|mesh|meshscatter|image|barplot|hist|density|arrows|series|stairs|stem|errorbars|boxplot|violin|hlines|vlines|ablines|text|wireframe|streamplot|spy|volume|voronoiplot|rangebars|annotations)!)\s*\("
_uses_shared_graphics(src::AbstractString) = occursin(_GRAPHICS_RE, src)

# GLOBAL theme mutators only — `with_theme` is scoped to its block and mutates nothing global.
# Single source of truth for "which calls count as a theme setter" — worker.jl's
# `_collect_theme_calls!` (memo-restore replay) must recognize the SAME names, or a setter
# classified EVERYWHERE here can restore "clean" while never actually re-applying the theme.
const _THEME_SENTINEL = Symbol("##makie_theme##")
const _THEME_CALL_NAMES = (:set_theme!, :update_theme!, :use_slate_theme!)
const _THEME_SET_RE = r"\b(?:set_theme!|update_theme!|use_slate_theme!)\s*\("
_sets_global_theme(src::AbstractString) = occursin(_THEME_SET_RE, src)
