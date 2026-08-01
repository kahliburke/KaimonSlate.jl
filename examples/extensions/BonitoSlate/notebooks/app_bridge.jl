try
    using KaimonSlate: KaimonSlate
catch
    error(
        "This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate.",
    )
end;
KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# BonitoSlate — plain `Bonito.App` support

Isolation harness for the app path, with **no Makie anywhere**. `figure.jl` gives WGLMakie figures a working
contract (render through the Slate HTML MIME, inline the scene, declare the output session-bound). A plain
`Bonito.App` is the layer *underneath* a figure and had none of that, so any non-Makie Bonito output — a
widget, a custom app, a third-party view — renders once and then vanishes on reload.

**The failure to fix.** When a browser page is attached and ready, a Bonito sub-session writes its DOM over
the socket instead of inlining it, so the captured HTML comes back nearly empty (just the runtime `<script>`).
The pushed DOM then has no node to land in. Figures dodge this because their scene is inlined; apps do not.

Each cell below states what it should show and what a failure looks like, so a regression is obvious without
reading any Julia.
"""

#%% code id=setup
using Bonito, BonitoSlate
BonitoSlate.enable!()
(bonito=pkgversion(Bonito), enabled=true)

#%% code id=static_app nocache
# Step 1: the simplest possible Bonito app — static DOM, no JS, no widgets. If even this does not survive a
# reload, the problem is in how the app is CAPTURED, not in sockets or interactivity.
#
# EXPECT: a green box reading "static Bonito app". FAIL: empty output, or the box vanishing after a reload.
App() do
    return Bonito.DOM.div(
        "static Bonito app";
        style="padding:14px;border-radius:8px;background:#12321c;color:#8de08d;font:13px monospace",
    )
end

#%% code id=widget_app nocache
# Fresh-worker leak test, widget run C.
App() do
    s = Bonito.Slider(1:100)
    out = Bonito.DOM.span(s.value; style="color:#8de08d;font:13px monospace")
    return Bonito.DOM.div(
        Bonito.DOM.div("drag me (C):"; style="color:#838b9b;font:11px monospace"),
        s,
        out;
        style="padding:12px;display:flex;flex-direction:column;gap:6px",
    )
end

#%% code id=figure_takes_root nocache
# Step 3: a WGLMakie FIGURE rendered alongside the apps.
#
# The bug this harness caught: apps used to mint their OWN page root (Bonito's `show_html` takes its no-parent
# branch when `CURRENT_SESSION[]` is unset), so several roots competed and `_PAGE_ROOT` was clobbered. That
# breaks FIGURES specifically — WGLMakie's `orderedExecutor` counts scene order per root, so a figure attached
# to a root the page never wired queues behind a number that never comes up: a permanent spinner, no console
# error. Apps now always attach to the one page root.
#
# EXPECT: a scatter plot on the Slate dark palette (a brief spinner, then the plot). FAIL: a spinner that
# never resolves.
using WGLMakie
WGLMakie.activate!()
use_slate_theme!()
scatter(1:10, rand(10); axis=(; title="figure shares the one page root"))

#%% code id=app_after_figure nocache
# Step 4: THE FAILING CASE. Identical app to `static_app`, but rendered after a figure has taken the page root,
# so this one is a pure sub-session with no root init of its own.
#
# EXPECT (once fixed): an amber box reading "app AFTER a figure". FAIL (current): empty output — the capture
# contains only the runtime <script> and the sub-session's DOM never lands.
App() do
    return Bonito.DOM.div(
        "app AFTER a figure";
        style="padding:14px;border-radius:8px;background:#3a2c10;color:#ffc93c;font:13px monospace",
    )
end

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 7463c7fb-c421-4a3c-beca-426ed0a24aaf
# ╚═╡
