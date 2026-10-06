# `@bind` as a live Observable: the value-listener dispatch a figure consumes instead of being
# recomputed by, the cell-local Observable that makes the usual `lift` safe to write, `hidden(…)`
# for a control drawn outside the notebook, and the in-process kernel capabilities that standalone
# Slate needs (live re-render, extension-served assets, worker-reset hooks).
using ReTest
using KaimonSlate
using Observables
const RE = KaimonSlate.ReportEngine

# A notebook namespace without a server: `standalone!` installs the same `_populate_notebook_ns!`
# contract the worker does, so these exercise the real bind machinery rather than a stand-in.
function fresh_ns()
    m = Module(gensym("nb"))
    Core.eval(m, :(using KaimonSlate, Observables))
    KaimonSlate.standalone!(m; dir = @__DIR__)
    return m
end
nsget(m, s) = getfield(m, Symbol(s))

@testset "bind listeners" begin

    @testset "dispatch is INLINE, unlike @onchange" begin
        m = fresh_ns()
        Core.eval(m, :(@bind x Slider(0.0:0.1:1.0)))
        seen = Float64[]
        nsget(m, "__slate_on_bind")(:x, v -> push!(seen, v))
        nsget(m, "__slate_set_bind")(:x, 0.4)
        # No yield: a value listener must land in the same turn the global is assigned, so a cell
        # reading the Observable and one reading the global can never disagree.
        @test seen == [0.4]
        @test Core.eval(m, :x) == 0.4
    end

    @testset "many listeners per control" begin
        m = fresh_ns()
        Core.eval(m, :(@bind x Slider(0.0:0.1:1.0)))
        a, b = Float64[], Float64[]
        nsget(m, "__slate_on_bind")(:x, v -> push!(a, v))
        nsget(m, "__slate_on_bind")(:x, v -> push!(b, v))
        nsget(m, "__slate_set_bind")(:x, 0.7)
        @test a == [0.7] && b == [0.7]      # one control can drive several figures
    end

    @testset "unregister removes exactly one" begin
        m = fresh_ns()
        Core.eval(m, :(@bind x Slider(0.0:0.1:1.0)))
        a, b = Float64[], Float64[]
        un = nsget(m, "__slate_on_bind")(:x, v -> push!(a, v))
        nsget(m, "__slate_on_bind")(:x, v -> push!(b, v))
        un()
        nsget(m, "__slate_set_bind")(:x, 0.2)
        @test isempty(a)
        @test b == [0.2]
    end

    @testset "a throwing listener is isolated" begin
        m = fresh_ns()
        Core.eval(m, :(@bind x Slider(0.0:0.1:1.0)))
        seen = Float64[]
        nsget(m, "__slate_on_bind")(:x, _ -> error("boom"))
        nsget(m, "__slate_on_bind")(:x, v -> push!(seen, v))
        nsget(m, "__slate_set_bind")(:x, 0.9)
        # One bad figure must not strand its siblings or wedge the control itself.
        @test seen == [0.9]
        @test Core.eval(m, :x) == 0.9
    end

    @testset "the @onchange slot still works, and stays async" begin
        m = fresh_ns()
        Core.eval(m, :(@bind x Slider(0.0:0.1:1.0)))
        Core.eval(m, :(const HITS = Float64[]))
        Core.eval(m, :(@onchange x (push!(HITS, x))))
        nsget(m, "__slate_set_bind")(:x, 0.5)
        @test isempty(Core.eval(m, :HITS))        # spawned, not inline — unchanged behaviour
        yield(); sleep(0.05)
        @test Core.eval(m, :HITS) == [0.5]
    end
end

