# Cell debugger: the stepper itself (worker_debug.jl), driven in-process against a scratch
# module. The gate path is the same five verbs behind `_tool`, so what is worth pinning here
# is the stepping semantics and the wire shape every viewer reads.
using ReTest
using KaimonSlate
# A worker reaches the interpreter through Revise, which a test process does not have — so load
# it into Main here, which is where `_ji` looks next.
import JuliaInterpreter
const RE = KaimonSlate.ReportEngine

# A namespace to step in, standing in for a notebook's `Main.NB`.
module Sandbox
    function smooth(v, α)
        out = similar(v)
        acc = v[1]
        for i in eachindex(v)
            acc = α * v[i] + (1 - α) * acc
            out[i] = acc
        end
        return out
    end
    outer(x) = inner(x) + 1
    inner(x) = x * 2
end

step!(mode) = RE.debug_step!(; mode = mode)

# `scope` is the method's fully-qualified name, and runtests.jl nests each file in its own module,
# so the prefix is `Main.Debugger.Sandbox` here rather than `Main.Sandbox`. Name it once.
const SB = string(Sandbox)
scoped(name) = SB * "." * name

# Step until the predicate holds, so a test says what it is waiting for rather than counting
# lowered statements — several of those can sit on one source line.
function until(pred; limit = 80, mode = "next")
    st = RE.debug_frame()
    for _ in 1:limit
        pred(st) && return st
        st.finished && return st
        st = step!(mode)
    end
    return st
end

