# ── `slate` — Pkg-app entrypoint + status TUI ─────────────────────────────────
# Included into the KaimonSlate module (not a submodule) so it reaches the hub
# internals (_HUB/_LOCK/_hub/_base) directly.
#
# `pkg> app add KaimonSlate` installs a `slate` launcher on PATH:
#   slate             → start (or attach to) the hub, show the status TUI
#   slate <file.jl>   → additionally open that notebook in the browser
#
# Three modes, decided by probing the port before binding it: if a hub already
# answers on $_PORT (typically the Kaimon-spawned extension), we ATTACH as a
# status viewer over HTTP instead of fighting for the port. If nothing answers
# but Slate is registered as an auto-start Kaimon extension, the extension is
# the PRIMARY runtime — we WAIT for its hub instead of racing it for the port
# (Kaimon may be starting right now; grabbing 8765 first would crash the
# extension). `[s]` in the TUI / `--own` on the CLI skips the wait and OWNS the
# hub in-process (same entrypoints the extension uses) — also the immediate
# default when Slate isn't registered.
# First run offers to register Slate as a Kaimon extension — the CONSENTED
# replacement for the old silent `__init__` auto-register (see `__init__`).

import HTTP
using Match: @match
using Tachikoma: Model, Terminal, Frame, Rect, Buffer, KeyEvent, MouseEvent, Block, Style, Span,
                 StatusBar, DataTable, DataColumn, col_right,
                 ResizableLayout, Vertical, Fixed, Fill, split_layout,
                 handle_key!, handle_mouse!, handle_resize!, render_resize_handles!,
                 render, set_string!, set_char!, tstyle, theme, center, bottom, right,
                 BOX_HEAVY, SPINNER_BRAILLE
import Tachikoma

# ── First-run onboarding (plain terminal, before the alt-screen TUI) ──────────

# Offer to register Slate as a Kaimon extension: [Y]es / [n]o / [d]on't ask again.
# Yes → register + persist "yes"; No → nothing (ask again next run); Don't-ask →
# persist "dismissed". Skipped when Kaimon isn't installed, Slate is already
# registered, or stdin isn't a terminal (CI/pipe). A REMOVED entry is respected as a
# choice, not damage: even after a prior Yes the prompt comes back rather than the
# entry being silently repaired (nothing re-registers behind the user's back).
# Returns `true` when it JUST WROTE a registration — Kaimon scans for extensions
# dynamically, so no restart is needed: the caller falls through to the waiting TUI,
# which attaches the moment Kaimon brings the extension's hub up. `input`/`output`
# are injectable for tests.
function _maybe_onboard!(; input::IO = stdin, output::IO = stdout)::Bool
    isdir(_kaimon_dir()) || return false
    _slate_registered() && return false
    ext_prompt_choice() == "dismissed" && return false
    input === stdin && !(stdin isa Base.TTY) && return false
    _onboard_banner(output)
    printstyled(output, "  Register Slate as a Kaimon extension now?  "; bold = true)
    printstyled(output, "[Y]es"; color = :green, bold = true)
    print(output, " · [n]o · [d]on't ask again ")
    printstyled(output, "› "; color = :cyan)
    ans = _read_choice(input)
    println(output, ans in ('\r', '\n') ? "" : string(ans))   # echo — raw mode doesn't
    if ans in ('y', '\r', '\n', ' ')
        set_ext_prompt_choice!("yes")
        return register_extension()
    elseif ans == 'd'
        set_ext_prompt_choice!("dismissed")
        println(output)
        printstyled(output, "  Okay — won't ask again."; color = :yellow)
        println(output, "  (`KaimonSlate.register_extension()` registers manually.)")
    end                          # 'n'/anything else → not persisted, ask again next run
    return false
end