@testset "bind_observable" begin

    @testset "seeded from the registry and tracks changes" begin
        m = fresh_ns()
        Core.eval(m, :(@bind x Slider(0.0:0.1:1.0; default = 0.3)))
        o = Core.eval(m, :(bind_observable(:x)))
        @test o[] == 0.3
        nsget(m, "__slate_set_bind")(:x, 0.8)
        @test o[] == 0.8
        @test Core.eval(m, :x) == 0.8             # agrees with the global
    end

    @testset "two consumers of one control" begin
        m = fresh_ns()
        Core.eval(m, :(@bind x Slider(0.0:0.1:1.0)))
        o1 = Core.eval(m, :(bind_observable(:x)))
        o2 = Core.eval(m, :(bind_observable(:x)))
        nsget(m, "__slate_set_bind")(:x, 0.6)
        @test o1[] == 0.6 && o2[] == 0.6
    end

    @testset "an unknown control names itself" begin
        m = fresh_ns()
        err = try; Core.eval(m, :(bind_observable(:nope))); catch e; sprint(showerror, e); end
        @test occursin("nope", err)
        @test occursin("@bind", err)              # says how to fix it, not just that it failed
    end

    @testset "listeners do not accumulate across repeated cell runs" begin
        # The leak this design exists to prevent: a session-bound figure cell re-runs on every
        # browser connect, and anything it attached to notebook-lifetime state would survive the
        # render that made it — holding a whole Figure and its GPU buffers each time.
        m = fresh_ns()
        Core.eval(m, :(@bind x Slider(0.0:0.1:1.0)))
        listeners = nsget(m, "__slate_bind_listeners")
        cleanups = nsget(m, "__slate_cleanups")
        counts = map(1:6) do _
            RE._run_cell_cleanups!(cleanups, "figcell")     # what Slate fires before a re-run
            task_local_storage(:slate_cell, "figcell") do
                o = Core.eval(m, :(bind_observable(:x)))
                for _ in 1:3; Observables.map(v -> v * 2, o); end
            end
            length(listeners[:x])
        end
        @test all(==(1), counts)
    end
end

@testset "live re-render on the in-process kernel" begin
    # Session-bound outputs (a WGLMakie figure) are stored as a non-booting placeholder and
    # replaced when a browser connects. That hook calls `rerender_live`, which had only a
    # GateKernel method — so standalone Slate fell through to the generic no-op and every such
    # figure stayed on "⟳ connecting…" forever, with its cell still reporting `fresh`.
    rep = RE.Report("rerender_test", "")
    mod = RE.report_module(rep)
    Core.eval(mod, :(const _MARK = Ref(0)))

    lock(RE._LIVE_OUTPUTS_LOCK) do
        RE._LIVE_OUTPUTS["figcell"] =
            (source = "_MARK[] += 1; HTML(\"<canvas id=live-\$(_MARK[])></canvas>\")",
             filename = "cell:figcell")
    end
    try
        out = RE.rerender_live(RE.InProcessKernel(), rep)
        @test length(out) == 1
        @test out[1][1] == "figcell"                       # keyed by the cell it belongs to
        @test out[1][2].live                               # still flagged session-bound
        @test occursin("canvas", String(out[1][2].mime[end][2]))
        @test Core.eval(mod, :(_MARK[])) == 1              # the SOURCE re-ran, not a replay

        # The generic fallback is what standalone used to get.
        @test isempty(RE.rerender_live(RE.InProcessKernel("", ""), RE.Report("empty", "")))
    finally
        lock(RE._LIVE_OUTPUTS_LOCK) do; delete!(RE._LIVE_OUTPUTS, "figcell"); end
    end
end

