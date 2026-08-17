# Reactive state vs. the durable memo cache — the live path, not the state machine.
#
# `_memo_key` digests a cell's source, its upstream cells' sources, the `@bind` values it reads,
# and its `@asset` file contents. `Reactive` values are none of those: a `reactive(:x, v)` is an
# ordinary global, not a `BindSpec`. So a cell that reads only reactives computes the SAME key on
# every run, and the second run onward is served from the cache — the cell stops being evaluated
# while the values it reports keep moving.
#
# That is not theoretical: it froze a progress bar in an exported app, where the status cell's
# first run happened to cross `_MEMO_THRESHOLD_MS` on cold JIT and get auto-cached. The `cache`
# tag below makes the same condition deterministic instead of timing-dependent.
#
# Deliberately driven through a REAL hub — start_hub / open_notebook! / set_bind! — and asserted on
# the cell's OUTPUT. A unit test over `Cell` state transitions cannot see this: every transition is
# correct. The cell restales, runs, and reports; it's the VALUE that's stale.
using ReTest
using KaimonSlate
using Serialization
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine
_noop_refresh(_) = nothing

# The property `hash` does NOT have, and the reason this uses `slate_fingerprint` instead. For any
# value holding heap references `hash` answers object identity, so two structurally identical values
# digest differently — and an address freed and reused can make two DIFFERENT values digest the same,
# which is a stale restore rather than a harmless recompute. Caught in the field: a chart restoring a
# previous fit's result.
@testset "a write digest identifies the value, not the object" begin
    v = [1.0, 2.0, 3.0]
    @test RE._write_digest(v) == RE._write_digest(deepcopy(v))   # same value ⇒ same key ⇒ correct restore
    @test RE._write_digest(v) != RE._write_digest([1.0, 2.0, 4.0])
    @test RE._state_digest(v) == RE._write_digest(v)             # hub and worker must speak one language
end

# The invariant, tested where the fix lives: a memo key must be a total function of everything the
# cell reads. This one is pure and hub-side — no worker, no gate, no timing — so unlike the live
# testset below it runs everywhere, which matters because the live path can only be exercised where
# a gate exists.
# A cell that DECLARES reactive state must never be memoizable — the same exemption `@replay` has.
# `reactive(...)` creates live state by RUNNING; a restore skips the body, so the objects arrive by
# deserialization carrying a previous session's values and bound to a namespace that no longer
# exists. Found in the field: a declarations cell crossed the 150ms auto-cache threshold, restored a
# 25KB fit result from another session, and the notebook's buttons stopped doing anything.
@testset "a cell declaring reactive state is never cached" begin
    decl  = RE.Cell("d", RE.CODE, "busy = reactive(:busy, false)\nnothing")
    sugar = RE.Cell("s", RE.CODE, "@reactive msg = \"idle\"\nnothing")
    plain = RE.Cell("p", RE.CODE, "x = 1 + 1")
    @test !RE._memoizable(decl)
    @test !RE._memoizable(sugar)
    @test RE._memoizable(plain)          # guard: the exemption must not swallow ordinary cells
    # …and unkeyable in a real report ⇒ never stored, so never restored.
    r = RE.parse_report("#%% code id=d\nbusy = reactive(:busy, false)\nnothing\n")
    RE.build_dependencies!(r)
    @test isempty(RE._memo_key(r, r.cells[1]))
end

@testset "a reactive write moves the memo key" begin
    src = "#%% code id=decl\nbusy = reactive(:busy, false)\nnothing\n" *
          "#%% code id=reads\nstring(busy[])\n" *
          "#%% code id=ignores\n1 + 1\n"
    r = RE.parse_report(src)
    RE.build_dependencies!(r)
    cell(id) = r.cells[findfirst(c -> c.id == id, r.cells)]
    RE.forget_state_writes!(r.id)

    reads_before  = RE._memo_key(r, cell("reads"))
    others_before = RE._memo_key(r, cell("ignores"))
    @test !isempty(reads_before)          # guard: a key of "" would make every assertion below vacuous

    RE.note_state_write!(r.id, "busy", "deadbeef")
    @test RE._memo_key(r, cell("reads")) != reads_before

    # …and a second write to the same value-identity is the same key, so an unchanged reactive
    # doesn't churn the cache on every push.
    after = RE._memo_key(r, cell("reads"))
    RE.note_state_write!(r.id, "busy", "deadbeef")
    @test RE._memo_key(r, cell("reads")) == after

    # A cell that reads no reactive must key EXACTLY as before — otherwise this change would
    # invalidate every existing entry in every notebook, and every exported bundle with it.
    @test RE._memo_key(r, cell("ignores")) == others_before

    RE.forget_state_writes!(r.id)
    @test RE._memo_key(r, cell("reads")) == reads_before   # reopen ⇒ back to the pristine key
end

# The other half of the same registry. `@bind` and `reactive` are one thing to the key — state a
# cell reads, identified by its current value — differing only in where that value lives (the hub
# holds a control's; only the worker holds a reactive's). This asserts the control half travels the
# same path, so the two can't drift apart again the way they did before.
@testset "a control change moves the key through the same registry" begin
    r = RE.parse_report("#%% code id=ctl\n@bind k Slider(0:10)\n" *
                        "#%% code id=uses\nk * 2\n")
    RE.build_dependencies!(r)
    RE.eval_stale!(r)                       # binds are REPORTED by evaluation, not by parsing
    cell(id) = r.cells[findfirst(c -> c.id == id, r.cells)]
    @test !isempty(cell("ctl").binds)       # guard: no binds ⇒ the assertion below proves nothing

    before = RE._memo_key(r, cell("uses"))
    cell("ctl").binds[1].value = 7          # what `set_bind!` mirrors on a browser change
    @test RE._memo_key(r, cell("uses")) != before