# One keypress, no Enter (on Unix): raw-mode single-char read on a real terminal,
# set with the tty ccall directly — REPL.TerminalMenus.terminal is NOT initialized
# in a `julia -m` process, so it can't be used here. Windows consoles don't take
# jl_tty_set_mode reliably → Enter-terminated line there, first key wins (empty
# line = the [Y]es default). Non-tty input (tests' IOBuffers) reads one char;
# EOF reads as 'n'.
function _read_choice(input::IO)::Char
    if input === stdin && stdin isa Base.TTY
        @static if Sys.iswindows()
            ln = try; readline(stdin); catch; ""; end
            return lowercase(isempty(ln) ? '\n' : first(ln))
        else
            raw = ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, 1) == 0
            try
                return lowercase(read(stdin, Char))
            finally
                raw && ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, 0)
            end
        end
    end
    return lowercase(eof(input) ? 'n' : read(input, Char))
end

# The pre-prompt banner: what registering does, in two lines. Plain terminal output
# (this runs before the alt-screen TUI); printstyled drops the colors on non-tty IO.
function _onboard_banner(io::IO)
    hr() = printstyled(io, "  ", "─"^58, "\n"; color = :cyan)
    println(io)
    hr()
    printstyled(io, "  ◆ Kaimon detected\n"; color = :cyan, bold = true)
    hr()
    println(io, "  Slate can register itself as a Kaimon extension:")
    println(io)
    printstyled(io, "    • "; color = :cyan)
    println(io, "your agents get the slate.* notebook tools")
    printstyled(io, "    • "; color = :cyan)
    println(io, "the in-browser Agent chat panel lights up (Kaimon's agent service)")
    printstyled(io, "    • "; color = :cyan)
    println(io, "Kaimon serves your notebooks from its hub — no extra process")
    println(io)
end

# ── Hub probe / attach ─────────────────────────────────────────────────────────

# Is a hub already answering on our port? (Kaimon extension or another `slate`.)
# Must be checked BEFORE `_hub()` so we never bind-clash; a 200 on /api/notebooks
# distinguishes a real hub from some unrelated service squatting the port.
function _hub_running()
    r = try
        HTTP.get(_base() * "/api/notebooks"; retry = false, status_exception = false)
    catch
        return false
    end
    return r.status == 200
end

# Will Kaimon bring the hub up on its own? True when Slate is a registered extension
# that is enabled AND auto-starts — the case where grabbing the port ourselves would
# crash the extension moments later.
function _ext_autostarts()
    file = joinpath(_kaimon_dir(), "extensions.json")
    isfile(file) || return false
    data = try; JSON.parsefile(file); catch; return false; end
    exts = get(data, "extensions", nothing)
    exts isa AbstractVector || return false
    for e in exts
        e isa AbstractDict || continue
        _is_slate_project(String(get(e, "project_path", ""))) || continue
        return get(e, "enabled", true) === true && get(e, "auto_start", true) === true
    end
    return false
end

# Startup-mode decision (pure — unit-tested): a live hub always wins (attach);
# otherwise defer to a registered auto-start extension unless --own forces it.
_startup_mode(hub_up::Bool, ext_autostart::Bool, own::Bool) =
    hub_up ? :viewer : (own || !ext_autostart) ? :owner : :waiting

# Owner-mode boot: persisted settings BEFORE any worker spawns, reap leftovers from a
# crashed instance, shutdown backstop, bind the hub. Throws if the port can't be bound.
function _own_hub!()
    _load_slate_config!()
    _reap_orphan_workers!()
    atexit(on_shutdown)          # backstop — cleanup! also stops the hub on a clean quit
    _hub()
    return nothing
end

# The live per-notebook status rows (`_notebooks_json` shape) for either mode.
_fetch_notebooks(mode::Symbol) =
    if mode == :owner
        h = _HUB[]
        h === nothing ? Any[] : NotebookServer._notebooks_json(h)
    else
        r = HTTP.get(_base() * "/api/notebooks"; retry = false)
        JSON.parse(String(r.body))
    end

# Open `path` (creating the file like slate.open does) and return its URL.
function _open_notebook_url(mode::Symbol, path::AbstractString)
    path = abspath(expanduser(path))
    isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
    if mode == :owner
        return "$(_base())/n/$(open_notebook!(_hub(), path))"
    end
    r = HTTP.post(_base() * "/api/open", ["Content-Type" => "application/json"],
                  JSON.json(Dict("path" => path)); retry = false)
    return _base() * String(get(JSON.parse(String(r.body)), "url", "/"))
end

