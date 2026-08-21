# A worker that DIES during boot must be reported as a crash, not as an unreachable socket
# (issue #18). The connect error only ever says "connection refused", which describes the port and
# sends the reader off to check firewalls while the real cause sits in the worker's log.
using ReTest
using KaimonSlate
const RE = KaimonSlate.ReportEngine

# `wait_s = 0` throughout: the grace period exists so a log line still in the pump can land, and
# waiting it out here would only make the suite slow.
@testset "worker boot failure" begin
    @testset "the worker's own error is what gets reported" begin
        log = tempname()
        write(log, """
              SlateWorker starting on port 9108
              ERROR: LoadError: ArgumentError: Package SlateExtensionsBase [bc31d39e] is required but does not seem to be installed:
               - Run `Pkg.instantiate()` to install all recorded dependencies.
              in expression starting at /x/src/widgets.jl:22
              """)
        lines = RE._worker_error_lines(log; wait_s = 0)
        # Starts AT the error, not at the top of the log — the banner above it is noise.
        @test startswith(lines[1], "ERROR: LoadError: ArgumentError")
        @test length(lines) == 3
        @test occursin("widgets.jl:22", lines[end])
    end

    @testset "context after the error is capped" begin
        log = tempname()
        write(log, "boot\nERROR: boom\n" * join(["frame $i" for i in 1:50], "\n"))
        @test length(RE._worker_error_lines(log; max_lines = 5, wait_s = 0)) == 5
    end

    @testset "a death with no ERROR: line falls back to the tail" begin
        # A signal or an OOM kill leaves no `ERROR:` — the evidence is wherever the log stopped.
        log = tempname()
        write(log, join(["line $i" for i in 1:40], "\n"))
        lines = RE._worker_error_lines(log; max_lines = 4, wait_s = 0)
        @test lines == ["line 37", "line 38", "line 39", "line 40"]
    end

    @testset "a missing or empty log yields nothing, and never throws" begin
        @test RE._worker_error_lines(tempname(); wait_s = 0) == String[]
        empty_log = tempname()
        write(empty_log, "")
        @test RE._worker_error_lines(empty_log; wait_s = 0) == String[]
    end

    @testset "the message names the crash, the cause, and the log" begin
        k = RE.GateKernel(mktempdir())
        k.port = 9108
        k.logpath = tempname()
        write(k.logpath, "ERROR: ArgumentError: Package Foo is required but does not seem to be installed\n")
        msg = RE._boot_failure_message(k)
        # The three things a reader needs: WHICH worker, WHY it died, and where the rest is.
        @test occursin("exited during boot", msg)
        @test occursin("9108", msg)
        @test occursin("Package Foo is required", msg)
        @test occursin(k.logpath, msg)
        # It must NOT claim a network condition — that was the whole complaint.
        @test !occursin("not reachable", msg)
        @test !occursin("connection refused", msg)
    end

    @testset "only a kernel that owns a process can be judged dead" begin
        # An attached/remote kernel has no `proc`; it must keep waiting out the deadline rather than
        # be declared crashed on the strength of a `nothing`.
        k = RE.GateKernel(mktempdir())
        @test k.proc === nothing
        @test RE._worker_died(k) == false
    end

    @testset "a live process is not reported as dead, an exited one is" begin
        k = RE.GateKernel(mktempdir())
        k.proc = run(`sleep 30`; wait = false)
        try
            @test RE._worker_died(k) == false
        finally
            kill(k.proc)
        end
        dead = RE.GateKernel(mktempdir())
        dead.proc = run(pipeline(`false`; stdout = devnull, stderr = devnull); wait = false)
        wait(dead.proc)
        @test RE._worker_died(dead) == true
    end

    # The error at the top of this file — "SlateExtensionsBase … is required but does not seem to be
    # installed" — is what a worker reports when its infra env was never resolved. That names a
    # package, but the fault is one step earlier: the env build failed and the old code fell back to a
    # dir with no Manifest, discarding the reason. These two helpers are what let the build report
    # itself instead.
    @testset "a failed env build explains itself" begin
        @testset "the reason is the log's first ERROR line" begin
            log = tempname()
            write(log, """
                  Installing known registries into `~/.julia`
                  Resolving package versions...
                  ERROR: Unsatisfiable requirements detected for package SlateExtensionsBase [bc31d39e]:
                   Restricted by compat entry to versions: 0.9.1
                  """)
            r = RE._env_build_error(log)
            @test startswith(r, "ERROR: Unsatisfiable requirements")
            @test !occursin("Resolving package versions", r)   # the noise above it is dropped
        end

        @testset "no ERROR line falls back to the tail, never to silence" begin
            log = tempname()
            write(log, "Resolving...\n\nfailed to clone from https://example.invalid\n  network is unreachable\n")
            r = RE._env_build_error(log)
            @test occursin("network is unreachable", r)
            @test occursin("failed to clone", r)               # a few lines of context, joined
        end

        @testset "a missing or empty log says so rather than throwing" begin
            @test occursin("no build log", RE._env_build_error(joinpath(mktempdir(), "absent.log")))
            empty_log = tempname(); write(empty_log, "   \n\n")
            @test occursin("empty", RE._env_build_error(empty_log))
        end

        @testset "the reason is capped so it can ride in an error message" begin
            log = tempname(); write(log, "ERROR: " * repeat("x", 5000) * "\n")
            @test length(RE._env_build_error(log)) <= 300
        end

        # The predicate that decides fail-closed vs fall-back. A Project.toml alone resolves nothing;
        # only a Manifest means the dir is usable on a worker's LOAD_PATH.
        @testset "an env counts as usable only once it has a Manifest" begin
            d = mktempdir()
            write(joinpath(d, "Project.toml"), "name = \"x\"\n")
            @test RE._env_instantiated(d) == false
            write(joinpath(d, "Manifest.toml"), "manifest_format = \"2.0\"\n")
            @test RE._env_instantiated(d) == true
        end
    end
end
