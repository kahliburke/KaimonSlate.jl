# App mode: serving a notebook as a finished application. The pieces pinned here are the ones whose
# failure is SILENT — a route that quietly stays reachable, a presentation default that never
# arrives, a launcher that resolves the wrong KaimonSlate. The browser half (reading view, app bar,
# neutralised openers) is CSS/JS and is eyeballed, not asserted here; what a test can hold is the
# server's posture and the text of what the exporter generates.
using ReTest
using KaimonSlate
import JSON
const NS = KaimonSlate.NotebookServer

@testset "app route allowlist" begin
    allowed(m, t) = NS._app_route_allowed(m, t)

    @testset "a reader's own traffic is served" begin
        # The page, its state, the live streams, and the things a control does. If any of these were
        # refused the app would not work at all — so they are the floor, not a nicety.
        reader = ["GET /", "GET /status", "GET /api/status", "GET /assets/js/core.js",
                  "GET /n/demo", "GET /n/demo/asset/plot.png", "GET /api/demo/state",
                  "GET /api/demo/events", "GET /api/demo/ws", "GET /api/demo/blob/abc",
                  "GET /api/demo/health",
                  # Which Slate is serving this — the operator of an app is often not its author.
                  "GET /api/version",
                  "POST /api/demo/bind/x", "POST /api/demo/upload-file",
                  "POST /api/demo/table-page", "POST /api/demo/cancel"]
        # One assertion over the whole table: a per-request @test in a loop reports "14 passed" and
        # names nothing when one fails.
        bad = [r for r in reader if !allowed(split(r)[1], split(r)[2])]
        @test isempty(bad)
    end

    @testset "authoring is refused" begin
        # The whole point of app mode. A hidden button is presentation; THIS is the enforcement, so
        # every one of these must stay refused however the front end is restyled.
        authoring = ["POST /api/demo/cell", "POST /api/demo/publish", "POST /api/demo/packages",
                     "GET /api/notebooks", "POST /api/open", "GET /n/demo/export.standalone.jl",
                     "POST /api/demo/eval", "GET /api/demo/files", "POST /api/demo/save",
                     "GET /api/demo/history",
                     # Exporting is authoring: it writes a folder on the server's filesystem.
                     "POST /api/demo/export-app", "GET /api/demo/memo-catalog"]
        leaked = [r for r in authoring if allowed(split(r)[1], split(r)[2])]
        @test isempty(leaked)
    end

    @testset "the allowlist is matched on the path alone" begin
        # A query string must not be able to widen the set — `/api/x/state?…` is allowed because of
        # its path, and a refused path stays refused however it is decorated.
        @test allowed("GET", "/api/demo/state?v=3")
        @test !allowed("GET", "/api/demo/cell?id=a")
        # …and a refused path can't be smuggled in as another route's query value.
        @test !allowed("GET", "/api/notebooks?next=/api/demo/state")
        # Methods outside the two allowlists are refused wholesale, not fallen through.
        @test !allowed("DELETE", "/api/demo/state")
        @test !allowed("PUT", "/api/demo/bind/x")
        # HEAD rides with GET (a probe of an allowed page is an allowed probe).
        @test allowed("HEAD", "/n/demo")
    end
end

@testset "the page shell has no duplicate element ids" begin
    # App mode added a SECOND surface of app-prefixed controls (the reader's settings popover, and
    # the export dialog's App options), and the two collided on `apptheme`. A duplicate id isn't
    # only invalid HTML: `getElementById` returns whichever comes first in the document, so the
    # loser silently reads the winner's element — the export dialog was reading the settings
    # popover's theme select and could never have worked. The browser reports it as a form-autofill
    # warning, which is a long way from that cause.
    html = read(joinpath(@__DIR__, "..", "src", "assets", "notebook.html"), String)
    ids = [m.captures[1] for m in eachmatch(r"\bid=\"([A-Za-z0-9_-]+)\"", html)]
    dupes = sort(unique([i for i in ids if count(==(i), ids) > 1]))
    @test isempty(dupes)
end

