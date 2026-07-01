# Kaimon extension TUI panel for KaimonSlate (rendered in the Extensions tab — press `u`).
# Lets you set the worker Julia-thread count, which governs parallel cell execution:
#   • 1 compute thread  → independent cells overlap only at yield points (I/O / sleep / async).
#   • N compute threads → independent cells run on real OS threads (multi-core CPU parallelism).
# The setting is persisted by the extension (KaimonSlate.set_worker_threads!) and applied by
# respawning the running notebooks' workers. Built entirely from Tachikoma 2.3 widgets.
#
# Panel protocol (see Kaimon docs): init(ctx)→state, update!(state,ctx), view(state,area,buf),
# handle_key!(state,evt)::Bool, cleanup!(state,ctx). `ctx.eval(code)` runs code in the extension
# process and returns (; stdout, stderr, value_repr).

using Tachikoma

# Offered thread specs: "<compute>,<interactive>". One interactive thread is reserved so the gate
# stays responsive; vary the compute count. `auto` lets Julia pick (≈ all cores).
const _OPTIONS = ["1,1", "2,1", "4,1", "8,1", "auto,1"]

mutable struct PanelState
    list::Tachikoma.SelectableList
    ctx::Any
    current::String     # spec currently applied in the extension ("" → default 1,1)
    ncpu::Int
    status::String
end

# Read "(worker_threads(), CPU_THREADS)" out of the extension process via ctx.eval.
function _read_current(ctx)
    cur, ncpu = "", 0
    try
        r = ctx.eval("(KaimonSlate.worker_threads(), Sys.CPU_THREADS)")
        m = match(r"\(\s*\"([^\"]*)\"\s*,\s*(\d+)", String(r.value_repr))
        m !== nothing && (cur = String(m.captures[1]); ncpu = parse(Int, m.captures[2]))
    catch e
        @warn "slate_panel: failed to read worker thread state" exception = (e, catch_backtrace())
    end
    return (cur, ncpu)
end

_items(eff) = [Tachikoma.ListItem(o == eff ? "$o   ● current" : o, Tachikoma.tstyle(:text))
               for o in _OPTIONS]

function init(ctx)
    cur, ncpu = _read_current(ctx)
    eff = isempty(cur) ? "1,1" : cur
    sel = something(findfirst(==(eff), _OPTIONS), 1)
    list = Tachikoma.SelectableList(_items(eff); selected = sel, focused = true)
    PanelState(list, ctx, eff, ncpu,
               "↑/↓ choose · Enter apply (respawns workers) · Esc close")
end

update!(state, ctx) = nothing

function view(state, area::Tachikoma.Rect, buf)
    hh = min(5, area.height)
    hdr = Tachikoma.Rect(area.x, area.y, area.width, hh)
    p = Tachikoma.Paragraph(Tachikoma.Span[
        Tachikoma.Span("Worker Julia threads\n", Tachikoma.tstyle(:title, bold = true)),
        Tachikoma.Span("applied: ", Tachikoma.tstyle(:text_dim)),
        Tachikoma.Span(state.current, Tachikoma.tstyle(:accent, bold = true)),
        Tachikoma.Span("   ·   CPU threads: $(state.ncpu)\n", Tachikoma.tstyle(:text_dim)),
        Tachikoma.Span(state.status, Tachikoma.tstyle(:text_dim)),
    ]; wrap = Tachikoma.word_wrap)
    Tachikoma.render(p, hdr, buf)
    if area.height > hh
        lrect = Tachikoma.Rect(area.x, area.y + hh, area.width, area.height - hh)
        state.list.block = Tachikoma.Block(title = "thread spec  (compute,interactive)",
                                           border_style = Tachikoma.tstyle(:border))
        Tachikoma.render(state.list, lrect, buf)
    end
end

function handle_key!(state, evt::Tachikoma.KeyEvent)::Bool
    if evt.key == :enter
        spec = _OPTIONS[state.list.selected]
        try
            state.ctx.eval("KaimonSlate.set_worker_threads!(\"$spec\")")
            state.current = spec
            state.list.items = _items(spec)
            state.status = "✓ applied $spec — workers respawned. (re-run cells to use the new threads)"
        catch e
            state.status = "⚠ failed to apply: $(sprint(showerror, e))"
        end
        return true
    end
    return Tachikoma.handle_key!(state.list, evt)   # ↑/↓/Home/End/PgUp/PgDn navigation
end

cleanup!(state, ctx) = nothing