@testset "a render can save an asset" begin
    # The sink used to be harvested before the RETURN VALUE was rendered, and a package puts its render
    # in a `show`/`slate_render` method — which runs in that later block. So the one call site that most
    # wants `save_asset` was the one where it silently did nothing: the bytes were dropped and the path
    # handed back resolved to a 404.
    rep = RE.Report("render_asset", "")
    mod = RE.report_module(rep)
    src = """
    struct RenderSaver end
    function Base.show(io::IO, ::MIME"text/html", ::RenderSaver)
        p = SlateExtensionsBase.slate_save_asset("fromshow", UInt8[9, 9, 9])
        print(io, "<div data-a='", p, "'>x</div>")
    end
    RenderSaver()
    """
    ctx = RE._build_slate_ctx(mod, "nb", "", String[])
    Core.eval(mod, :(import SlateExtensionsBase))
    w = RE.run_capture(mod, src, "cell:rs"; capture = RE.DemuxCapture(), slate_ctx = ctx)

    @test length(w.assets) == 1                        # harvested from inside `show`
    a = only(w.assets)
    @test a.bytes == UInt8[9, 9, 9]
    html = String(w.mime[end][2])
    @test occursin(String(a.path), html)               # the markup names the path that was registered
    @test !occursin("nothing", html)                   # the accessor answered a path, not its fallback

    # The sink must not outlive the eval — the task is reused, and a later handler would otherwise
    # harvest into a cell that has finished.
    @test !haskey(task_local_storage(), :slate_assets)
end

@testset "the save_asset capability answers nothing where nothing would be harvested" begin
    # Slate installs the context on paths that harvest no assets (a `slate_on` handler, the reactive
    # handler task, the in-process call path). Storing bytes there would hand back a path that 404s, so
    # the capability reports no and the caller falls back to inlining.
    @test !haskey(task_local_storage(), :slate_assets)       # no sink on this task
    @test RE._ctx_save_asset("x", UInt8[1]) === nothing
    # A child task never inherits task-local storage, so a render that spawns one gets the same answer.
    task_local_storage(:slate_assets, Any[])
    try
        @test RE._ctx_save_asset("x", UInt8[1]) isa String   # with a sink, a real path
        @test fetch(@async RE._ctx_save_asset("y", UInt8[2])) === nothing
    finally
        delete!(task_local_storage(), :slate_assets)
    end
end

@testset "the gate's flat asset channel regroups by cell" begin
    # Across the gate the re-render's assets ride as one flat vector tagged with the owning cell, because
    # a vector-per-cell is the nesting the structured return does not survive (which is why the rendered
    # chunks go as parallel arrays). The hub has to put them back.
    res = (; cids = ["a", "b"], mimetypes = ["text/html", "text/html"], b64s = ["", ""],
           assets = Any[(; cell = "a", name = "x", path = "data/x.bin", mime = "m", bytes = UInt8[1]),
                        (; cell = "b", name = "y", path = "data/y.bin", mime = "m", bytes = UInt8[2]),
                        (; cell = "a", name = "z", path = "data/z.bin", mime = "m", bytes = UInt8[3])])
    g = RE._regroup_rerender_assets(res)
    @test sort(collect(keys(g))) == ["a", "b"]
    @test [a.name for a in g["a"]] == ["x", "z"]          # both of a's, in the order sent
    @test [a.name for a in g["b"]] == ["y"]

    # An untagged record is dropped rather than landing on an arbitrary cell.
    @test isempty(RE._regroup_rerender_assets((; assets = Any[(; name = "orphan")])))
    # A worker on older code sends no `assets` at all — that pair must still work, not error.
    @test isempty(RE._regroup_rerender_assets((; cids = String[], mimetypes = String[], b64s = String[])))
end

@testset "a live re-render carries the assets it saved" begin
    # A re-render is a real eval, so a live cell calling `save_asset` registers bytes into that run's
    # sink and the markup it returns references them by path. Returning the rendered chunks without the
    # assets published markup whose paths nothing had registered — every `Slate.asset` in a reconnected
    # live output then resolved to a 404, which reads as a broken figure rather than a missing asset.
    rep = RE.Report("rerender_assets", "")
    mod = RE.report_module(rep)
    src = "ref = save_asset(\"blob\", UInt8[1, 2, 3]); HTML(string(\"<div data-a='\", ref, \"'></div>\"))"
    lock(RE._LIVE_OUTPUTS_LOCK) do
        RE._LIVE_OUTPUTS["assetcell"] = (source = src, filename = "cell:assetcell")
    end
    try
        out = RE.rerender_live(RE.InProcessKernel(), rep)
        @test length(out) == 1 && out[1][1] == "assetcell"
        assets = out[1][2].assets
        @test length(assets) == 1
        a = only(assets)
        @test a.bytes == UInt8[1, 2, 3]
        # The path in the record is the one the markup points at, or the page asks for an asset that
        # was registered under a different name.
        @test occursin(String(a.path), String(out[1][2].mime[end][2]))
    finally
        lock(RE._LIVE_OUTPUTS_LOCK) do; delete!(RE._LIVE_OUTPUTS, "assetcell"); end
    end