# ── The status TUI (Tachikoma, Elm architecture) ──────────────────────────────

mutable struct SlateModel <: Model
    mode::Symbol                 # :owner (we bind the port) | :viewer (attached over HTTP) |
                                 # :waiting (deferring to the Kaimon extension's hub)
    base::String
    quit::Bool
    tick::Int
    msg::String                  # transient status-bar message ("" → key hints)
    msg_until::Float64
    lock::ReentrantLock          # guards notebooks/ok/registered (refresher task ↔ view)
    notebooks::Vector{Any}
    ok::Bool                     # last refresh reached a hub
    registered::Bool             # Slate present in Kaimon's extensions.json
    pending::Union{Nothing,String}  # notebook to open once a hub exists (waiting mode)
    layout::ResizableLayout      # header / table / status bar — divider mouse-draggable
    table::Union{DataTable,Nothing}  # persistent across frames: owns selection, scroll,
                                     # column widths/drag, and the [d] detail modal
    rows::Vector{Any}            # the raw notebook dicts, aligned with the table rows
    _table_hash::UInt            # rebuild the table only when its data changes
    detail::Bool                 # the [d] notebook-detail modal is open
    close_arm_id::String         # [c] pressed once for this notebook — second press confirms
    close_arm_until::Float64
    refresher::Union{Task,Nothing}
end
SlateModel(mode::Symbol; pending = nothing) =
    SlateModel(mode, _base(), false, 0, "", 0.0,
               ReentrantLock(), Any[], false, false, pending,
               ResizableLayout(Vertical, [Fixed(5), Fill(1), Fixed(1)]),
               nothing, Any[], UInt(0), false, "", 0.0, nothing)

# Open the notebook that was queued while we waited for a hub (then browser it).
function _open_pending!(m::SlateModel)
    p = m.pending
    p === nothing && return nothing
    m.pending = nothing
    try
        url = _open_notebook_url(m.mode, p)
        NotebookServer._open_in_browser(url)
        _flash!(m, "opened $p")
    catch e
        _flash!(m, "could not open '$p': $(sprint(showerror, e))")
    end
    return nothing
end

_flash!(m::SlateModel, s::AbstractString) = (m.msg = String(s); m.msg_until = time() + 4.0; nothing)

# Snapshot the shared status under the lock (the refresher task writes it).
_status(m::SlateModel) = lock(m.lock) do
    (copy(m.notebooks), m.ok, m.registered)
end

# Pull fresh status into the model (called from the background refresher).
# In waiting mode this doubles as the extension watcher: the moment the hub
# answers, flip to viewer and open any queued notebook — no restart needed.
function _refresh!(m::SlateModel)
    if m.mode == :waiting
        if _hub_running()
            m.mode = :viewer
            _open_pending!(m)
            _flash!(m, "Kaimon's slate hub is up — attached")
        else
            reg = try; _slate_registered(); catch; false; end
            lock(m.lock) do
                m.notebooks = Any[]; m.ok = false; m.registered = reg
            end
            return nothing
        end
    end
    nbs, ok = try
        (_fetch_notebooks(m.mode), true)
    catch
        (Any[], false)
    end
    m.mode == :owner && _HUB[] === nothing && (ok = false)
    reg = try; _slate_registered(); catch; false; end
    lock(m.lock) do
        m.notebooks = nbs; m.ok = ok; m.registered = reg
    end
    return nothing
end

# [s] in waiting mode: stop deferring to the extension and own the hub now.
function _own_now!(m::SlateModel)
    m.mode == :waiting || return _flash!(m, "hub already running")
    try
        _own_hub!()
        m.mode = :owner
        _open_pending!(m)
        _flash!(m, "started a local hub on $(_base())")
    catch e
        _flash!(m, "could not start a hub: $(sprint(showerror, e))")   # e.g. lost the port race
    end
    _refresh!(m)
    return nothing
end

