# The hub's worker reaper: a worker that accepted a shutdown request is left to exit on its own
# before any signal, and one that does not exit is escalated to SIGTERM, then SIGKILL.
using ReTest
using KaimonSlate
const RE = KaimonSlate.ReportEngine

# By pid: `getpid` on a process that has exited throws.
stage(pid) = lock(() -> get(RE._PENDING_KILLS, pid, nothing), RE._PENDING_KILLS_LOCK)
backdate!(pid, s) = lock(RE._PENDING_KILLS_LOCK) do
    r = RE._PENDING_KILLS[pid]
    RE._PENDING_KILLS[pid] = (proc = r.proc, stage = r.stage, since = r.since - s)
end
gone(p) = timedwait(() -> !process_running(p), 5.0) === :ok

@testset "worker reaper" begin
    @testset "a worker exiting on request gets no signal until its grace runs out" begin
        p = run(`sleep 30`; wait = false); pid = getpid(p)
        RE.register_pending_kill!(p; termed = false)
        RE.reap_pending_kills!()
        @test stage(pid).stage === :asked && process_running(p)
        backdate!(pid, RE._EXIT_GRACE_S + 1)
        RE.reap_pending_kills!()
        @test stage(pid).stage === :termed
        @test gone(p)
        RE.reap_pending_kills!()
        @test stage(pid) === nothing
    end

    @testset "hub stop SIGTERMs workers still exiting, and SIGKILL follows" begin
        # Ignored signals survive exec, so this process ignores SIGTERM.
        p = run(`sh -c 'trap "" TERM; exec sleep 30'`; wait = false); pid = getpid(p)
        RE.register_pending_kill!(p; termed = false)
        RE.term_pending_exits!(; wait_s = 0.1)
        @test stage(pid).stage === :termed && process_running(p)
        backdate!(pid, RE._KILL_GRACE_S + 1)
        RE.reap_pending_kills!()
        @test stage(pid).stage === :killed
        @test gone(p)
        RE.reap_pending_kills!()
        @test stage(pid) === nothing
    end
end
