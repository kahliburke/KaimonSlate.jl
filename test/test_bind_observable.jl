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