# Restart the hub we own, re-opening the notebooks it served (async — keeps the UI live).
function _restart_hub!(m::SlateModel)
    m.mode == :waiting && return "no hub yet — [s] starts a local one"
    m.mode == :owner || return "external hub — restart it from Kaimon (Extensions tab)"
    @async begin
        try
            paths = String[]
            lock(_LOCK) do
                h = _HUB[]
                if h !== nothing
                    paths = lock(h.lock) do
                        [abspath(nb.path) for nb in values(h.notebooks)]
                    end
                    try; stop_hub(h); catch; end
                    _HUB[] = nothing
                end
            end
            h2 = _hub()
            for p in paths
                try; open_notebook!(h2, p); catch e
                    @warn "slate: reopen after restart failed" path = p exception = e
                end
            end
            _refresh!(m)
            _flash!(m, "hub restarted on $(_base())")
        catch e
            _flash!(m, "restart failed: $(sprint(showerror, e))")
        end
    end
    return "restarting hub…"
end

# [c] close the selected notebook — armed on the first press, executed on the second
# (within 4 s, same notebook). Open tabs get the SSE `closed:` notice, so they show the
# closed overlay instead of auto-reopening, and their unsaved edits are backed up.
function _close_selected!(m::SlateModel)
    m.mode == :waiting && return _flash!(m, "no hub yet — nothing to close")
    sel = m.table === nothing ? 0 : m.table.selected
    (1 <= sel <= length(m.rows)) || return nothing
    nb = m.rows[sel]
    id = String(get(nb, "id", "")); path = String(get(nb, "path", ""))
    if m.close_arm_id != id || time() > m.close_arm_until
        m.close_arm_id = id
        m.close_arm_until = time() + 4.0
        return _flash!(m, "close '$id'? press c again — open tabs get a notice, unsaved edits are backed up")
    end
    m.close_arm_id = ""
    @async begin
        try
            if m.mode == :owner
                h = _HUB[]
                h === nothing || close_notebook!(h, id)
            else
                HTTP.post(_base() * "/api/close", ["Content-Type" => "application/json"],
                          JSON.json(Dict("path" => path)); retry = false)
            end
            _refresh!(m)
            _flash!(m, "closed $id")
        catch e
            _flash!(m, "close failed: $(sprint(showerror, e))")
        end
    end
    return nothing
end

# Open the selected notebook row (enter), or nothing when the table is empty.
function _open_selected!(m::SlateModel)
    sel = m.table === nothing ? 0 : m.table.selected
    (1 <= sel <= length(m.rows)) || return nothing
    url = "$(m.base)/n/$(String(get(m.rows[sel], "id", "")))"
    NotebookServer._open_in_browser(url)
    _flash!(m, "opening $url …")
    return nothing
end

function Tachikoma.init!(m::SlateModel, ::Terminal)
    m.refresher = @async while !m.quit
        try; _refresh!(m); catch; end
        sleep(1.0)
    end
    return nothing
end

Tachikoma.should_quit(m::SlateModel) = m.quit

function Tachikoma.cleanup!(m::SlateModel)
    m.quit = true                       # stops the refresher loop
    m.mode == :owner && on_shutdown()   # stop the hub + workers we own (idempotent)
    return nothing
end

function Tachikoma.update!(m::SlateModel, evt::KeyEvent)
    if m.detail                       # the [d] detail modal owns the keys
        @match (evt.key, evt.char) begin
            (:escape, _) || (:char, 'd') || (:char, 'q') || (:enter, _) => (m.detail = false)
            (:ctrl_c, _) => (m.quit = true)
            _ => nothing
        end
        return nothing
    end
    dt = m.table
    # Table first: ↑↓ / pgup / pgdn / home / end / ←→ column pan.
    # It leaves our action keys (q/d/c/s/r/o/enter) untouched.
    dt !== nothing && !isempty(m.rows) && handle_key!(dt, evt) && return nothing
    @match (evt.key, evt.char) begin
        (:ctrl_c, _) || (:ctrl, 'c') || (:char, 'q') => (m.quit = true)
        (:enter, _)  => _open_selected!(m)
        (:char, 'd') => begin
            sel = dt === nothing ? 0 : dt.selected
            (1 <= sel <= length(m.rows)) && (m.detail = true)
        end
        (:char, 'c') => _close_selected!(m)
        (:char, 's') => _own_now!(m)
        (:char, 'r') => _flash!(m, _restart_hub!(m))
        (:char, 'o') => begin
            NotebookServer._open_in_browser(m.base)
            _flash!(m, "opening $(m.base) …")
        end
        _ => nothing
    end
    return nothing