@testset "cell debugger" begin
    @testset "top-level writes" begin
        W(src) = sort!(String[string(s) for s in RE._toplevel_writes(Meta.parseall(src))])
        @test W("a = 1\nb = 2") == ["a", "b"]
        @test W("x, y = 1, 2") == ["x", "y"]
        @test W("n::Int = 3") == ["n"]
        @test W("const K = 9") == ["K"]
        @test W("f(z) = z") == ["f"]                      # the function, not its argument
        @test W("function g(z)\n  z\nend") == ["g"]
        @test W("struct P\n  a::Int\nend") == ["P"]
        @test W("struct Q <: Integer\n  a::Int\nend") == ["Q"]
        @test W("1 + 1") == String[]                       # an expression writes nothing
    end

    @testset "stepping a cell" begin
        st = RE.debug_start!(Sandbox; cell = "c1", source = "p = 6\nq = 7\nr = p * q\n")
        try
            # Before anything runs: on the first line, nothing finished, and every declared
            # name already listed so a reader watches them arrive rather than appear.
            @test !st.finished
            @test st.line == 1
            @test st.in_cell
            @test st.file == "cell:c1"
            @test [b.name for b in st.bindings] == ["p", "q", "r"]
            @test all(isempty(b.type) for b in st.bindings)   # declared, not yet assigned

            # `p` is bound as soon as its line has run — this is the world-age case: the
            # interpreter creates the global in a newer world than the reader was compiled in.
            st = until(s -> s.line >= 2)
            @test st.line >= 2
            pb = only(b for b in st.bindings if b.name == "p")
            @test pb.type == "Int64"
            @test pb.repr == "6"

            st = until(s -> s.finished || s.line >= 3)
            ev = RE.debug_eval_expr(; expr = "p + q")
            @test ev.ok
            @test ev.value.repr == "13"
            @test RE.debug_eval_expr(; expr = "nope_not_here").ok == false
        finally
            RE.debug_stop!()
        end
        @test RE.debug_frame().error !== nothing           # the session is gone
    end

    @testset "into and out" begin
        RE.debug_start!(Sandbox; cell = "c2", source = "v = outer(5)\n")
        try
            st = step!("into")
            # Descends into the notebook's own code. `in_cell` is false: the frame is a method,
            # which is exactly when a viewer must stop highlighting a line of the cell.
            @test st.scope == scoped("outer")
            @test !st.in_cell
            @test length(st.stack) == 2
            @test st.stack[end].scope == scoped("outer")

            depth = length(st.stack)
            st = until(s -> length(s.stack) > depth; mode = "into")
            @test st.scope == scoped("inner")
            @test only(b.repr for b in st.locals if b.name == "x") == "5"

            # `out` returns to the caller rather than ending the run — `:so` is Debugger.jl's
            # key for this and JuliaInterpreter rejects it, which ended the session instead.
            # Stepping INTO a call is implemented as a synthetic breakpoint, so reading
            # `debug_command`'s return reported one on every `into` — with none set anywhere.
            @test !st.at_breakpoint

            st = step!("out")
            @test !st.finished
            @test st.error === nothing
            @test length(st.stack) < depth + 1
        finally
            RE.debug_stop!()
        end
    end

    @testset "frame source" begin
        RE.debug_start!(Sandbox; cell = "c3", source = "w = smooth([1.0, 2.0, 4.0], 0.5)\n")
        try
            st = until(s -> s.scope == scoped("smooth"); mode = "into")
            @test st.scope == scoped("smooth")
            # The method's text ships with the state: `file` names a path on the kernel's
            # machine, so a viewer elsewhere cannot read it.
            @test occursin("function smooth", st.source)
            @test st.srcfirst > 0
            @test st.line >= st.srcfirst
        finally
            RE.debug_stop!()
        end
    end

    @testset "continue and results" begin
        RE.debug_start!(Sandbox; cell = "c4", source = "a = 2\nb = a + 3\n")
        st = step!("continue")
        @test st.finished
        @test st.error === nothing
        @test only(b.repr for b in st.bindings if b.name == "b") == "5"
        RE.debug_stop!()
    end

    @testset "refusals keep the shape" begin
        # A start that cannot parse answers as a terminal state, not an exception: a viewer
        # renders "it ended, here is why" already.
        st = RE.debug_start!(Sandbox; cell = "bad", source = "function oops(\n")
        @test st.finished
        @test st.error !== nothing
        @test st.locals == RE.DebugLocal[]

        # An unrecognized verb must not tear down a live session.
        RE.debug_start!(Sandbox; cell = "c5", source = "m = 1\nn = 2\n")
        try
            before = RE.debug_frame()
            st = step!("sideways")
            @test !st.finished
            @test st.steps == before.steps
        finally
            RE.debug_stop!()
        end
    end

    @testset "breakpoints" begin
        ji = RE._ji()
        # A cell's code is parsed with the filename `cell:<id>`, which is what a file breakpoint
        # matches against — so one mechanism arms both a cell line and a method's line.
        src = "t = 0\nfor i in 1:50\n  global t += i\nend\nt\n"
        st = RE.debug_start!(Sandbox; cell = "bp", source = src,
                             mark_files = ["cell:bp"], mark_lines = [3])
        try
            @test !st.finished
            # `continue` stops AT the mark instead of running the cell out — the loop would
            # otherwise be 50 iterations away.
            st = step!("continue")
            @test !st.finished
            @test st.at_breakpoint
            @test st.line == 3
            ev = RE.debug_eval_expr(; expr = "i")
            @test ev.ok
            @test ev.value.repr == "1"

            # Continuing again stops at the same line on the next pass, not the end.
            st = step!("continue")
            @test st.at_breakpoint
            @test RE.debug_eval_expr(; expr = "i").value.repr == "2"

            # Clearing the set lets it run to the end. `at_breakpoint` still holds: it says how
            # the LAST step ended, and nothing has stepped since.
            st = RE.debug_marks!(; mark_files = String[], mark_lines = Int[])
            @test st.line == 3
            st = step!("continue")
            @test st.finished
            @test only(b.repr for b in st.bindings if b.name == "t") == "1275"
        finally
            RE.debug_stop!()
        end
        # Process-global, like the interpret scope: what a session armed, it disarms.
        @test isempty([bp for bp in ji.breakpoints() if occursin("cell:bp", string(bp))])
    end

    @testset "conditional breakpoints" begin
        # The point of a predicate: reach an iteration you could not step to. A plain mark on
        # line 3 stops on i=1, which is the pass that is fine.
        src = "t = 0\nfor i in 1:5000\n  global t += i\nend\nt\n"
        st = RE.debug_start!(Sandbox; cell = "cbp", source = src,
                             mark_files = ["cell:cbp"], mark_lines = [3],
                             mark_conds = ["i == 4700"])
        try
            st = step!("continue")
            @test st.at_breakpoint
            @test st.line == 3
            @test RE.debug_eval_expr(; expr = "i").value.repr == "4700"   # one continue, not 4700 steps
        finally
            RE.debug_stop!()
        end

        # A predicate that errors must neither stop nor abort the run: `shouldbreak` asserts
        # `::Bool` on the result, so an unwrapped one would take the whole cell down.
        st = RE.debug_start!(Sandbox; cell = "cbp2", source = "s = 0\nfor i in 1:20\n  global s += i\nend\ns\n",
                             mark_files = ["cell:cbp2"], mark_lines = [3],
                             mark_conds = ["nosuchbinding > 1"])
        try
            st = step!("continue")
            @test st.finished
            @test !st.at_breakpoint
            @test only(b.repr for b in st.bindings if b.name == "s") == "210"
        finally
            RE.debug_stop!()
        end

        # A predicate that does not parse is refused when armed, rather than silently never firing.
        st = RE.debug_start!(Sandbox; cell = "cbp3", source = "x = 1\nx + 1\n")
        try
            bad = RE.debug_marks!(; mark_files = ["cell:cbp3"], mark_lines = [2],
                                    mark_conds = ["x >"])
            @test !isempty(bad.error)
            @test occursin("does not parse", bad.error)
        finally
            RE.debug_stop!()
        end
    end

    @testset "watch expressions" begin
        # A watch samples at every execution of its line and never stops the run. That is the
        # question a stepper cannot answer: not what a value is now, but what it has been — which
        # is the shape a divergence has, and it is a curve rather than a number.
        src = "t = 0\nfor i in 1:400\n  global t += i\nend\nt\n"
        st = RE.debug_start!(Sandbox; cell = "w", source = src,
                             watch_files = ["cell:w"], watch_lines = [3],
                             watch_exprs = ["t"])
        try
            st = step!("continue")
            @test st.finished                      # a watch does not pause anything
            tr = RE.debug_traces()
            @test haskey(tr, "t")
            @test length(tr["t"]) == 400           # one sample per iteration
            @test tr["t"][1] == 0.0                # `t` BEFORE the first add
            @test tr["t"][end] == sum(1:399)
            @test issorted(tr["t"])                # monotonic, as a running sum must be
            # The SUMMARY rides in every state; the series does not. A hundred thousand samples
            # belong in a chart, not in each step's payload.
            sm = only(st.traces)
            @test sm.expr == "t" && sm.n == 400
            @test sm.first == 0.0 && sm.last == Float64(sum(1:399))
            @test sm.min == 0.0 && sm.max == sm.last
        finally
            RE.debug_stop!()
        end

        # An expression that errors on some iteration must not take the run down with it: a watch
        # observes, and an observer that can break the thing it watches is worse than none.
        st = RE.debug_start!(Sandbox; cell = "w2", source = "s = 0\nfor i in 1:50\n  global s += i\nend\ns\n",
                             watch_files = ["cell:w2"], watch_lines = [3],
                             watch_exprs = ["nosuchbinding + 1"])
        try
            st = step!("continue")
            @test st.finished
            @test only(b.repr for b in st.bindings if b.name == "s") == "1275"
            @test isempty(RE.debug_traces()["nosuchbinding + 1"])   # nothing recorded, nothing broken
        finally
            RE.debug_stop!()
        end

        # Watches and predicate breakpoints coexist: sample every pass, stop on the one that matters.
        st = RE.debug_start!(Sandbox; cell = "w3", source = "t = 0\nfor i in 1:400\n  global t += i\nend\nt\n",
                             mark_files = ["cell:w3"], mark_lines = [3], mark_conds = ["i == 300"],
                             watch_files = ["cell:w3"], watch_lines = [3], watch_exprs = ["t"])
        try
            st = step!("continue")
            @test st.at_breakpoint
            @test RE.debug_eval_expr(; expr = "i").value.repr == "300"
            @test length(RE.debug_traces()["t"]) == 300   # sampled all the way up to the stop
        finally
            RE.debug_stop!()
        end
    end

    @testset "interpreter scope is restored" begin
        ji = RE._ji()
        saved = copy(ji.compiled_modules)
        RE.debug_start!(Sandbox; cell = "c6", source = "s = 1\n")
        @test !(Sandbox in ji.compiled_modules)    # the stepped namespace is interpreted
        RE.debug_stop!()
        # Process-global state: a session left behind would follow the next notebook onto a
        # shared warm worker.
        @test ji.compiled_modules == saved
    end
end