@testset "an app doesn't ship the scripts it can't use" begin
    shell = read(joinpath(@__DIR__, "..", "src", "assets", "notebook.html"), String)
    stripped = NS._strip_app_scripts(shell)

    # Every name in the list must actually MATCH a tag — a rename upstream would otherwise turn each
    # entry into a silent no-op, and the page would quietly go back to loading everything.
    missing = [n for n in NS._APP_SKIP_SCRIPTS if !occursin("<script src=\"/assets/js/$n\"></script>", shell)]
    @test isempty(missing)
    @test all(n -> !occursin("/assets/js/$n\"", stripped), NS._APP_SKIP_SCRIPTS)

    # …and the ones an app genuinely needs stay. These aren't arbitrary: core/view/wscall render and
    # talk to the server, appmode/settings build the reading view, the widget files back @bind
    # controls, editor owns `@cell_action` buttons, inspect handles the allowed eval-result path,
    # dialogs owns the shared alert/confirm/loading helpers.
    for n in ("core.js", "view.js", "wscall.js", "appmode.js", "settings.js", "prepare.js",
              "widget-fileupload.js", "widget-rangeslider.js", "outputs.js", "runstatus.js",
              "editor.js", "inspect.js", "dialogs.js", "regions.js", "agent.js", "errors.js")
        @test occursin("/assets/js/$n\"", stripped)
    end
    # Nothing else was disturbed: only whole <script> tags go, one per listed name.
    @test count("<script", stripped) ==
          count("<script", shell) - length(NS._APP_SKIP_SCRIPTS) - length(NS._APP_SKIP_VENDOR)
end

@testset "an app is named for what it is" begin
    RE = KaimonSlate.ReportEngine
    mknb(src, file) = NS.LiveNotebook("app", "/tmp/$file", RE.parse_report(src; title = "app"),
        RE.InProcessKernel(), 1, String[], String[], ReentrantLock(), Channel{String}[],
        ReentrantLock(), "", false, Dict{String,String}())

    nb = mknb("#%% md id=t title\n# Band Deconvolution\n", "app.jl")
    # The bundle filename becomes the SERVED ID, so it is what a reader sees in the URL. `.standalone`
    # is a marker for a bundle handed over on its own; inside an app folder it names nothing, and it
    # leaked all the way into `/n/band_deconvolution_standalone`.
    @test NS._app_bundle_filename(nb) == "band-deconvolution.jl"
    @test !occursin("standalone", NS._app_bundle_filename(nb))
    # An explicit title wins over the document's own.
    @test NS._app_bundle_filename(nb, "Lab Scanner") == "lab-scanner.jl"
    # No title cell → the notebook's own name, still WITHOUT the suffix. This is the branch where
    # `.standalone` would sneak back in if it fell through to `_bundle_filename`.
    untitled = NS._app_bundle_filename(mknb("#%% code id=a\nx=1\n", "app.jl"))
    @test untitled == "app.jl"
    @test !occursin("standalone", untitled)
end

@testset "a reactive push during a run isn't lost" begin
    RE = KaimonSlate.ReportEngine
    # The hazard, in the two lines that matter: a cell is RUNNING, a reactive value it reads
    # changes, and the run then finishes. `mark_result!` marks it FRESH — silently discarding the
    # STALE that the push set mid-run — and since the push has already been and gone, nothing ever
    # restales it again. The cell keeps output computed from values that have since moved.
    #
    # In the app this showed up as a progress bar that never cleared: a handler writes several
    # reactives in a burst (`msg[]`, `result[]`, `busy[] = false`) and the LAST one — the one that
    # clears the flag — is the one most likely to land while the status cell is still running.
    c = RE.Cell("status", RE.CODE, "busy[]")
    RE.mark_running!(c)
    @test c.state == RE.RUNNING

    # What a reactive push does to a RUNNING cell.
    RE.restale!(c)
    @test c.state == RE.STALE

    # …and what the run's completion did to it before this fix.
    RE.mark_result!(c, nothing)
    @test c.state == RE.FRESH        # ← the STALE above is gone, and nothing will set it again

    # The fix keeps the result but restores STALE, so the runner comes back to it. (`_eval_one!`
    # does exactly this when the cell id is in `_DIRTY_WHILE_RUNNING`.)
    RE.restale!(c)
    @test c.state == RE.STALE

    # The marker is per notebook and consumed once — a re-run must not loop forever.
    empty!(NS._DIRTY_WHILE_RUNNING)
    s = get!(Set{String}, NS._DIRTY_WHILE_RUNNING, "nb1")
    push!(s, "status")
    @test pop!(s, "status", nothing) !== nothing     # first completion re-runs it…
    @test pop!(s, "status", nothing) === nothing     # …the second doesn't
    empty!(NS._DIRTY_WHILE_RUNNING)