end

# Mouse: drag the pane divider, drag column borders, click a row to select it,
# wheel-scroll the table. A live column drag keeps priority over the divider.
function Tachikoma.update!(m::SlateModel, evt::MouseEvent)
    dt = m.table
    (dt === nothing || dt.col_drag == 0) && handle_resize!(m.layout, evt)
    dt === nothing && return nothing
    handle_mouse!(dt, evt)
    return nothing
end

function Tachikoma.view(m::SlateModel, f::Frame)
    m.tick += 1
    nbs, ok, registered = _status(m)
    panes = split_layout(m.layout, f.area)
    length(panes) == 3 || return
    _view_header(m, panes[1], f.buffer, ok, registered)
    _sync_table!(m, nbs)
    m.table === nothing || (m.table.tick = m.tick; render(m.table, panes[2], f.buffer))
    _view_statusbar(m, panes[3], f.buffer, ok)
    render_resize_handles!(f.buffer, m.layout)
    m.detail && _view_detail(m, f)   # on top of everything
    return nothing
end

# The [d] modal: a heavy-bordered Block (Kaimon-modal style) over the table, listing
# everything the status payload knows about the selected notebook.
function _view_detail(m::SlateModel, f::Frame)
    sel = m.table === nothing ? 0 : m.table.selected
    if !(1 <= sel <= length(m.rows))
        m.detail = false
        return nothing
    end
    fields = _nb_detail(m.rows, sel)
    buf = f.buffer
    label_w = maximum(textwidth(first(p)) for p in fields) + 2
    val_w = maximum(textwidth(last(p)) for p in fields)
    w = clamp(label_w + val_w + 4, 40, max(20, f.area.width - 4))
    h = min(f.area.height - 2, length(fields) + 3)   # borders + hint row
    inner = render(Block(title = " $(String(get(m.rows[sel], "id", "?"))) ",
                         border_style = tstyle(:accent, bold = true),
                         title_style = tstyle(:accent, bold = true),
                         box = BOX_HEAVY),
                   center(f.area, w, h), buf)
    for y in inner.y:bottom(inner), x in inner.x:right(inner)   # blank the interior
        set_char!(buf, x, y, ' ', Style(bg = theme().bg))
    end
    y = inner.y
    for (lab, val) in fields
        y > bottom(inner) - 1 && break
        set_string!(buf, inner.x + 1, y, rpad(lab, label_w), tstyle(:text_dim), inner)
        set_string!(buf, inner.x + 1 + label_w, y, val, tstyle(:text), inner)
        y += 1
    end
    set_string!(buf, inner.x + 1, bottom(inner), "[esc/d] close", tstyle(:text_dim), inner)
    return nothing
end

function _view_header(m::SlateModel, area::Rect, buf::Buffer, ok::Bool, registered::Bool)
    inner = render(Block(title = " slate — KaimonSlate ",
                         border_style = tstyle(:accent),
                         title_style = tstyle(:accent, bold = true)),
                   area, buf)
    inner.width < 24 && return
    x = inner.x + 1
    lbl(row, s) = set_string!(buf, x, inner.y + row, rpad(s, 8), tstyle(:text_dim), inner)

    lbl(0, "Server")
    if m.mode == :waiting
        dots = "."^mod1(m.tick ÷ 8, 3)
        set_string!(buf, x + 8, inner.y, "◌ ", tstyle(:warning), inner)
        set_string!(buf, x + 10, inner.y,
            "waiting for Kaimon's slate extension$dots  ([s] starts a local hub instead)",
            tstyle(:warning), inner)
    else
        set_string!(buf, x + 8, inner.y, ok ? "● " : "○ ", ok ? tstyle(:success) : tstyle(:error), inner)
        set_string!(buf, x + 10, inner.y,
            !ok ? (m.mode == :owner ? "starting…" : "hub not answering") :
            m.mode == :owner ? "up — this process owns the hub" :
                               "attached — external hub (Kaimon extension)",
            tstyle(:text), inner)
    end
    lbl(1, "URL")
    set_string!(buf, x + 8, inner.y + 1, m.base, tstyle(:accent), inner)
    lbl(2, "Kaimon")
    ktxt, kst = !isdir(_kaimon_dir()) ? ("not installed", tstyle(:text_dim)) :
                registered            ? ("extension registered", tstyle(:success)) :
                                        ("installed — extension not registered", tstyle(:warning))
    set_string!(buf, x + 8, inner.y + 2, ktxt, kst, inner)
    return nothing
