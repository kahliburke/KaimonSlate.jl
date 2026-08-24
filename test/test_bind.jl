# Reactive @bind widget tests.
#   julia --startup-file=no --project=/tmp/report-devenv test/report/test_bind.jl
#
# `@bind` is real Julia: widgets are constructors, `@bind name W(…)` runs as code
# (so dynamic args work), and the control is reported back through eval — not parsed.
using ReTest
import Base64                            # decode a swept table's packed row order

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine
const RE = ReportEngine
findcell(r, id) = r.cells[findfirst(c -> c.id == id, r.cells)]
# A `Reactive` names the namespace it notifies rather than carrying the notifier, so that it can
# cross a process boundary (see `_REFRESH_REGISTRY`). These tests only exercise the cancellation
# semantics of a write, so they register a no-op notifier and hand out its id.
_noop_refresh(_) = nothing
const _TESTNS = RE.register_refresh_ns!("test-bind", _noop_refresh)

@testset "ReportEngine bind" begin

    @testset "widget constructors build specs" begin
        s = RE.Slider(0:10)
        @test s.kind == "slider" && s.params["min"] == 0 && s.params["max"] == 10 && s.default == 0
        @test RE.Checkbox(true).default === true
        sel = RE.Select(["a", "b"])
        # Options normalize to `[{value,label}]` specs (the labeled-options form), not bare values.
        @test sel.kind == "select" && sel.default == "a" &&
              [o["value"] for o in sel.params["options"]] == ["a", "b"]
        @test RE.Toggle(true).kind == "toggle"
        @test RE.TextArea("hi").kind == "textarea"
        @test RE.ColorPicker("#ff8800").default == "#ff8800"
        @test RE.Radio(["a", "b"], "b").default == "b"
        ms = RE.MultiSelect(["x", "y", "z"], ["x", "z"])
        @test ms.kind == "multiselect" && ms.default == ["x", "z"]
        @test RE.MultiSelect(["x", "y"]).default == Any[]
        @test RE.Button("Go").params["label"] == "Go" && RE.Button("Go").default == 0
        nf = RE.NumberField(0, 10, 3)
        @test nf.kind == "number" && nf.default == 3 && nf.params["min"] == 0 && nf.params["max"] == 10
        # kwargs (the natural Pluto-ish syntax) are real now, not a parser special case
        sk = RE.Slider(0.0:0.01:1.0; default = 0.5, label = "frac")
        @test sk.default == 0.5 && sk.params["label"] == "frac"
    end

    @testset "coerce_bind: browser JSON → widget type" begin
        @test RE.coerce_bind(RE.Slider(0:100), 7.0) === 7        # integer slider stays Int
        @test RE.coerce_bind(RE.Slider(0:0.1:1), 0.5) === 0.5    # float slider stays Float
        @test RE.coerce_bind(RE.Checkbox(false), true) === true
        @test RE.coerce_bind(RE.Toggle(false), 1) === true
        @test RE.coerce_bind(RE.Button("x"), 4.0) === 4
        @test RE.coerce_bind(RE.MultiSelect(["x", "y"]), ["x", "y"]) == ["x", "y"]
        @test RE.coerce_bind(RE.ColorPicker(), "#123456") == "#123456"
    end

    # An `<option>` can only carry TEXT, so a numeric option comes back as the BROWSER's string
    # form — and the two ends stringify numbers differently (Julia writes `1.0e7`, JavaScript
    # writes `10000000`). Matching on `string(...)` alone therefore failed for every numeric
    # Select: the bind kept the raw String, arithmetic on it threw a TypeError naming a type the
    # author never chose, and a labeled option lost its label as well. It looked fine until the
    # reader first CHANGED the control, because a default never makes the round trip.
    @testset "numeric Select options survive the browser's string round-trip" begin
        w = RE.Select([1e4 => "soft", 1e5 => "medium", 1e7 => "very stiff"], 1e5)
        rt(s) = RE.wrap_value(w, RE.coerce_bind(w, s))
        @test rt("10000000").value == 1e7          # what JS actually sends for 1.0e7
        @test rt("10000000").value isa Float64     # …not a String
        @test rt("10000000").label == "very stiff" # the label survives too
        @test rt("10000").value == 1e4
        @test rt("1.0e7").value == 1e7             # Julia's own form still matches
        @test rt(1e7).value == 1e7                 # and a real number
        # String options are untouched by the numeric path.
        ws = RE.Select(["a" => "Apple", "b" => "Banana"])
        @test RE.wrap_value(ws, RE.coerce_bind(ws, "b")).label == "Banana"
        # An unknown value passes through rather than being silently snapped to an option.
        @test RE.coerce_bind(w, "nope") == "nope"
        # Multi-select shares the matcher.
        @test RE.coerce_bind(RE.MultiSelect([1e4 => "soft", 1e7 => "stiff"]), ["10000000"]) == Any[1e7]
    end

    # A RangeSlider's thumb can only sit on a step, but another input device can hand over
    # anything — an `echart(…; select = …)` brush posts raw axis coordinates. Snapping in the
    # coercion (the one place a value enters the bind) keeps every writer honest, instead of the
    # slider and the chart disagreeing by up to a step and meaningless precision leaking into every
    # axis label downstream.
    @testset "RangeSlider: coercion sorts, clamps and snaps to the step" begin
        w = RE.RangeSlider(400:5:4000; default = (1500, 1800))
        c(v) = RE.coerce_bind(w, v)
        @test c([733.206106870229, 1334.351145038168]) == Any[735.0, 1335.0]   # snapped
        @test c([1900, 1200]) == Any[1200.0, 1900.0]     # crossed thumbs → sorted
        @test c([-50, 99999]) == Any[400.0, 4000.0]      # out of range → clamped
        @test c("nonsense") == w.default                 # garbage → the default
        # A fractional step keeps its precision rather than being rounded to integers.
        wf = RE.RangeSlider(0, 1; step = 0.05, default = (0.2, 0.8))
        @test RE.coerce_bind(wf, [0.31, 0.77]) == Any[0.30, 0.75]
        # The user-facing value destructures and reads by name.
        s = RE.wrap_value(w, c([1500, 1800]))
        @test s.lo == 1500 && s.hi == 1800
        @test (first(s), last(s)) == (1500.0, 1800.0)
    end

    # `set_bind(:name, v)` from cell code names only the VARIABLE — a notebook shouldn't have to
    # know which of its own cells happens to declare a control in order to move it. `bind_owner` is
    # how that name is resolved to the cell id the setter needs.
    @testset "bind_owner: resolve a control's declaring cell by name" begin
        r = RE.parse_report("""
        #%% code id=ctl
        @bind pick Select(["a", "b", "c"], "a")
        @bind n Slider(0:10)

        #%% code id=other
        @bind flag Checkbox(false)

        #%% code id=reader
        chosen = pick
        """)
        RE.eval_report!(r)
        @test RE.bind_owner(r, "pick") == "ctl"
        @test RE.bind_owner(r, "n") == "ctl"        # a group cell owns every var it declares
        @test RE.bind_owner(r, "flag") == "other"
        # Unknown → "", which the caller turns into a silent no-op: a stale name left in a handler
        # must not break a run.
        @test RE.bind_owner(r, "nosuchbind") == ""
        @test RE.bind_owner(r, "chosen") == ""      # an ordinary global is not a control
    end

    @testset "custom_widget: third-party kind passes through the value contract" begin
        w = RE.custom_widget("mathfield"; label = "answer")
        @test w.kind == "mathfield" && w.default == "" && w.params["label"] == "answer"
        @test RE.custom_widget("mathfield", "\\frac{1}{2}").default == "\\frac{1}{2}"   # positional default carries
        # coerce is TYPE-DRIVEN from the default even for an unregistered kind: a String-valued field
        # coerces a stray browser value to String (see SlateExtensionsBase `coerce_value`).
        @test RE.coerce_bind(w, "x^2 + 1") == "x^2 + 1"
        @test RE.coerce_bind(w, 42) === "42"                                            # coerced to the default's String type
        # reconcile keeps the user's value across a re-run (same custom kind), resets on a kind change
        @test RE.reconcile_bind(w, "kept", RE.custom_widget("mathfield")) == "kept"
        @test RE.reconcile_bind(w, "kept", RE.Slider(0:10)) == 0                        # kind changed → default
    end

    @testset "TableSelect binds the clicked row as a NamedTuple" begin
        ts = RE.TableSelect([(sym = "AAPL", px = 42.0), (sym = "MSFT", px = 13.5)])
        @test ts.kind == "tableselect"
        @test [c["name"] for c in ts.params["columns"]] == ["sym", "px"]   # object-form columns
        @test ts.default == 0                                   # nothing selected initially
        # No selection → nothing; a valid 1-based index → the row as a NamedTuple (field per column)
        @test RE.wrap_value(ts, 0) === nothing
        row = RE.wrap_value(ts, 1)
        @test row === (sym = "AAPL", px = 42.0)
        @test row.px == 42.0 && row.sym == "AAPL"               # struct-like field access
        # coerce clamps the browser's row index to the known rows (out of range → 0 = none)
        @test RE.coerce_bind(ts, 2.0) === 2
        @test RE.coerce_bind(ts, 99) === 0 && RE.coerce_bind(ts, 0) === 0
        # reconcile keeps the selected index across a re-run while it stays in range
        @test RE.reconcile_bind(ts, 2, ts) == 2
        ts1 = RE.TableSelect([(sym = "AAPL", px = 42.0)])       # a re-run that now has only 1 row
        @test RE.reconcile_bind(ts, 2, ts1) == 0               # index 2 no longer valid → default
    end

    @testset "reconcile: keep value unless type-changed or out of domain" begin
        @test RE.reconcile_bind(RE.Slider(0:10), 5, RE.Slider(0:10)) == 5        # in range → keep
        @test RE.reconcile_bind(RE.Slider(0:10), 8, RE.Slider(0:5)) == 0         # out of range → default
        @test RE.reconcile_bind(RE.Slider(0:10), 5, RE.Toggle(false)) === false  # type change → default
        @test RE.reconcile_bind(RE.Select(["a", "b"]), "b", RE.Select(["a", "b", "c"])) == "b"
        @test RE.reconcile_bind(RE.Select(["a", "b"]), "b", RE.Select(["a", "c"])) == "a"  # gone → default
        # multiselect drops now-invalid options
        @test RE.reconcile_bind(RE.MultiSelect(["x", "y", "z"]), ["x", "z"],
                                 RE.MultiSelect(["x", "y"])) == ["x"]
        # `_do_bind` handles the "?" placeholder (browser set a value before this bind cell's first
        # run this session): it isn't a real type change, so the pending value survives, coerced
        # against the real widget, instead of being discarded to the default.
        lk = ReentrantLock()
        regp = Dict{Symbol,Tuple{RE.Widget,Any}}(:k => (RE.Widget("?", Dict{String,Any}(), 7), 7))
        @test RE._do_bind(regp, lk, :k, RE.Slider(0:10)) == 7
        regp2 = Dict{Symbol,Tuple{RE.Widget,Any}}(:k => (RE.Widget("?", Dict{String,Any}(), 7.0), 7.0))
        @test RE._do_bind(regp2, lk, :k, RE.Slider(0:10)) == 7   # coerced like a normal Int slider set
    end

    @testset "bind cell: control reported by eval; dependents react" begin
        r = parse_report("#%% code id=ctl\n@bind n Slider(1:10)\n#%% code id=use\nm = n * 2")
        build_dependencies!(r)
        @test :n in findcell(r, "ctl").writes              # graph sees the write (static)
        @test "ctl" in findcell(r, "use").deps             # dependent reads the bound var
        @test isempty(findcell(r, "ctl").binds)            # not populated until eval
        eval_stale!(r)
        @test !isempty(findcell(r, "ctl").binds)           # control reported by eval
        @test findcell(r, "ctl").binds[1].widget == "slider"
        @test Base.invokelatest(getproperty, r.mod, :n) == 1 && Base.invokelatest(getproperty, r.mod, :m) == 2

        set_bind_value!(r, findcell(r, "ctl"), 5)          # "move the slider"
        findcell(r, "use").state = STALE                   # (server marks dependents)
        eval_stale!(r)
        @test Base.invokelatest(getproperty, r.mod, :n) == 5 && Base.invokelatest(getproperty, r.mod, :m) == 10
        @test findcell(r, "ctl").binds[1].value == 5       # host-side spec mirrors it
    end

    @testset "mixed cell: @bind and code in one cell both work" begin
        r = parse_report("#%% code id=mix\n@bind w Slider(2:10)\nq = w + 1")
        build_dependencies!(r)
        @test :w in findcell(r, "mix").writes && :q in findcell(r, "mix").writes
        eval_stale!(r)
        @test findcell(r, "mix").state == FRESH
        @test Base.invokelatest(getproperty, r.mod, :w) == 2 && Base.invokelatest(getproperty, r.mod, :q) == 3
        @test !isempty(findcell(r, "mix").binds)           # control reported even though mixed
    end

    @testset "Choice is transparent in convert/index/construct contexts" begin
        # A labeled Select binds a `Choice`; it must behave like its value wherever a `convert` flows.
        c = RE.Choice(8, "8 heads", 4)
        @test convert(Int, c) === 8                        # typed field / local / collection element
        @test Int(c) === 8                                 # explicit numeric construction
        @test (let x::Int = c; x end) === 8                # typed local assignment
        @test Int[c, c] == [8, 8]                          # typed collection element
        @test [10, 20, 30, 40, 50, 60, 70, 80][c] == 80    # indexing (to_index)
        @test c == 8 && c.value === 8 && c.label == "8 heads"
        # The scalar-only `convert` restriction keeps Choice→Choice conversion intact (Selection needs it).
        @test eltype(RE.Choice[c, c]) === RE.Choice
    end

    @testset "a mixed @bind cell is memoizable, keyed on the control value" begin
        r = parse_report("#%% code id=up\nd = 3\n#%% code id=mix\n@bind k Slider(1:5)\ny = d * k")
        build_dependencies!(r); eval_stale!(r)
        mix = findcell(r, "mix")
        @test !isempty(mix.binds)
        @test RE._memoizable(mix)                          # bind cells now cacheable (scaffold-replay on restore)
        # the control's current value is folded into the key, so changing it invalidates the entry
        k1 = RE._memo_key(r, mix)
        set_bind_value!(r, mix, :k, 5)
        k2 = RE._memo_key(r, mix)
        @test !isempty(k1) && k1 != k2
    end

    @testset "dynamic range: widget args are reads; range re-evaluates" begin
        r = parse_report("#%% code id=hi\nhi = 5\n#%% code id=ctl\n@bind k Slider(1:hi)")
        build_dependencies!(r)
        @test :hi in findcell(r, "ctl").reads              # widget arg is a read
        @test "hi" in findcell(r, "ctl").deps              # bind cell depends on hi's writer
        eval_stale!(r)
        @test findcell(r, "ctl").binds[1].params["max"] == 5
        set_bind_value!(r, findcell(r, "ctl"), 4)
        @test Base.invokelatest(getproperty, r.mod, :k) == 4
        # hi grows → bind cell re-runs, range expands; in-range value is preserved
        Core.eval(r.mod, :(hi = 8))
        findcell(r, "ctl").state = STALE
        eval_stale!(r)
        @test findcell(r, "ctl").binds[1].params["max"] == 8   # range updated live
        @test Base.invokelatest(getproperty, r.mod, :k) == 4                       # value preserved (still in range)
    end

    @testset "value persists across a bind-cell re-run (registry reconcile)" begin
        r = parse_report("#%% code id=ctl\n@bind n Slider(1:10)")
        build_dependencies!(r); eval_stale!(r)
        set_bind_value!(r, findcell(r, "ctl"), 7)
        @test Base.invokelatest(getproperty, r.mod, :n) == 7
        findcell(r, "ctl").state = STALE                   # re-run the bind cell
        eval_stale!(r)
        @test Base.invokelatest(getproperty, r.mod, :n) == 7                  # not reset to default
        @test findcell(r, "ctl").binds[1].value == 7
    end

    @testset "group cell: multiple @bind; per-name value set" begin
        r = parse_report("#%% code id=ctl\n@bind a Slider(1:10)\n@bind b Slider(0:0.5:5)\n" *
                         "#%% code id=use\nm = a + b")
        build_dependencies!(r)
        ctl = findcell(r, "ctl")
        @test :a in ctl.writes && :b in ctl.writes
        @test "ctl" in findcell(r, "use").deps
        eval_stale!(r)
        @test length(ctl.binds) == 2
        @test Base.invokelatest(getproperty, r.mod, :a) == 1 && Base.invokelatest(getproperty, r.mod, :b) == 0 && Base.invokelatest(getproperty, r.mod, :m) == 1

        set_bind_value!(r, ctl, :b, 2.5)                   # set one of the two
        findcell(r, "use").state = STALE
        eval_stale!(r)
        @test Base.invokelatest(getproperty, r.mod, :b) == 2.5 && Base.invokelatest(getproperty, r.mod, :m) == 3.5
        @test ctl.binds[findfirst(s -> s.name == :a, ctl.binds)].value == 1   # other unchanged
    end

    @testset "@onclick: a superseded handler is cancelled at its next Reactive write (no pause needed)" begin
        tokens = Dict{Symbol,Any}()
        log = Int[]
        r = RE.Reactive(:level, 0, _TESTNS)
        done1, done2 = Ref(false), Ref(false)
        handler1 = _ -> begin       # NO `pause()` calls — relies on the write itself being a checkpoint
            for i in 1:5
                r[] = i             # should throw _Cancelled here, before ever appending to log
                push!(log, i)
            end
            done1[] = true
        end
        handler2 = _ -> begin
            r[] = 99
            push!(log, 99)
            done2[] = true
        end
        RE.__on_fire!(tokens, :fill, handler1, nothing)
        RE.__on_fire!(tokens, :fill, handler2, nothing)   # supersedes handler1 before it has run any code
        for _ in 1:200   # both tasks are spawned async — wait for handler2 to finish
            done2[] && break
            sleep(0.01)
        end
        @test done2[]
        @test !done1[]            # handler1 never completed — cancelled at (or before) its first write
        @test 1 ∉ log             # handler1's loop body never executed, not even its first iteration
        @test r[] == 99           # handler2's write landed cleanly; handler1 never raced it
    end

    @testset "@onclick: a cancelled handler still runs its cleanup" begin
        # The reason the checkpoint fires only ONCE per task. A handler that raises a busy flag and
        # clears it in `finally` is the documented shape for "show progress while this runs" — and if
        # the cancellation kept throwing, the `finally` write would throw too and the flag would stay
        # raised forever. The visible failure is a progress bar that never stops, on a notebook whose
        # code is correct: nothing in the handler is reachable to fix it.
        tokens = Dict{Symbol,Any}()
        busy = RE.Reactive(:busy, false, _TESTNS)
        msg  = RE.Reactive(:msg, "", _TESTNS)
        r    = RE.Reactive(:level, 0, _TESTNS)
        ran_finally, ran_catch, working = Ref(false), Ref(false), Ref(false)
        handler1 = _ -> begin
            try
                busy[] = true
                working[] = true             # plain Ref: signals "inside the try" without a checkpoint
                for i in 1:500
                    sleep(0.01)
                    r[] = i                  # cancelled at one of these
                end
            catch
                ran_catch[] = true
                msg[] = "interrupted"        # a Reactive write on the CATCH path
                rethrow()
            finally
                ran_finally[] = true
                busy[] = false               # …and on the FINALLY path — the one that must land
            end
        end
        done2 = Ref(false)
        RE.__on_fire!(tokens, :fit, handler1, nothing)
        # Let it get INTO the try before superseding it — cancelling a handler that hasn't started
        # yet is the other test above, and has no cleanup to run.
        for _ in 1:300; working[] && break; sleep(0.01); end
        @test working[]
        RE.__on_fire!(tokens, :fit, _ -> (done2[] = true), nothing)   # supersedes handler1
        for _ in 1:300
            (done2[] && ran_finally[]) && break
            sleep(0.01)
        end
        @test ran_catch[] && ran_finally[]   # both unwinding paths were reached…
        @test busy[] == false                # …and their writes actually took effect
        @test msg[] == "interrupted"
        @test r[] < 500                      # the WORK was still aborted, not run to completion
    end

    @testset "valueless set on a button is a click: server increments the count" begin
        # The core new behaviour, at the registry layer: a button's value IS its click count, so a
        # set with `nothing` increments it server-side — the caller never needs (or races) the count.
        reg = Dict{Symbol,Tuple{RE.Widget,Any}}(:go => (RE.Button("Run"), 0))
        lk = ReentrantLock()
        @test RE._do_set_bind(reg, lk, :go, nothing) == 1       # click: 0 → 1
        @test RE._do_set_bind(reg, lk, :go, nothing) == 2       # click: 1 → 2
        @test reg[:go][2] == 2
        @test RE._do_set_bind(reg, lk, :go, 10) == 10           # an explicit value (browser path) still sets exactly
        # the increment is button-only: a valueless slider set just coerces (no magic count bump)
        reg2 = Dict{Symbol,Tuple{RE.Widget,Any}}(:s => (RE.Slider(0:10), 3))
        @test RE._do_set_bind(reg2, lk, :s, 6) == 6
    end

    @testset "@bind Button: a valueless click increments the global AND fires @onclick" begin
        r = parse_report("#%% code id=ctl\n@bind go Button(\"Run\")\n@onclick go (fires[] += 1)\n" *
                         "#%% code id=use\nseen = go")
        build_dependencies!(r); eval_stale!(r)
        # inject the counter the handler bumps AFTER eval (the module exists now); the @onclick
        # closure only resolves `fires` when it fires, so registering it earlier is fine.
        Core.eval(r.mod, :(const fires = $(Ref(0))))
        @test findcell(r, "ctl").binds[1].widget == "button"
        @test Base.invokelatest(getproperty, r.mod, :go) == 0

        set_bind_value!(r, findcell(r, "ctl"), :go, nothing)    # click — no value passed
        findcell(r, "use").state = STALE; eval_stale!(r)
        @test Base.invokelatest(getproperty, r.mod, :go) == 1   # count advanced server-side
        @test Base.invokelatest(getproperty, r.mod, :seen) == 1 # a reader reacted

        set_bind_value!(r, findcell(r, "ctl"), :go, nothing)    # click again
        @test Base.invokelatest(getproperty, r.mod, :go) == 2
        @test findcell(r, "ctl").binds[1].value == 2            # host-side spec mirrors it

        # @onclick dispatch is async (__on_fire! spawns a task) — wait for both fires to land
        fires = Base.invokelatest(getproperty, r.mod, :fires)
        for _ in 1:200; fires[] == 2 && break; sleep(0.01); end
        @test fires[] == 2                                       # the handler fired on each click
    end

    # ── `@replay` domains ────────────────────────────────────────────────────
    # `bind_domain` is the single gate on whether a control survives a static export: `@replay` asks
    # for every value the control can take and refuses anything that answers `nothing`. These are the
    # WIRE values (what the registry stores and the browser sends back), not the wrapped form a cell
    # sees — that distinction is what keeps a TableSelect's domain a run of integers instead of a
    # shipped copy of its own table.
    @testset "bind_domain: every control with an enumerable domain" begin
        @test RE.bind_domain(RE.Slider(1:2:15)) == [1, 3, 5, 7, 9, 11, 13, 15]   # endpoint kept
        @test RE.bind_domain(RE.Checkbox()) == [false, true]
        @test RE.bind_domain(RE.Select(["a", "b"])) == ["a", "b"]

        # A range slider's two thumbs are ONE value, so the domain is ordered pairs — lo ≤ hi, since a
        # crossed pair is not a state the control can be put into. n stops → n(n+1)/2, not n².
        rs = RE.bind_domain(RE.RangeSlider(0:1:3))
        @test length(rs) == 10
        @test rs[1] == [0, 0] && rs[end] == [3, 3]
        @test all(p -> p[1] <= p[2], rs)
        @test allunique(rs)

        # A table select enumerates ROW INDICES (0 = nothing selected), which is why it is cheaper to
        # replay than a categorical control, not more expensive.
        ts = RE.TableSelect([(a = 1, b = "x"), (a = 2, b = "y"), (a = 3, b = "z")])
        @test RE.bind_domain(ts) == [0, 1, 2, 3]

        # A multi-select is the POWER SET, enumerated by increasing bitmask so the empty set is first.
        ms = RE.bind_domain(RE.MultiSelect(["a", "b"]))
        @test ms == [[], ["a"], ["b"], ["a", "b"]]

        # A number field is finite exactly when the author bounded it; unbounded is free text with arrows.
        @test RE.bind_domain(RE.NumberField(0; min = 0, max = 4)) == [0, 1, 2, 3, 4]
        @test RE.bind_domain(RE.NumberField(3)) === nothing

        # Genuinely unbounded, and driven-by-something-else, stay refused.
        for w in (RE.TextField("hi"), RE.DateField("2026-01-01"), RE.ColorPicker("#fff"),
                  RE.Button("go"), RE.FileUpload())
            @test RE.bind_domain(w) === nothing
        end
    end

    # The cap exists because these two grow faster than the control looks like it does: a range slider
    # is quadratic in its steps and a multi-select exponential in its options, so an innocuous-looking
    # control can ask for a domain nothing should enumerate. Refusing here means the author gets
    # `@replay`'s error while writing the cell rather than an export that grinds.
    @testset "bind_domain: combinatorial domains are capped, not enumerated forever" begin
        @test RE.bind_domain(RE.RangeSlider(0:1:150)) !== nothing     # 11 476 pairs — under the cap
        @test RE.bind_domain(RE.RangeSlider(0:1:400)) === nothing     # 80 601 — refused
        @test RE.bind_domain(RE.MultiSelect(string.(1:10))) !== nothing   # 1 024 subsets
        @test RE.bind_domain(RE.MultiSelect(string.(1:20))) === nothing   # 1 048 576 — refused
    end

    # A sweep evaluates the author's expression, which is written against the value a CELL sees. For
    # most controls the wire value and the cell value are the same thing; for these they are not, and
    # sweeping the wire value would hand `sel.product` an integer.
    @testset "bind_domain values wrap into what a cell actually sees" begin
        ts = RE.TableSelect([(a = 1, b = "x"), (a = 2, b = "y")])
        @test RE.wrap_value(ts, 0) === nothing                  # 0 is "nothing selected"
        @test RE.wrap_value(ts, 2).b == "y"                     # a row NamedTuple, field per column

        rs = RE.RangeSlider(0:1:3)
        w = RE.wrap_value(rs, [1, 3])
        @test w.lo == 1 && w.hi == 3                            # the (lo, hi) NamedTuple, not a vector
    end

    # `Slate.replay` exists twice — core.js for a page that can load it, and a hand-mirrored copy
    # inside a Julia string in server_export.jl for a static page that cannot. Nothing enforced that
    # they agree, and a fix applied to one and not the other shows up as an exported control quietly
    # selecting the wrong column. This asserts both copies against the same cases and each other.
    @testset "replay matching parity: core.js vs the export mirror (node, if available)" begin
        node = Sys.which("node")
        if node === nothing
            @info "node not found — skipping Slate.replay parity check"
            @test true
        else
            io = IOBuffer()
            script = joinpath(@__DIR__, "js", "replay_parity.mjs")
            ok = success(pipeline(`$node $script`; stdout = io, stderr = io))
            ok || print(String(take!(io)))     # surface the diverging cases on failure
            @test ok
        end
    end

    # A sweep is keyed by cell + control, which is what makes a re-run replace its own entry instead of
    # accumulating. But a cell may hold SEVERAL marks on ONE control — the ordinary way to replay a
    # stacked chart or a dual-axis figure, where every series is a different expression of the same
    # knob. Those used to collide on the shared key: the second registration overwrote the first, so
    # both series resolved to the same sweep and an exported page drew one expression twice while
    # reporting no error at all.
    @testset "several @replay marks on one control in one cell get distinct sweeps" begin
        r = parse_report("""
        #%% code id=ctl
        @bind k Slider(1:4)
        #%% code id=two
        a = @replay(k, [k, k])
        b = @replay(k, [10k, 10k])
        (a, b)
        """)
        build_dependencies!(r)
        eval_stale!(r)

        sweeps = Base.invokelatest(getproperty, r.mod, :__slate_replay_sweeps)
        ids = sort(collect(keys(sweeps)))
        @test ids == ["two:k", "two:k#1"]          # first keeps the bare key, later ones are suffixed

        # …and they are the DIFFERENT expressions, in source order — not one registration twice.
        # `invokelatest`, because the closures were defined by the eval above and are newer than this
        # test's world age — the same reason the reads around here go through it.
        @test Base.invokelatest(sweeps["two:k"].f, 3) == [3, 3]
        @test Base.invokelatest(sweeps["two:k#1"].f, 3) == [30, 30]

        # Re-running replaces those two rather than adding two more, which is the property the shared
        # key was there to give and which the suffix must not cost.
        findcell(r, "two").state = STALE; eval_stale!(r)
        @test sort(collect(keys(Base.invokelatest(getproperty, r.mod, :__slate_replay_sweeps)))) == ids
    end

    # `@replay` sweeps the value a CELL sees, not the wire value the registry holds. For a slider or a
    # select those are the same thing; for a TableSelect the wire value is a row index and the cell
    # value is the row, so sweeping unwrapped would hand `sel.b` an integer and fail on field access.
    @testset "@replay sweeps wrapped values, so a row-valued control works" begin
        r = parse_report("""
        #%% code id=ctl
        @bind sel TableSelect([(a = 1, b = 10.0), (a = 2, b = 20.0)]; default = 1)
        #%% code id=use
        v = @replay(sel, [sel === nothing ? 0.0 : sel.b])
        """)
        build_dependencies!(r)
        eval_stale!(r)

        sweeps = Base.invokelatest(getproperty, r.mod, :__slate_replay_sweeps)
        s = sweeps["use:sel"]
        @test s.domain == [0, 1, 2]                    # WIRE values: row indices, 0 = nothing selected
        # …wrapped into the row (or `nothing`) on the way in, which is what the author's expression
        # is written against. `invokelatest` for the same world-age reason as above.
        @test Base.invokelatest(s.f, Base.invokelatest(s.wrap, 0)) == [0.0]
        @test Base.invokelatest(s.f, Base.invokelatest(s.wrap, 2)) == [20.0]
    end

    # `@replay` now sweeps the WRAPPED value, which for a labeled Select is a `Choice` rather than the
    # bare option. That is a behaviour change, and the reason it is the right one is here: before it,
    # the value a cell saw LIVE and the value the sweep computed with were different types, so an
    # expression could work in the notebook and quietly compute something else in the export.
    @testset "a labeled Select sweeps the same value the cell sees live" begin
        r = parse_report("""
        #%% code id=ctl
        @bind pick Select(["a" => "Apple", "b" => "Banana"])
        #%% code id=use
        v = @replay(pick, [pick == "b" ? 1.0 : 0.0])
        """)
        build_dependencies!(r)
        eval_stale!(r)

        live = Base.invokelatest(getproperty, r.mod, :pick)
        s = Base.invokelatest(getproperty, r.mod, :__slate_replay_sweeps)["use:pick"]
        swept = Base.invokelatest(s.wrap, first(s.domain))
        @test typeof(swept) === typeof(live)          # the same TYPE, not just an equal value
        @test swept == live == "a"                    # …and transparent against the bare option
        @test s.domain == ["a", "b"]                  # the domain itself stays bare — it has to ship

        # The expression therefore computes the same thing at both ends.
        @test Base.invokelatest(s.f, Base.invokelatest(s.wrap, "b")) == [1.0]
        @test Base.invokelatest(s.f, Base.invokelatest(s.wrap, "a")) == [0.0]
    end

    # A TABLE is replayable too, and it is not an array of numbers: the mark rides on the table's own
    # spec (a `ReplayArray` could neither hold a `SlateTable` nor be handed on to the things that
    # consume one), and the sweep packs to the UNION of the rows plus a per-position order over it.
    @testset "@replay on a table marks the table and sweeps to a union + row order" begin
        r = parse_report("""
        #%% code id=ctl
        @bind region Select(["north", "south"])
        #%% code id=tbl
        t = @replay(region, slate_table(["city", "n"],
            region == "north" ? [["oslo", 1], ["bergen", 2]] : [["lima", 3]]))
        """)
        build_dependencies!(r)
        eval_stale!(r)

        # LIVE, the cell's value is the ordinary table for the position the control is on — with the
        # mark added, which is the only thing the export needs and the only thing that changed.
        t = Base.invokelatest(getproperty, r.mod, :t)
        @test length(Base.invokelatest(getproperty, t, :rows)) == 2
        mk = Base.invokelatest(getproperty, t, :opts)["__replay"]
        @test mk["id"] == "tbl:region" && mk["control"] == "region" && mk["index"] == 0

        # `invokelatest` twice: once to read the binding, once to CALL it — the sweep closures were
        # defined by the eval above and are newer than this test's world age.
        got = Base.invokelatest(Base.invokelatest(getproperty, r.mod, :__slate_run_replays))
        s = got["tbl:region"]
        @test s["target"] == "table"                 # the page drives a table, not a chart series
        @test s["rows"] == Any[Any["oslo", 1], Any["bergen", 2], Any["lima", 3]]   # first-seen order
        @test s["dtype"] == "i16" && s["shape"] == [3, 2]
        A = reshape(reinterpret(Int16, Base64.base64decode(s["b64"])), 3, 2)
        @test A[:, 1] == Int16[1, 2, 0]              # north: its two rows, then padding
        @test A[:, 2] == Int16[3, 0, 0]              # south: the one row only its position has

        # An estimate the export dialog can show without sweeping the whole domain: one position's rows
        # at two bytes each. A floor, and labelled a table so the dialog can say what it is.
        p = Base.invokelatest(Base.invokelatest(getproperty, r.mod, :__slate_replay_plan))["tbl:region"]
        @test p["target"] == "table" && p["bytes_per_value"] == 4 && p["slice"] == [2]
    end

    # One mark's failure used to cost the whole export. `_replay_sweep_assets` catches what escapes the
    # sweep and ships the page with EVERY control frozen — so a single expression that dislikes a single
    # position of a single control disabled every figure on the page, with one warning to explain it.
    @testset "a failing sweep costs its own control, not the whole export" begin
        good = (; name = "a", f = (v -> [Float64(v)]), wrap = identity, domain = Any[1, 2],
                  cell = "c1", kind = "slider")
        bad = (; name = "b", f = (v -> error("no")), wrap = identity, domain = Any[1, 2],
                 cell = "c2", kind = "slider")
        got = RE._run_replay_sweeps(Dict{String,Any}("c1:a" => good, "c2:b" => bad))
        @test haskey(got["c1:a"], "b64")                # the working mark still ships
        @test !haskey(got["c2:b"], "b64")               # …the failing one ships nothing
        @test occursin("no", got["c2:b"]["error"])      # …and says why, rather than vanishing
    end

    # `replay_stack` packs whatever a marked expression returns. A boolean array is numeric and stacks
    # fine, but `Bool` is not a dtype the asset writer can pack, so it used to widen to Float64 —
    # eight bytes to carry a yes/no.
    @testset "a boolean slice packs as one byte, not eight" begin
        A = RE.replay_stack([[true, false], [false, true]])
        @test eltype(A) === UInt8
        @test A == UInt8[1 0; 0 1]
    end

end