end

# Why the notifier had to come out of the value. A `Reactive` that carries its own closure cannot
# leave the process it was built in — the closure either refuses to serialize or arrives still bound
# to the ORIGIN's gate stream, so a write on the far side wakes the wrong notebook. That, and not
# anything in the transport, is what kept a reactive from being readable on a region worker while a
# `@bind` value crossed freely: `transfer_binding!` is name-addressed and carries any serializable
# global.
@testset "a reactive can cross to another kernel" begin
    origin = RE.register_refresh_ns!("origin-ns", _ -> nothing)
    r = RE.Reactive(:x, 42, origin)

    io = IOBuffer()
    serialize(io, r)                        # what the cross-kernel value transport does
    seekstart(io)
    replica = deserialize(io)
    @test replica[] == 42

    # …and single-writer discipline: the replica names a namespace that does not exist here, so
    # writing it would change this copy alone while the declaring kernel kept the old value. Refused,
    # and refused BEFORE the store — a rejected write must not leave the copy diverged by exactly the
    # write that was rejected.
    RE.register_refresh_ns!("receiving-ns", _noop_refresh)
    far = RE.Reactive(:x, 0, "a-namespace-from-another-process")
    @test_throws ErrorException far[] = 7
    @test far[] == 0

    # A reactive minted by THIS process whose namespace is gone — restored from the memo store, or
    # left behind by a namespace rebuild — is the same KERNEL, so its write is legitimate and must
    # re-bind to the live namespace. Refusing these silently killed every handler in a notebook whose
    # declarations cell restored from cache: buttons that did nothing at all.
    rebuilt = String(split(RE.register_refresh_ns!("gone-ns", _noop_refresh), "|")[1]) *
              "|NB-a-namespace-that-no-longer-exists"
    survivor = RE.Reactive(:z, 0, rebuilt)
    survivor[] = 3
    @test survivor[] == 3

    # A reactive whose own namespace IS registered writes normally — the rule is about which kernel,
    # not about replicas being second-class.
    seen = String[]
    home = RE.register_refresh_ns!("home-ns", s -> push!(seen, String(s)))
    mine = RE.Reactive(:y, 0, home)
    mine[] = 7
    @test mine[] == 7
    @test length(seen) == 1 && startswith(only(seen), "y:")   # name:digest
end

@testset "reactive state and the memo key" begin
    # The durable memo layer lives in `worker.jl`, and `_select_kernel` only reaches for a
    # GateKernel when `gate_available()`. Without a gate this notebook runs in-process, where there
    # is no store to hit and no restore to catch — the assertions below would pass while exercising
    # nothing. Skip loudly instead of going green on an untested path.
    if !KaimonSlate.ReportEngine.gate_available()
        @info "reactive/memo: no gate available — skipping (in-process kernel has no memo layer)"
        return
    end
    NS.SlateHistory._ROOT[] = mktempdir()
    # Never write to the developer's real memo store — the notebook below deliberately caches.
    ENV["KAIMONSLATE_CACHE_HOME"] = mktempdir()
    hub = NS.start_hub(; port = 8871)
    try
        nbp = tempname() * ".jl"
        write(nbp, """
              #%% code id=decl
              busy = reactive(:busy, false)
              msg  = reactive(:msg, "idle")
              nothing
              #%% code id=ctl
              @bind go Button("Run")
              #%% code id=handler
              @onclick go begin
                  busy[] = true
                  msg[] = "working"
                  try
                      sleep(0.2)
                      msg[] = "done"
                  finally
                      busy[] = false
                  end
              end
              nothing
              #%% code id=status cache
              string(busy[], "|", msg[])
              """)
        nb = hub.notebooks[NS.open_notebook!(hub, nbp)]

        @testset "a cell reading reactives re-runs against the CURRENT values" begin
            # `open_notebook!` kicks the runner asynchronously — wait for the first drain before
            # asserting anything, or the baseline reads "(not run)".
            initial = ""
            for _ in 1:400
                initial = NS._result_of(nb, "status")
                occursin("false|idle", initial) && break
                sleep(0.05)
            end
            @test occursin("false|idle", initial)

            # PRECONDITION, asserted rather than assumed: this test is only meaningful if the cell
            # actually entered the durable cache. If memoization is off (no store, unwritable cache
            # home, key refused) the cell recomputes every time and the assertions below pass
            # without exercising anything — a green that means nothing.
            tr = try; KaimonSlate.ReportEngine.memo_trace(nb.kernel, "status"); catch; nothing; end
            @test tr !== nothing && occursin("stored", string(tr))

            NS.set_bind!(nb, "ctl", "go", nothing)          # click — Button carries no value

            # The handler writes a BURST: busy=true, msg="working", sleep, msg="done", and
            # busy=false from its `finally`. Each write restales the status cell, so by the time
            # the handler returns the cell must report the settled state.
            settled = ""
            for _ in 1:400
                settled = NS._result_of(nb, "status")
                occursin("false|done", settled) && break
                sleep(0.05)
            end
            @test occursin("false|done", settled)
        end

        @testset "the LAST write of a burst is the one that must land" begin
            # `busy` is cleared in the handler's `finally`, so it is written last and is the write
            # most likely to be lost — to a stale key, a dropped push, or a run that finished
            # against the previous value. It is also the one a reader sees as a spinner that never
            # stops, which is why it gets its own assertion rather than riding on the string above.
            @test !occursin("true|", NS._result_of(nb, "status"))
        end
    finally
        NS.stop_hub(hub)
    end
end