end

# Relative "edited" age from a unix mtime — compact, single unit.
function _rel_ago(unix::Int)
    unix <= 0 && return "—"
    d = max(0, round(Int, time()) - unix)
    d < 60 && return "$(d)s"
    d < 3600 && return "$(d ÷ 60)m"
    d < 86400 && return "$(d ÷ 3600)h"
    return "$(d ÷ 86400)d"
end

_geti(nb, k) = (v = get(nb, k, 0); v isa Number ? Int(v) : 0)

# The [d] detail modal: everything the status payload knows about one notebook.
function _nb_detail(rows::Vector{Any}, row::Int)
    (1 <= row <= length(rows)) || return Pair{String,String}[]
    nb = rows[row]
    id = String(get(nb, "id", "?"))
    ms = (v = get(nb, "compute_ms", 0.0); v isa Number ? Float64(v) : 0.0)
    port = get(nb, "port", nothing)
    ["Title"   => String(get(nb, "title", "")),
     "Id"      => id,
     "Path"    => String(get(nb, "path", "")),
     "URL"     => "$(_base())/n/$id",
     "Cells"   => "$(_geti(nb, "cells")) ($(_geti(nb, "code")) code · $(_geti(nb, "md")) md)",
     "State"   => "$(_geti(nb, "running")) running · $(_geti(nb, "stale")) stale · $(_geti(nb, "errors")) err",
     "Binds"   => string(_geti(nb, "binds")),
     "Compute" => ms >= 1000 ? "$(round(ms / 1000; digits = 1))s" : "$(round(Int, ms))ms",
     "Edited"  => _rel_ago(_geti(nb, "mtime")) * " ago",
     "Worker"  => port isa Number ? ":$(Int(port))" : "in-process"]
end

