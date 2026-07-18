# Shared "preparing environment" progress classifier (engine + worker).
#
# Opening a notebook whose deps aren't precompiled — Makie is the canonical case — pays a
# one-time precompile that used to be INVISIBLE: it happens lazily under a running cell's
# output capture (so its "Precompiling…" progress lands in the cell buffer, unseen), and the
# topbar just reads "Running 0/N", frozen, indistinguishable from a hang. This turns the raw
# line stream from `Pkg.instantiate()`/`Pkg.precompile()` into a structured status the UI can
# narrate — a real k/N bar, the current package, elapsed, and a one-time-cost note.
#
# Pure Base string ops, no deps — `include`d into BOTH `module SlateWorker` (worker.jl, which
# drives a proactive precompile on boot) and the engine/hub (which classifies a REMOTE worker's
# streamed provision output the same way). One classifier, so local and remote read identically.
#
# The producer emits control markers around the real Pkg output so the classifier needn't guess
# the denominator or the end:
#   @@SLATE_PREP total=<n>     — n packages will be (re)compiled (from `Base.isprecompiled`)
#   @@SLATE_PREP phase=<name>  — force a phase (resolve|install|precompile)
#   @@SLATE_PREP done          — the run finished cleanly

mutable struct PrepareTracker
    phase::String            # "" | resolve | install | precompile | done | error  (drives the k/N bar)
    stage::String            # coarse bring-up step headline (e.g. "Starting worker process") — see `@@SLATE_PREP stage=`
    total::Int               # packages needing precompile (-1 = unknown)
    done::Int                # ✓/✗/? lines seen
    pkg::String              # most-recently-touched package
    recent::Vector{String}   # last few completed (a ticker)
    installed::Int           # resolver "+ Pkg" lines counted (install phase)
    note::String             # headline / summary / error text
    err::Bool
    t0::Float64              # start wall time (for elapsed)
end
PrepareTracker(t0::Float64 = time()) = PrepareTracker("", "", -1, 0, "", String[], 0, "", false, t0)

# A completion line, color OFF (non-TTY), is `<12-char timing>  ✓ Name` (✓ ok, ✗ failed,
# ? not-precompilable). ✗ pads with spaces instead of a timing token — the optional timing
# group covers both. The name tail may carry `describe_pkg` annotations; keep it as-is.
const _PREP_DONE_RE = r"^\s*(?:[\d.]+\s*\w{1,3}\s+)?(✓|✗|\?)\s+(.+?)\s*$"
# `  [8bf52ea8] + CRC32c v1.11.0` and friends — the resolver/installer churn we DON'T want shown raw.
const _PREP_RESOLVE_RE = r"^\s*\[?[0-9a-f]{6,}\]?\s*[+~\-↑↓]\s"

# Feed one raw output line. Returns true if the STRUCTURED state changed (caller should emit a
# snapshot); false for noise (which the caller may still tuck into the raw "details" log).
function prepare_feed!(tr::PrepareTracker, raw::AbstractString)
    s = strip(String(raw))
    isempty(s) && return false

    # ── control markers from our own producer ────────────────────────────────────────────────
    if startswith(s, "@@SLATE_PREP")
        rest = strip(s[nextind(s, 1, length("@@SLATE_PREP")):end])
        if startswith(rest, "total=")
            n = tryparse(Int, strip(rest[nextind(rest, 1, length("total=")):end]))
            n === nothing || (tr.total = n; tr.phase = tr.phase == "" ? "precompile" : tr.phase)
        elseif startswith(rest, "stage=")
            # Coarse bring-up step (payload sync, env build, worker spawn, connect) — the banner headline.
            # Orthogonal to `phase`: the precompile k/N bar (phase) rides UNDER it while packages compile.
            tr.stage = strip(rest[nextind(rest, 1, length("stage=")):end])
        elseif startswith(rest, "phase=")
            tr.phase = strip(rest[nextind(rest, 1, length("phase=")):end])
        elseif startswith(rest, "done")
            tr.phase = "done"
        elseif startswith(rest, "error")
            tr.phase = "error"; tr.err = true
            m = findfirst(' ', rest); m === nothing || (tr.note = strip(rest[nextind(rest, 1):end]))
        end
        return true
    end

    # ── per-package precompile completion ────────────────────────────────────────────────────
    m = match(_PREP_DONE_RE, s)
    if m !== nothing
        mark = m.captures[1]; name = String(m.captures[2])
        tr.phase = "precompile"
        tr.done += 1
        tr.pkg = name
        pushfirst!(tr.recent, name); length(tr.recent) > 4 && pop!(tr.recent)
        mark == "✗" && (tr.err = true)
        tr.total >= 0 && tr.done > tr.total && (tr.total = tr.done)   # extensions can overshoot the estimate
        return true
    end

    # ── final summary ("N dependencies successfully precompiled in X seconds. …") ─────────────
    if occursin("successfully precompiled", s) || occursin("dependencies precompiled", s)
        tr.note = s
        return true
    end

    # ── precompile phase header ──────────────────────────────────────────────────────────────
    if startswith(s, "Precompiling")
        tr.phase = "precompile"
        return true
    end

    # ── resolve / install churn: acknowledged as context, NEVER shown raw ─────────────────────
    if match(_PREP_RESOLVE_RE, s) !== nothing
        tr.phase == "precompile" && return false          # trailing manifest echo after compile — ignore
        tr.installed += 1
        tr.phase = "install"
        return true
    end
    if startswith(s, "Updating") || startswith(s, "Resolving") || startswith(s, "Installed") ||
       startswith(s, "Downloaded") || startswith(s, "Cloning") || startswith(s, "Fetching")
        tr.phase == "precompile" && return false
        tr.phase = tr.phase in ("", "resolve") ? "resolve" : tr.phase
        return true
    end

    return false   # Info/warn banners and other noise → raw details log only
end

# Is there anything worth showing? (No point flashing a banner for a fully-warm env.)
prepare_active(tr::PrepareTracker) =
    !isempty(tr.stage) || tr.phase in ("resolve", "install", "precompile", "error") ||
    tr.total > 0 || tr.done > 0

# Minimal JSON (hand-built; the worker has no JSON dep). Phase/counts/current pkg/elapsed/note.
function prepare_json(tr::PrepareTracker)
    esc(x) = replace(String(x), '\\' => "\\\\", '"' => "\\\"", '\n' => " ", '\r' => " ")
    recent = "[" * join(("\"" * esc(r) * "\"" for r in tr.recent), ",") * "]"
    secs = round(Int, time() - tr.t0)
    string("{\"phase\":\"", esc(tr.phase), "\",\"stage\":\"", esc(tr.stage),
           "\",\"k\":", tr.done, ",\"n\":", tr.total,
           ",\"pkg\":\"", esc(tr.pkg), "\",\"installed\":", tr.installed,
           ",\"recent\":", recent, ",\"secs\":", secs,
           ",\"err\":", tr.err ? "true" : "false", ",\"note\":\"", esc(tr.note), "\"}")
end
