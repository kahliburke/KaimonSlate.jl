# ── Bonito apps ───────────────────────────────────────────────────────────────────────────────────
#
# A `Bonito.App` is the fundamental Bonito renderable; a WGLMakie figure is one special case of it. Until this
# file, BonitoSlate taught Slate about the special case only, so every OTHER Bonito output — a widget, a custom
# app, a third-party view built on Bonito — fell through to plain `text/html` with no live-render opt-in.
#
# That fallback is not merely plainer, it is broken in a specific way. A Bonito app's DOM is a handle into a
# session living on the worker, not self-contained markup. Captured once and replayed, it points at a session
# the new page knows nothing about, so the output renders EMPTY after a browser reload. The symptom is an app
# that works on first render and then silently disappears on every refresh.
#
# The fix is the contract `figure.jl` gives figures, applied at the level it should have been: render through
# the Slate HTML MIME so the runtime script and root announcement ride along, and declare the output
# SESSION-BOUND so Slate re-runs the cell's source for each page that connects.

# ── Render serialisation ──────────────────────────────────────────────────────────────────────────
#
# Slate evaluates cells as a PARALLEL BATCH (see the task-local `@bind`/effects/asset sinks in `run_capture`),
# but rendering a Bonito output mutates PROCESS-GLOBAL state that has no such isolation:
#
#   * `Bonito.CURRENT_SESSION[]`, which `show_html` reads and writes to decide root-vs-sub;
#   * `_PAGE_ROOT[]`, read-then-written when a render establishes the page root — two cells both observing
#     `nothing` would each mint a root, which is the multi-root bug that strands figures on a spinner;
#   * `_ANNOUNCE_ROOT[]`, a consume-once flag, where a lost race means the page never receives the root DOM;
#   * `root.children`, which `track_new_sessions` DIFFS around a render — concurrently rendering cells would
#     each attribute the other's new sessions to themselves, so re-running one cell would tear down another
#     cell's live session. That one is silent and would be extremely hard to trace.
#
# One reentrant lock over the whole render-and-register span removes all four. Renders are short and already
# effectively serialised by Bonito's own global-session design, so this costs nothing real.
const _RENDER_LOCK = ReentrantLock()

"""
    with_render_lock(f)

Run `f` holding the Bonito render lock — used around any render that touches the page root, the root
announcement, or the session registry. Reentrant, so nesting these is safe.
"""
with_render_lock(f::Function) = lock(f, _RENDER_LOCK)   # Base's do-block form takes the FUNCTION first

"""
    bonito_output_html(render) -> String

Assemble any Bonito output: the runtime loader, the page-root announcement, then `render()`'s fragment —
with the announcement read, the render and the session bookkeeping held as ONE atomic span.

Both output kinds go through this. The ordering is not cosmetic: the announcement carries the root's DOM and
must precede the sub-session it belongs to, in the emitted HTML (the browser registers the root before the
sub's init runs) and in time (the root's queued messages flush into it). Reading it outside the lock would let
a concurrently-rendering cell consume it in between.

`render` returns the fragment as a `String`.
"""
function bonito_output_html(render::Function)
    announce, frag = with_render_lock() do
        return (root_announce_html(), track_new_sessions(render))
    end
    return _bonito_runtime_script() * announce * frag
end

# A `<script src="/n/<id>/served/<hash>" type="module">` loading the Bonito runtime (which self-assigns
# `window.Bonito`). Served once and deduped by URL, so it is safe to include in EVERY output: Bonito emits its
# own runtime script only for the page-ROOT session, so any output rendering as a sub would otherwise carry no
# loader and fail to boot from its stored fragment. Empty before `enable!` sets `_NB_ID`.
function _bonito_runtime_script()
    isempty(_NB_ID[]) && return ""
    url = try
        Bonito.url(SlateAssetServer(), Bonito.BonitoLib)
    catch
        return ""
    end
    return string("<script src=\"", url, "\" type=\"module\"></script>")
end

"""
    slate_app_html(app) -> String

A `Bonito.App` as a Slate HTML fragment: the Bonito runtime loader, the page-root announcement when one is
pending, then the app's own fragment.

Order matters and mirrors `slate_card_html`. The root announcement has to be built BEFORE the app renders,
because rendering is what creates the app's sub-session under the root, and the browser must register the root
before that sub-session's init runs.
"""
function slate_app_html(app::Bonito.App)
    try
        return bonito_output_html() do
            return sprint(io -> _show_app_under_root(io, app))
        end
    catch e
        # Surface a render failure inline rather than let the display capture swallow it into a `text/plain`
        # repr, which for an App is an uninformative one-liner.
        return string(
            "<pre style=\"color:#f88;white-space:pre-wrap\">BonitoSlate app render error:\n",
            sprint(showerror, e),
            "</pre>",
        )
    end
end