# Build/rebuild the notebooks DataTable — only when the data (or the spinner/age
# frame) changes; interaction state (selection, scroll, column widths, an open
# detail modal) is carried across rebuilds so the mouse and [d] keep working.
function _sync_table!(m::SlateModel, nbs::Vector{Any})
    rows = Any[nb for nb in nbs if nb isa AbstractDict]
    n = length(rows)
    anim = any(nb -> _geti(nb, "running") > 0, rows)
    h = hash(([(get(nb, "id", ""), _geti(nb, "cells"), _geti(nb, "running"), _geti(nb, "stale"),
                _geti(nb, "errors"), get(nb, "port", 0), _geti(nb, "mtime")) for nb in rows],
              anim ? m.tick ÷ 2 : 0,   # spinner frame
              m.tick ÷ 30))            # "edited Xs ago" refresh (~2 s at 15 fps)
    old = m.table
    old !== nothing && m._table_hash == h && return
    col_name = Any[]; col_cells = Any[]; col_run = Any[]; col_stale = Any[]
    col_err = Any[]; col_edited = Any[]; col_worker = Any[]; col_url = Any[]
    row_styles = Style[]
    tot_cells = 0; tot_run = 0; tot_stale = 0; tot_err = 0
    for nb in rows
        errs, running, stale = _geti(nb, "errors"), _geti(nb, "running"), _geti(nb, "stale")
        cells = _geti(nb, "cells")
        tot_cells += cells; tot_run += running; tot_stale += stale; tot_err += errs
        st = errs > 0    ? tstyle(:error) :
             running > 0 ? tstyle(:accent) :
             stale > 0   ? tstyle(:warning) : tstyle(:success)
        icon = running > 0 ?
            string(SPINNER_BRAILLE[mod1(m.tick ÷ 2 + 1, length(SPINNER_BRAILLE))]) : "●"
        id = String(get(nb, "id", "?"))
        title = String(get(nb, "title", "")); isempty(title) && (title = id)
        port = get(nb, "port", nothing)
        push!(col_name, Span("$icon $title", st))
        push!(col_cells, string(cells))
        push!(col_run, running == 0 ? "" : string(running))
        push!(col_stale, stale == 0 ? "" : string(stale))
        push!(col_err, errs == 0 ? "" : string(errs))
        push!(col_edited, _rel_ago(_geti(nb, "mtime")))
        push!(col_worker, port isa Number ? ":$(Int(port))" : "")
        push!(col_url, "/n/$id")
        push!(row_styles, st)
    end
    if n == 0
        push!(col_name, "No notebooks open — browser index, slate.open, or `slate <file.jl>`")
        for c in (col_cells, col_run, col_stale, col_err, col_edited, col_worker, col_url)
            push!(c, "")
        end
        push!(row_styles, tstyle(:text_dim))
    end
    agg = n == 0 ? "" :
        " — $tot_cells cells" * (tot_run > 0 ? " · $tot_run running" : "") *
        (tot_stale > 0 ? " · $tot_stale stale" : "") * (tot_err > 0 ? " · $tot_err err" : "")
    dt = DataTable(
        [
            DataColumn("Notebook", col_name),
            DataColumn("Cells", col_cells; width = 6, align = col_right),
            DataColumn("Run", col_run; width = 5, align = col_right),
            DataColumn("Stale", col_stale; width = 6, align = col_right),
            DataColumn("Err", col_err; width = 5, align = col_right),
            DataColumn("Edited", col_edited; width = 7, align = col_right),
            DataColumn("Worker", col_worker; width = 8),
            DataColumn("URL", col_url),
        ];
        selected = n == 0 ? 0 :
                   old === nothing ? 1 : clamp(max(old.selected, 1), 1, n),
        block = Block(title = "Notebooks ($n)$agg — [d] details",
                      border_style = tstyle(:border),
                      title_style = tstyle(:text, bold = true)),
        tick = m.tick,
        row_styles = row_styles,
    )
    if old !== nothing   # carry the interaction state across the rebuild
        dt.offset = old.offset
        dt.col_offset = old.col_offset
        dt.col_widths = old.col_widths
        dt.col_drag = old.col_drag
        dt.col_drag_start_x = old.col_drag_start_x
        dt.col_drag_start_w = old.col_drag_start_w
        dt.last_content_area = old.last_content_area
        dt.last_col_positions = old.last_col_positions
        dt.last_widths = old.last_widths
    end
    m.rows = rows
    m.table = dt
    m._table_hash = h
    return nothing
end

function _view_statusbar(m::SlateModel, area::Rect, buf::Buffer, ok::Bool)
    left = if time() < m.msg_until && !isempty(m.msg)
        [Span(" $(m.msg) ", tstyle(:warning, bold = true))]
    elseif m.mode == :waiting
        [Span(" [q]uit ", tstyle(:text_dim)),
         Span(" [s]tart local hub ", tstyle(:warning))]
    else
        [Span(" [q]uit ", tstyle(:text_dim)),
         Span(" [↑↓/enter] open notebook ", tstyle(:text_dim)),
         Span(" [d]etails ", tstyle(:text_dim)),
         Span(" [c]lose notebook ", tstyle(:text_dim)),
         Span(" [o]pen index ", tstyle(:text_dim)),
         Span(" [r]estart hub ", tstyle(:text_dim))]
    end
    mode_span = m.mode == :waiting ?
        Span(" waiting ", tstyle(:warning, bold = true)) :
        Span(m.mode == :owner ? " owner " : " viewer ",
             ok ? tstyle(:success, bold = true) : tstyle(:error, bold = true))
    right = [mode_span, Span(" $(m.base) ", tstyle(:accent))]
    render(StatusBar(left = left, right = right), area, buf)
    return nothing
end

# ── Entrypoint ─────────────────────────────────────────────────────────────────