end

# An app is BUILT by copying the notebook into the bundle, so it is always a copy of its source and
# the shared-document notice would always fire — telling a reader who is not the author about a file
# on the machine the app was built on, absolute path included. It is suppressed by process, not by
# hiding it client-side, so the path never reaches the wire.
@testset "an app never reports its source document" begin
    RE = KaimonSlate.ReportEngine
    H = NS.SlateHistory
    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            old_root = H._ROOT[]; old_app = NS._APP_PROCESS[]
            H._ROOT[] = joinpath(dir, "kaimonslate", "history")
            try
                src = joinpath(dir, "source.jl"); copy = joinpath(dir, "app-copy.jl")
                write(src, "#%% code id=a\nx = 1\n"); write(copy, "#%% code id=a\nx = 1\n")
                meta = Dict{String,Any}("docid" => "11111111-2222-3333-4444-555555555555")
                # One document recorded at both paths, both still present: a genuine copy.
                d(p) = H.Doc(NS.doc_key(p, meta), abspath(p))
                H.record!(d(src), "x\n"; cells = [("a", "code", "x\n")])
                H.record!(d(copy), "x\n2\n"; cells = [("a", "code", "x\n"), ("b", "code", "2\n")])

                nb = RE.parse_report("#%% code id=a\nx = 1\n")
                nb.meta["docid"] = meta["docid"]
                live = NS.LiveNotebook("app", copy, nb, RE.PendingKernel(), 0, String[], String[],
                                       ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                                       Dict{String,String}())
                NS._APP_PROCESS[] = false
                @test !isempty(NS.shared_with(live))            # authoring: the copy IS detected
                @test haskey(NS.state_json(live), "sharedWith")

                NS._APP_PROCESS[] = true                        # app mode: never on the wire
                s = NS.state_json(live)
                @test !haskey(s, "sharedWith")
                @test !haskey(s, "sharedFrom")
                @test !occursin(abspath(src), string(s))        # …and the source path leaks nowhere else
            finally
                H._ROOT[] = old_root; NS._APP_PROCESS[] = old_app
            end
        end
    end
end

# A `region=` cell names its compute target; the host lives in the registry, which an app's isolated
# state home does not have. So the definitions the notebook uses travel beside the launcher and
# `run.jl` seeds them in — otherwise a region cell has a name, no host, and never runs.
@testset "an app carries the regions its cells use" begin
    RE = KaimonSlate.ReportEngine
    mktempdir() do cfg
        withenv("KAIMONSLATE_CONFIG_HOME" => cfg) do
            # No hyphen: `region_set!` sanitises a name (`-` → `_`), so a hyphen here would compare
            # the name we asked for against the one the registry actually stored.
            name = "__apregtest_$(getpid())__"
            RE.region_set!(name; host = "somehost", transport = :tunnel)
            src = joinpath(cfg, "nb.jl")
            write(src, "#%% code id=a\nx = 1\n\n#%% code id=b region=$name\ny = x + 1\n")
            rep = RE.parse_report(read(src, String))
            live = NS.LiveNotebook("nb", src, rep, RE.PendingKernel(), 0, String[], String[],
                                   ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                                   Dict{String,String}())
            out = mktempdir()
            NS._write_app_regions(live, out)
            f = joinpath(out, "regions.json")
            @test isfile(f)
            defs = JSON.parse(read(f, String))
            @test [String(d["name"]) for d in defs] == [name]   # only what the notebook uses
            @test String(defs[1]["host"]) == "somehost"          # …with the host, or it can't be reached

            # Seeding an empty home from that file is what makes the name resolve in the app.
            fresh = mktempdir()
            withenv("KAIMONSLATE_CONFIG_HOME" => fresh) do
                @test RE.region_get(name) === nothing
                cp(f, joinpath(fresh, "regions.json"))
                r = RE.region_get(name)
                @test r !== nothing && r.host == "somehost"
            end

            # A notebook that places nothing on a region carries no file at all.
            plain = RE.parse_report("#%% code id=a\nx = 1\n")
            pl = NS.LiveNotebook("p", src, plain, RE.PendingKernel(), 0, String[], String[],
                                 ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                                 Dict{String,String}())
            out2 = mktempdir()
            NS._write_app_regions(pl, out2)
            @test !isfile(joinpath(out2, "regions.json"))
        end
    end