# Render the app as a SUB of the one page-root session, never as a root of its own.
#
# This is the whole correctness condition for apps. `show(io, MIME"text/html"(), app)` reaches Bonito's
# `show_html(io, app; parent = CURRENT_SESSION[])`, and when that global happens to be unset — which it is for a
# cell rendering outside a figure's render, and racily so across a parallel cell batch — Bonito takes its
# no-parent branch and MINTS A NEW ROOT. Every such app then overwrites `_PAGE_ROOT`, and the page ends up with
# several competing roots.
#
# That breaks figures specifically: WGLMakie's browser-side `orderedExecutor` is global-monotonic and
# `get_order!` counts per ROOT session, so a figure attached to a root the page never wired queues its scene
# init behind a number that never comes up — a permanent spinner, with nothing logged on either side (exactly
# the failure `connection.jl` documents for per-figure roots).
#
# Passing the established root explicitly makes an app a sub-session like every figure, which is the invariant
# `use_parent_session` is there to express. Before any root exists, the plain path is correct: the first output
# on the page legitimately establishes it.
function _show_app_under_root(io::IO, app::Bonito.App)
    root = _PAGE_ROOT[]
    # Both branches go through `show_html` because it RETURNS the sub-session, which `show(io, MIME, app)`
    # discards. With no root yet, Bonito's no-parent branch establishes one AND creates a child holding this
    # app's DOM; that child is per-cell like any other and must be released on re-run. Only the ROOT itself
    # outlives the cell, and `_release_with_cell!` skips it by identity — so reading `_PAGE_ROOT` back AFTER
    # the render (it is set during it) is what distinguishes the two.
    # Session bookkeeping is NOT done here: `bonito_output_html` wraps every render in `track_new_sessions`,
    # which registers whatever the render created. Registering here as well would attach two teardowns to the
    # same session.
    root === nothing ? Bonito.show_html(io, app) : Bonito.show_html(io, app; parent=root)
    return nothing
end

# Release this render's SUB session when the cell re-evaluates, is deleted, or the namespace rebuilds.
#
# Without this every re-run leaks a session: its inbox task stays alive, its `slate_on` handler lingers in
# `__slate_handlers`, and the browser keeps a stream subscription per run. `_teardown_session!` was written for
# exactly this and documents itself as "registered via `slate_on_cleanup`" — but nothing ever registered it, so
# the leak was live for figures too. Measured before this: one orphaned, still-open child session per re-run.
#
# The page ROOT is deliberately excluded. It is shared by every output and survives browser reloads by design
# (`_reset_page!` re-points it), so tearing it down with a cell would strand every other fragment on the page.
function _release_with_cell!(sub, root)
    (sub === nothing || sub === root) && return nothing
    SlateExtensionsBase.slate_on_cleanup(() -> _teardown_session!(sub))
    return nothing
end

"""
    track_new_sessions(f)

Run `f`, then register every sub-session it created under the page root for per-cell release.

For the app path the session comes back from `show_html` directly, but a Makie figure renders through
`show(io, MIME"text/html"(), fig)`, which discards it — leaving nothing to attach teardown to, which is why
figures leaked a session per re-run just as apps did. Diffing the root's children around the render recovers
them without changing how anything renders.
"""
function track_new_sessions(f::Function)
    # Held across the whole diff: the "new children" set is only meaningful if no other cell renders in
    # between (see `_RENDER_LOCK`).
    with_render_lock() do
        # `nothing` means no root existed BEFORE the render — in which case this render establishes it and
        # every child it leaves behind is new, including the sub holding this output. Returning early here
        # would leak exactly one session per root establishment, the same oversight the app path had.
        before = (root = _PAGE_ROOT[]) === nothing ? nothing : Set(keys(root.children))
        out = f()
        root = _PAGE_ROOT[]
        root === nothing && return out
        for (id, s) in collect(root.children)
            (before === nothing || !(id in before)) && _release_with_cell!(s, root)
        end
        return out
    end
end

# Pinned on the CONCRETE type rather than routed through `slate_render`, for the reason spelled out in
# `figure.jl`: SEB derives `showable` by CALLING `slate_render`, and rendering a Bonito app opens a session.
# Going through that seam would open one session per `showable` probe and another in `show`, orphaning the
# extras. A cheap constant `showable` keeps it to exactly one render per capture.
Base.showable(::SlateExtensionsBase.SlateHtmlMIME, ::Bonito.App) = true
Base.showable(::SlateExtensionsBase.SlateComponentMIME, ::Bonito.App) = false   # an app is HTML, never a component
function Base.show(io::IO, ::SlateExtensionsBase.SlateHtmlMIME, app::Bonito.App)
    return print(io, slate_app_html(app))
end

# SESSION-BOUND: the app's DOM is a handle into a worker session, so Slate re-runs the cell's source for every
# browser page that connects — a reload, a new tab, a reconnect — exactly as a Bonito server serves a fresh
# session per page load. Without this the stored fragment is replayed against a session that no longer exists.
SlateExtensionsBase.slate_live_render(::Bonito.App) = true