const _APP_HELP = """
slate — the KaimonSlate notebook hub + status TUI

Usage:
  slate                 start (or attach to) the hub and show the status TUI
  slate <file.jl>       also open that notebook in the browser (created if missing)
  slate --own           own the hub in-process even if the Kaimon extension is
                        registered (default is to WAIT for the extension's hub)
  slate --status        print the hub status and open notebooks, then exit
                        (exit code 0 = hub up, 1 = no hub)
  slate -h | --help     show this help

Environment:
  KAIMONSLATE_PORT      hub port (default 8765)
  KAIMONSLATE_NO_OPEN   =1 → never open a browser
"""

# `--status`: one-shot, script-friendly status print (no TUI). 0 = hub up, 1 = not.
function _print_status()::Int
    if !_hub_running()
        printstyled("  ○ no hub on $(_base())\n"; color = :red)
        println(_ext_autostarts() ?
            "  Slate is registered as a Kaimon extension — start Kaimon to bring it up (or `slate --own`)." :
            "  Run `slate` to start one.")
        return 1
    end
    nbs = try; _fetch_notebooks(:viewer); catch; Any[]; end
    printstyled("  ● hub up at $(_base())"; color = :green, bold = true)
    println(" — $(length(nbs)) notebook$(length(nbs) == 1 ? "" : "s") open")
    for nb in nbs
        nb isa AbstractDict || continue
        geti(k) = (v = get(nb, k, 0); v isa Number ? Int(v) : 0)
        id = String(get(nb, "id", "?"))
        parts = ["$(geti("cells")) cells"]
        geti("running") > 0 && push!(parts, "$(geti("running")) running")
        geti("stale") > 0 && push!(parts, "$(geti("stale")) stale")
        geti("errors") > 0 && push!(parts, "$(geti("errors")) err")
        printstyled("    • "; color = :cyan)
        print(rpad(id, 22), join(parts, " · "), "  ")
        printstyled("$(_base())/n/$id\n"; color = :light_black)
    end
    return 0
end

# The `slate` app body (separate from `@main` so tests can call it directly).
function _app_main(args::Vector{String})::Int
    file = nothing
    own = false
    for a in args
        if a in ("-h", "--help")
            print(_APP_HELP)
            return 0
        elseif a == "--status"
            return _print_status()
        elseif a == "--own"
            own = true
        elseif startswith(a, "-")
            println(stderr, "slate: unknown option '$a'\n")
            print(stderr, _APP_HELP)
            return 2
        elseif file === nothing
            file = a
        else
            println(stderr, "slate: too many arguments (one notebook file)")
            return 2
        end
    end
    if _maybe_onboard!()
        # Kaimon scans for extensions dynamically, so the entry we just wrote is picked up
        # without a restart. Don't exit — fall through to `:waiting`, where the TUI polls for
        # Kaimon's hub and attaches the moment it answers (or press [s] to own a local hub).
        println()
        printstyled("  ✓ Registered as a Kaimon extension — attaching to its hub…\n"; color = :green, bold = true)
        println()
    end
    mode = _startup_mode(_hub_running(), _ext_autostarts(), own)
    if mode == :owner
        try
            _own_hub!()
        catch e
            println(stderr, "slate: could not start the hub on port $_PORT: ", sprint(showerror, e))
            println(stderr, "Is another service using the port? Set KAIMONSLATE_PORT to move it.")
            return 1
        end
    end
    pending = nothing
    if file !== nothing
        if mode == :waiting
            pending = String(file)   # opened the moment the extension's hub answers
        else
            url = try
                _open_notebook_url(mode, String(file))
            catch e
                println(stderr, "slate: could not open '$file': ", sprint(showerror, e))
                mode == :owner && on_shutdown()
                return 1
            end
            NotebookServer._open_in_browser(url)
        end
    end
    m = SlateModel(mode; pending)
    _refresh!(m)                     # first frame renders with data
    Tachikoma.app(m; fps = 15)
    return 0
end

# `pkg> app add KaimonSlate` → a `slate` shim running `julia -m KaimonSlate …`,
# which calls this entrypoint. Guarded so the package still loads on Julia < 1.11
# (the app itself needs 1.12 for Pkg apps).
@static if isdefined(Base, Symbol("@main"))
    (@main)(args)::Cint = Cint(_app_main(String[String(a) for a in args]))
end