end

# `run.jl` must only seed a home that has no registry of its own, so an operator who configures the
# region there (pointing the app at a machine they control) is not overwritten on every start.
@testset "the launcher seeds regions without overwriting" begin
    rj = NS._run_script(""; agent = false, bundle_name = "x.jl", app = true,
                        appdefaults = Dict{String,Any}(), port = 0, apptitle = "T")
    @test occursin("regions.json", rj)
    @test occursin("KAIMONSLATE_CONFIG_HOME", rj)
    @test occursin("!isfile(joinpath(cfg", rj)          # only when the home has none
end

# An export ships the repo's TRACKED files. A package whose source `include`s a file nobody
# `git add`ed therefore cannot LOAD on the target machine: the app dies in `Pkg.instantiate` with a
# SystemError naming a path inside the install, minutes after an export that reported success, and
# nothing about the exported folder looks wrong. Catch it while the author is still here.
@testset "an export notices source it cannot carry" begin
    f = NS._unshipped_includes
    d = mktempdir(); mkpath(joinpath(d, "src"))
    write(joinpath(d, "src", "P.jl"), """
    module P
    include("shipped.jl")
    include("untracked.jl")
    include(joinpath(@__DIR__, "computed.jl"))
    end
    """)
    write(joinpath(d, "src", "shipped.jl"), "1")
    write(joinpath(d, "src", "untracked.jl"), "2")

    @test isempty(f(d, Set(["src/P.jl", "src/shipped.jl", "src/untracked.jl"])))   # all carried → quiet
    @test f(d, Set(["src/P.jl", "src/shipped.jl"])) == ["src/untracked.jl"]        # the real gap
    # A computed include can't be resolved here, and guessing would cry wolf over a file that is fine.
    @test !any(m -> occursin("computed", m), f(d, Set(["src/P.jl", "src/shipped.jl"])))
    # A source file that isn't shipped ITSELF says nothing about its includes.
    @test isempty(f(d, Set(["src/shipped.jl"])))
    # An include naming a file that doesn't exist is already broken in the source, not an export fault.
    write(joinpath(d, "src", "Q.jl"), "include(\"never-existed.jl\")\n")
    @test isempty(f(d, Set(["src/Q.jl"])))
end

# `/status` judged every worker by a LOCAL process handle. A remote worker has none, so it reported
# "not running" on a card that was, at the same moment, showing its live CPU and memory — a page an
# operator consults precisely when they distrust the system, contradicting itself.
@testset "a remote worker is judged by its wire, not a local pid" begin
    a = NS._status_alive
    # The reported case: remote, wire up, no local process.
    @test a(true, true, false, 1.0)
    # No wire, but a sample too recent to have come from a dead process.
    @test a(true, false, false, 3.0)
    # Silent long enough that the sample proves nothing.
    @test !a(true, false, false, 10 * NS._STATUS_SAMPLE_FRESH)
    @test NS._STATUS_SAMPLE_FRESH > 2   # must outlast several 2s publish intervals, or it flickers

    # A LOCAL worker is a process we own, so the OS is the authority: recent chatter does not make an
    # exited process alive, and a live one needs no telemetry to count.
    @test a(false, true, true, 1.0)
    @test !a(false, true, false, 1.0)
    @test a(false, false, true, Inf)
end