end

@testset "extension-served assets on the in-process kernel" begin
    # The hub answers `/n/<id>/served/<hash>` by asking the kernel. Only GateKernel implemented it,
    # so standalone returned `nothing` and the URL 404'd — and an extension that serves its
    # front-end runtime that way (BonitoSlate emits a <script src> for the Bonito runtime) could
    # never boot. Nothing errors; the figure just spins.
    SEB = Base.loaded_modules[Base.PkgId(Base.UUID("bc31d39e-4442-48fa-b9ae-1bd99fed63f7"),
                                         "SlateExtensionsBase")]
    url  = SEB.provide_served_asset!(Vector{UInt8}("console.log('rt')"); mime = "text/javascript")
    hash = String(last(split(url, '/')))          # what the route's {hash} param carries
    rep  = RE.Report("served_test", "")

    got = RE.get_served_asset(RE.InProcessKernel(), rep, hash)
    @test got !== nothing
    @test got[1] == "text/javascript"
    @test String(copy(got[2])) == "console.log('rt')"
    @test RE.get_served_asset(RE.InProcessKernel(), rep, "nosuchhash") === nothing
end

@testset "worker-reset hooks fire in process" begin
    # No worker to restart, but the extensions' hooks live in THIS process and a namespace rebuild
    # is the same event to them — state keyed to the old namespace has to be dropped either way.
    SEB = Base.loaded_modules[Base.PkgId(Base.UUID("bc31d39e-4442-48fa-b9ae-1bd99fed63f7"),
                                         "SlateExtensionsBase")]
    fired = Ref(0)
    SEB.on_worker_reset(() -> (fired[] += 1; nothing))
    RE.notify_worker_reset(RE.InProcessKernel(), RE.Report("reset_test", ""))
    @test fired[] >= 1
end

@testset "hidden controls" begin

    @testset "hidden() marks the widget, nothing else changes" begin
        m = fresh_ns()
        Core.eval(m, :(@bind shown Slider(0.0:0.1:1.0)))
        Core.eval(m, :(@bind gone  hidden(Slider(0.0:0.1:1.0))))
        reg = nsget(m, "__slate_bind_registry")
        @test !haskey(reg[:shown][1].params, "display")
        @test reg[:gone][1].params["display"] == "none"
    end

    @testset "a hidden control is still a real control" begin
        m = fresh_ns()
        Core.eval(m, :(@bind gone hidden(Slider(0.0:0.1:1.0; default = 0.2))))
        @test Core.eval(m, :gone) == 0.2
        o = Core.eval(m, :(bind_observable(:gone)))
        nsget(m, "__slate_set_bind")(:gone, 0.9)
        # Hiding is presentation only: it coerces, it drives an Observable, and it remains a
        # parameter for a static export. Only the notebook's own widget is suppressed.
        @test o[] == 0.9
        @test Core.eval(m, :gone) == 0.9
    end

    @testset "hidden() preserves the widget's own params" begin
        m = fresh_ns()
        Core.eval(m, :(@bind gone hidden(Slider(0.0:0.1:2.0; label = "L"))))
        p = nsget(m, "__slate_bind_registry")[:gone][1].params
        @test p["label"] == "L" && p["max"] == 2.0 && p["display"] == "none"
    end

    @testset "is_hidden_bind reads the flag" begin
        @test RE.is_hidden_bind(Dict{String,Any}("display" => "none"))
        @test !RE.is_hidden_bind(Dict{String,Any}())
        @test !RE.is_hidden_bind(Dict{String,Any}("display" => "inline"))
    end
end