@testset "presentation defaults" begin
    # Names in, localStorage keys out — the page applies them with the setters it already has.
    d = NS.app_defaults(theme = "nord", fullwidth = true, pagewidth = 1400, scrollzoom = 0)
    @test d["slateTheme"] == "nord"
    @test d["slatePageMax"] == "1400"
    @test d["slateScrollZoom"] == "0"
    @test d["slateFullWidth"] == "1"          # Bool → the "1"/"0" the page stores
    @test NS.app_defaults(fullwidth = false)["slateFullWidth"] == "0"
    # An unknown name is DROPPED, not guessed at — a typo must not silently become a stored key.
    @test !haskey(NS.app_defaults(thmee = "nord"), "thmee")
    @test isempty(NS.app_defaults())
end

@testset "app bootstrap injection" begin
    shell = "<title>Kaimon Slate</title><script>window.__SLATE_APP__=null;</script>"
    h = NS.Hub  # type only; _inject_app needs a real Hub, so drive the escaping via app_defaults text
    @test h === NS.Hub
    # The payload lands inside a <script>: a "</" in a default would otherwise close it early.
    d = NS.app_defaults(theme = "</script><b>x")
    @test occursin("</script>", d["slateTheme"])          # the VALUE keeps its text…
    js = replace(KaimonSlate.JSON.json(d), "</" => "<\\/")
    @test !occursin("</script>", js)                      # …and the injected form cannot close the tag
    @test occursin("<\\/script>", js)
end

@testset "run.jl resolves the KaimonSlate that exported it" begin
    # A package unpacked into a depot is read-only and content-addressed — nothing to develop.
    @test NS._dev_checkout_path(joinpath(first(DEPOT_PATH), "packages", "Foo", "abc123", "src")) == ""
    # No Project.toml above `src` → not a project at all.
    @test NS._dev_checkout_path(mktempdir()) == ""
    # A working checkout resolves to its root, with no trailing separator.
    root = mktempdir()
    write(joinpath(root, "Project.toml"), "name = \"Foo\"\n")
    mkpath(joinpath(root, "src"))
    @test NS._dev_checkout_path(joinpath(root, "src")) == rstrip(abspath(root), '/')

    rj = NS._run_script("https://x/y/nb.standalone.jl"; app = true, apptitle = "Demo", port = 7373)
    @test (Meta.parseall(rj); true)                       # generated Julia is valid (escaping intact)
    @test occursin("app = true", rj)                      # …and serves in app mode
    @test occursin("default_path", rj)                    # exporting checkout baked in as a DEFAULT…
    @test occursin("SLATE_KAIMONSLATE_PATH", rj)          # …with the env var still able to override
end

@testset "a run isolates its gates from the machine's Kaimon" begin
    # A worker's gate announces itself by writing session metadata into `<cache>/kaimon/sock`, and a
    # Kaimon on the same machine watches that directory and connects to every local gate in it. Two
    # clients then share one gate and the hub's calls to its OWN worker time out — presenting as
    # workers that "fail" and respawn while each one is healthy. So a run must not announce its gates
    # into the shared cache. Both env names, because Kaimon resolves its cache per-platform.
    for rj in (NS._run_script("https://x/y/nb.standalone.jl"; app = true, apptitle = "Demo"),
               NS._run_script("https://x/y/nb.standalone.jl"))          # standalone leaks the same way
        @test occursin("XDG_CACHE_HOME", rj) && occursin("LOCALAPPDATA", rj)
    end

    # It has to land in the run's OWN folder — a self-contained app that someone deletes should take
    # its gate sockets with it, not leave them in a machine-global cache. BESIDE the install dir,
    # never inside it: the cache is populated when the hub first touches its history, which happens
    # before the notebook is opened and so before the bundle is extracted — and extraction refuses a
    # non-empty install dir that isn't already a Slate install. A cache under `dir` therefore fails
    # the run with a message about SLATE_INSTALL_DIR that points nowhere near the cause.
    rj = NS._run_script("https://x/y/nb.standalone.jl"; app = true)
    @test occursin("joinpath(@__DIR__, \".cache\")", rj)
    @test !occursin("joinpath(dir, \".cache\")", rj)
    # …and be set where `dir` is known but nothing has served yet: after this, a worker spawn would
    # already have announced itself in the shared directory.
    @test findfirst("XDG_CACHE_HOME", rj).start < findfirst("serve_notebook", rj).start

    # …and nothing in the isolation block may CREATE a directory under `dir` either, for the same
    # reason — the install dir has to still be empty when extraction reaches it.
    block = rj[findfirst("SLATE_INSTALL_DIR", rj).start:findfirst("Where to listen", rj).start]
    @test !occursin("mkpath(cache", block) && !occursin("mkpath(joinpath(dir", block)

    # The mechanism this rests on — that the gate resolves its socket directory from the environment
    # at RUNTIME rather than at load — belongs to Kaimon and is verified against it directly, not
    # re-asserted here where KaimonGate may not even be loaded.
end

@testset "ready banner" begin
    say(; kw...) = sprint(io -> NS._print_ready_banner("http://0.0.0.0:7373/n/band-deconv"; io = io, kw...))

    # An app is announced at the server ROOT (`/` redirects to its notebook), so the banner shows an
    # address a person can type or read out — not an internal id derived from a filename.
    root = sprint(io -> NS._print_ready_banner("http://0.0.0.0:7373"; io = io, keys = true,
                                               app = true, apptitle = "Band Deconvolution"))
    @test occursin("http://0.0.0.0:7373", root) && !occursin("/n/", root)
    @test occursin("http://0.0.0.0:7373/status", root)

    a = say(keys = true, app = true, apptitle = "Band Deconvolution")
    @test occursin("Band Deconvolution is running", a)     # named by its document, not by "notebook"
    @test occursin("/status", a)                           # the operator page is how you diagnose it
    # `b`/`p` mean "open AND launch" vs "open, stay a preview" — a lifecycle an app doesn't have,
    # since it is warmed before this prints. Offering them invites a reader to "go live" twice.
    @test !occursin("go live", a) && !occursin("stay a preview", a)
    @test occursin("open in a browser", a) && occursin("stop the app", a)

    # No document title → a generic subject, never a dangling "  ✓   is running".
    @test occursin("Your app is running", say(app = true, apptitle = ""))
    # `/status` on EVERY app path — a deployed app usually starts with no terminal (backgrounded, a
    # unit file, piped to a log), which is precisely when nobody can ask it how it's doing.
    @test occursin("/status", say(app = true, keys = false))

    # The authoring banner is untouched: it still has the preview lifecycle, and no /status.
    n = say(keys = true)
    @test occursin("notebook is live", n) && occursin("go live", n) && occursin("stay a preview", n)
    @test !occursin("/status", n)
    @test occursin("static preview", say(keys = true, inactive = true))
end

@testset "run.sh" begin
    sh = NS._run_sh("Band Study")
    @test occursin("Band Study", sh)
    @test occursin("--help", sh)
    # Colour is opt-OUT by environment and opt-in by capability: piping this into a log file or a
    # unit's journal must not fill it with escape codes.
    @test occursin("NO_COLOR", sh) && occursin("[ -t 1 ]", sh)
    # `--help` is answered by run.jl; the banner must not print above it.
    @test occursin("show_banner", sh)
    @test occursin("set -euo pipefail", sh)
    # The name is a printf ARGUMENT, never part of its format string, so a % in it is just a %.
    @test occursin("\"100% Study\"", NS._run_sh("100% Study"))
    # A named app says what it is under its name…
    @test occursin("a Kaimon Slate app", sh)
    # …but an unnamed one falls back to that same phrase as its NAME, so the subtitle would restate
    # it verbatim on the next line. One line, not two.
    # (counted over the printed banner only — the file's header comment names it too)
    banner(s) = [l for l in split(s, '\n') if occursin("printf", l) && occursin("Kaimon Slate app", l)]
    plain = NS._run_sh("")
    @test length(banner(plain)) == 1
    @test length(banner(sh)) == 1        # named: the name line is "Band Study", the subtitle is this
    # The choice is made at export time, so the script must not carry a test that can only pass —
    # dead code shipped to whoever reads the launcher.
    @test !occursin("[ -n \"a Kaimon Slate app\" ]", sh)
end
