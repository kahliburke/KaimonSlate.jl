# What travels to a remote, and what a sync survives.
#
# Two things are covered here, and they are related by the bug that produced both. A project
# directory is shipped by walking it into a tar: the walk decides WHAT goes (this file's first half)
# and it has to tolerate the tree changing underneath it (the second). When the walk was neither
# filtered nor tolerant, a project with a large untracked directory beside its code tried to send
# all of it, and a store being written while it was read aborted the sync outright.
using ReTest
include(joinpath(@__DIR__, "..", "src", "sweep.jl"))

const SW = Sweep
const MS = MemoStore

# A project laid out the way the reports were: code, plus things nobody wants on the far side.
# `git` may be absent in a test environment, so the git half is skipped rather than failed —
# `.slateignore` is asserted either way.
function _mkproj(dir; gitignore = "data/\n*.h5\n", slateignore = "")
    for d in ("src", "data", "results", "sub/data")
        mkpath(joinpath(dir, d))
    end
    write(joinpath(dir, "Project.toml"), "name = \"P\"\n")
    write(joinpath(dir, "src", "main.jl"), "x = 1\n")
    write(joinpath(dir, "data", "huge.bin"), "0"^64)
    write(joinpath(dir, "sub", "data", "also.bin"), "0"^64)
    write(joinpath(dir, "results", "out.h5"), "0"^8)
    write(joinpath(dir, "keep.txt"), "keep me\n")
    isempty(gitignore) || write(joinpath(dir, ".gitignore"), gitignore)
    isempty(slateignore) || write(joinpath(dir, SW._SLATEIGNORE), slateignore)
    return dir
end

_has_git() = try; success(`git --version`); catch; false; end
_git_init(dir) = try
    run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir add -A`; stdout = devnull, stderr = devnull))
    true
catch
    false
end

# Everything the filter keeps, as a sorted list — one assertion per scenario rather than one per
# path, so a failure names the whole shape that was wrong instead of the first file that differed.
function _kept(dir; region = "", excludes = String[])
    k = SW.transfer_keep(dir; region, excludes)
    out = String[]
    for (root, _, files) in walkdir(dir), f in files
        rel = replace(relpath(joinpath(root, f), dir), '\\' => '/')
        k(rel) && push!(out, rel)
    end
    return sort!(out)
end

@testset "transfer filter" begin
    @testset ".gitignore decides, with no configuration at all" begin
        if !_has_git()
            @test true                      # no git here; `.slateignore` below covers the rest
        else
            mktempdir() do d
                _mkproj(d)
                @test _git_init(d)
                # The reported case: a large untracked directory beside the code. It is ignored, so
                # it does not travel, and nobody had to say so anywhere.
                got = _kept(d)
                @test got == [".gitignore", "Project.toml", "keep.txt", "src/main.jl"]
                # The same thing said as properties, because that is what the fix is about: an
                # ignored directory does not travel, at any depth, and the code still does.
                @test !any(occursin("data/", p) for p in got)
                @test !any(endswith(p, ".h5") for p in got)
            end
        end
    end

    @testset ".slateignore works without git, and adds to it" begin
        mktempdir() do d
            # No git init: a project that is not a repository at all still gets a say.
            _mkproj(d; gitignore = "", slateignore = "results/\ndata/\n")
            # `.slateignore` travels with the project, exactly as `.gitignore` does above: it is a
            # project file, and the far side holding the rules it was sent under is worth the bytes.
            got = _kept(d)
            @test got == [".slateignore", "Project.toml", "keep.txt", "src/main.jl"]
            # An unanchored directory name matches at any depth, which is gitignore's rule and the
            # one people rely on when they write `data/`.
            @test !any(occursin("data/", p) for p in got)
        end
    end

    @testset "a region section applies only to that region" begin
        mktempdir() do d
            # The case that is genuinely per-destination: this host already has the data by other
            # means, so it is skipped THERE and sent everywhere else.
            _mkproj(d; gitignore = "", slateignore = "[region:studio]\ndata/\n")
            everywhere = _kept(d)
            studio = _kept(d; region = "studio")
            @test "data/huge.bin" in everywhere
            @test !("data/huge.bin" in studio)
            # …and the region section changes nothing else.
            @test setdiff(everywhere, studio) == ["data/huge.bin", "sub/data/also.bin"]
        end
    end

    @testset "a later rule wins, so a region can un-ignore" begin
        mktempdir() do d
            _mkproj(d; gitignore = "", slateignore = "data/\n\n[region:needsdata]\n!data/\n")
            @test !("data/huge.bin" in _kept(d))
            @test "data/huge.bin" in _kept(d; region = "needsdata")
        end
    end

    @testset "the fixed excludes still apply" begin
        mktempdir() do d
            _mkproj(d; gitignore = "")
            mkpath(joinpath(d, ".git")); write(joinpath(d, ".git", "HEAD"), "ref\n")
            write(joinpath(d, "Manifest.toml"), "x\n")
            got = _kept(d; excludes = ["Manifest.toml", ".git"])
            @test !any(startswith(p, ".git/") for p in got)
            @test !("Manifest.toml" in got)
            @test "Project.toml" in got
        end
    end

    @testset "an anchored pattern matches only at the root" begin
        mktempdir() do d
            _mkproj(d; gitignore = "", slateignore = "/data/\n")
            got = _kept(d)
            @test !("data/huge.bin" in got)      # at the root: dropped
            @test "sub/data/also.bin" in got     # deeper: kept, because the pattern is anchored
        end
    end
end

# Where the EDITOR for these rules lives, and what it is allowed to write to. Source-level, because
# standing a server up to assert a path is more machinery than the claim needs — and the claim is
# about scope, which is visible in the source.
@testset "the rules editor is anchored on the project" begin
    src = read(joinpath(@__DIR__, "..", "src", "server_complete.jl"), String)
    dag = read(joinpath(@__DIR__, "..", "src", "assets", "js", "dag.js"), String)
    focus = read(joinpath(@__DIR__, "..", "src", "assets", "js", "remotes-focus.js"), String)
    css = read(joinpath(@__DIR__, "..", "src", "assets", "notebook.css"), String)
    fails = String[]

    # PER NOTEBOOK is how it is reached; PER PROJECT is what it edits. The route carries a notebook
    # id so the project can be resolved server-side, and the file is written beside that project's
    # Project.toml — not into the per-notebook fork env, which lives in the depot, is generated, and
    # could never be committed.
    occursin("\"/api/{id}/transfer-rules\"", src) ||
        push!(fails, "the rules route is not scoped to a notebook")
    occursin("_project_of(nb) = String(get(nb.report.meta, \"assetbase\", \"\"))", src) ||
        push!(fails, "the project anchor is not `assetbase`")
    # The two wrong anchors, named so a future edit cannot quietly pick one up again.
    occursin("_region_ship_dir", src) &&
        push!(fails, "the editor resolves a REGION's preload again — a region is global across projects")
    occursin("notebook_env_dir", src) && occursin("transfer-rules", src) &&
        occursin("origin_env", src) &&
        push!(fails, "the editor may be resolving the fork env instead of the project")

    # It belongs beside the region map, which is the pane that answers "where does my work go".
    occursin("_dagRegionDetail", dag) || push!(fails, "the DAG pane has no region detail panel")
    occursin("_dagTravelsToggle", dag) ||
        push!(fails, "the tree has no prune toggle — this was a textarea once, and must not be again")
    occursin("_dagTravelGuard", dag) ||
        push!(fails, "nothing opens the tool before an expensive first provision")
    # And it must NOT come back on the front page, where the project is not knowable.
    occursin("TransferRules", focus) &&
        push!(fails, "the front-page region editor grew a transfer panel again")

    # A class the JS names but the stylesheet never defines renders as unstyled text, and nothing
    # reports it — the parse test only checks that the script is syntactically valid.
    for m in eachmatch(r"class=\"(dag(?:tv|travel|regleg|regfacts|reghue|regdot)[a-z-]*)", dag)
        occursin("." * m.captures[1], css) || push!(fails, "CSS class .$(m.captures[1]) is undefined")
    end

    isempty(fails) || @info "transfer editor drift" fails
    @test isempty(fails)
end

# Writing the rules FILE from a set of toggles. The tool shows a tree and the user clicks; this is
# what turns that back into text — in a file a person may also have edited by hand.
@testset "toggles edit the rules file without eating what they did not write" begin
    ah = SW.apply_holds
    @testset "the managed lines" begin
        @test ah("", "", ["scratch", "dist"], ["scratch", "dist", "src"]) == "scratch/\ndist/\n"
        @test ah("scratch/\n", "", ["scratch"], ["scratch"]) == "scratch/\n"      # idempotent
        @test ah("scratch/\n", "", String[], ["scratch"]) == ""                   # unticked ⇒ gone
        @test ah("", "", ["a/b"], ["a/b"]) == "a/b/\n"                            # a nested path
    end
    @testset "everything else is left alone" begin
        # A pattern no toggle could have produced is not the UI's to delete. `known` is what the
        # caller was in a position to decide about, and it may only remove from that.
        @test ah("scratch/\n*.h5\n", "", String[], ["scratch"]) == "*.h5\n"
        @test ah("!data/\n", "", String[], ["data"]) == "!data/\n"                # a deliberate un-ignore
        @test ah("# mine\nscratch/\n", "", ["scratch"], ["scratch"]) == "# mine\nscratch/\n"
    end
    @testset "sections" begin
        # A named section is created when absent, and edited in place when present — without
        # disturbing the global preamble above it or another region's section below.
        @test ah("scratch/\n", "gpu", ["data"], ["data", "scratch"]) ==
              "scratch/\n\n[region:gpu]\ndata/\n"
        @test ah("scratch/\n\n[region:gpu]\ndata/\n", "gpu", String[], ["data", "scratch"]) ==
              "scratch/\n\n[region:gpu]\n"
        # The added line lands INSIDE the section, not past the blank that separates it from the
        # next one — where it would silently belong to a different host.
        @test ah("[region:a]\nx/\n\n[region:b]\ny/\n", "a", ["z"], ["x", "z"]) ==
              "[region:a]\nz/\n\n[region:b]\ny/\n"
    end
end

# The pattern language is gitignore's, and this is where that claim is kept honest.
#
# It was previously an approximation, and the failure mode of an approximation here is SILENT: a
# pattern that matches nothing looks exactly like one that was meant to match nothing, and the
# result is a directory shipped that should have stayed home. `**`, character classes and escapes
# all quietly matched nothing.
@testset "the patterns really are gitignore's" begin
    rules(text) = (d = mktempdir(); write(joinpath(d, SW._SLATEIGNORE), text * "\n");
                   SW._slateignore_rules(d, ""))
    ig(text, rel; isdir = false, git = false) = SW._ignored(rules(text), rel, isdir, git)

    @testset "** crosses directories" begin
        @test ig("**/*.h5", "a/b/x.h5")
        @test ig("**/*.h5", "x.h5")            # `**/` is zero or more, so the root counts
        @test ig("a/**/b", "a/b")              # …including none at all
        @test ig("a/**/b", "a/x/y/b")
        @test ig("logs/**", "logs/a/b.txt")
    end
    @testset "character classes" begin
        @test ig("[Bb]uild/", "Build/x") && ig("[Bb]uild/", "build/x")
        @test ig("[a-c]x", "bx")
        @test ig("[!a]bc", "xbc")
        @test !ig("[!a]bc", "abc")
    end
    @testset "escapes and trailing space" begin
        @test ig("\\#lit", "#lit")             # not a comment
        @test ig("\\!lit", "!lit")             # not a negation
        @test ig("keep   ", "keep")            # unescaped trailing space is not part of the name
    end
    @testset "anchoring" begin
        # A slash-free pattern matches at any depth; one that says WHERE is rooted.
        @test ig("build/", "a/b/build/x")
        @test ig("/data/", "data/x")
        @test !ig("/data/", "sub/data/x")
        @test !ig("a*b", "a/b")                # `*` never crosses a separator
    end
    @testset "git is a seed the rules may override" begin
        # `.gitignore` decides first and `.slateignore` gets the last word, which is the same
        # last-match-wins rule gitignore uses between its own layers.
        @test ig("", "data/x"; git = true)                    # nothing said ⇒ git's answer stands
        @test !ig("!data/x", "data/x"; git = true)            # send this one anyway
        @test !ig("!**", "data/x"; git = true)                # ignore .gitignore for transfers
        # …and git's own precedence: under an excluded DIRECTORY, re-inclusion is not possible.
        @test ig("data/\n!data/keep", "data/keep")
    end
end

# A rule has to match the very thing it names, not only what is under it. The editor asks "is this
# directory held?" to draw its state; when the answer was always no, ticking a directory and saving
# appeared to do nothing — the rule was written, the transfer honoured it, and the checkbox came
# back unticked. A save that looks lost is worse than one that fails.
@testset "a directory rule matches the directory, not just its contents" begin
    mktempdir() do d
        write(joinpath(d, SW._SLATEIGNORE), "assets/\nsub/deep/\n")
        r = SW._slateignore_rules(d, "")
        # Two different questions, deliberately answered by two functions.
        #   `_rule_hits` — does this rule NAME this entry? The editor asks it per row, to draw a
        #                  tick. A `dir/` rule names the directory, not the files inside it.
        #   `_ignored`   — is this path excluded? Walks every parent, so a held directory carries
        #                  its whole subtree, which is what the transfer actually needs.
        names(rel; isdir = false) = any(x -> SW._rule_hits(x, rel; isdir), r)
        out(rel; isdir = false) = SW._ignored(r, rel, isdir, false)

        # the bug this testset exists for: a rule must name the very directory it is written about,
        # or the editor draws an unticked box over a rule that is doing its job
        @test names("assets"; isdir = true)
        @test names("sub/deep"; isdir = true)
        # a trailing slash means DIRECTORY, so a plain file of that name is untouched
        @test !names("assets"; isdir = false)
        @test !names("src"; isdir = true)
        # and the subtree still goes, which is the transfer's question rather than the tick's
        @test out("assets/big.bin")
        @test out("sub/deep/x")
        @test !out("src/main.jl")
    end
end

@testset "a remote path both expands ~ and stays one word" begin
    # These two requirements pull against each other, and for a long time only one was met: the
    # destination was single-quoted, so `~/.cache/…` was created as a directory literally NAMED `~`
    # beside the home directory. Julia on the far side resolved the same string against the real
    # home, so files were shipped to one path and looked for at another. Nothing reported it — the
    # transfer succeeded, and the copy was simply somewhere nobody read.
    @test SW.shq_path("~/.cache/kaimonslate/remote") == "\"\$HOME\"/'.cache/kaimonslate/remote'"
    # An absolute path is untouched, and still one word.
    @test SW.shq_path("/scratch/me/store") == "'/scratch/me/store'"
    @test SW.shq_path("/has space/x") == "'/has space/x'"
    # A `~` that is not a leading path component is a literal character in a name, not a home.
    @test SW.shq_path("/tmp/a~b") == "'/tmp/a~b'"
    @test SW.shq_path("~weird") == "'~weird'"
    # Quoting still defuses a quote in the tail, which is the reason `shq` exists at all.
    @test SW.shq_path("~/it's") == "\"\$HOME\"/'it'\\''s'"

    # And the property that matters, checked by actually running a shell rather than by reading the
    # string: the expansion happens, and a space does not split the word.
    if Sys.isunix()
        home = mktempdir()
        for (path, want) in (("~/one two", joinpath(home, "one two")),
                             ("~/.cache/x", joinpath(home, ".cache", "x")))
            out = readchomp(addenv(`sh -c $("printf '%s' " * SW.shq_path(path))`, "HOME" => home))
            @test out == want
        end
    end
end

# A mirror is not owned by one process. The hub and a notebook worker resolve the same cache home,
# so both sync the same directory — and the lock that was supposed to order them was a
# `ReentrantLock` in a process-local table, which orders the tasks in ONE process and nothing else.
# Two processes were measured entering it 18µs apart and both holding it for three seconds.
#
# The properties below are the ones that make a cross-process lock safe rather than a new way to
# hang: it is held across an ssh round trip, so every failure mode has to end in progress.
@testset "the store lock spans processes" begin
    @testset "a lock whose owner is gone is broken" begin
        m = mktempdir(); d = SW._lock_dir(m)
        mkdir(d); write(joinpath(d, "owner"), "999999 $(gethostname()) $(time())")
        t0 = time()
        @test SW.with_store_lock(m) do; :ran end === :ran
        @test time() - t0 < 5            # broken, not waited out
    end
    @testset "a lock older than any real sync is broken" begin
        # Even one whose pid is alive: a pid is reused, and 900s is far past any round trip.
        m = mktempdir(); d = SW._lock_dir(m)
        mkdir(d); write(joinpath(d, "owner"), "$(getpid()) $(gethostname()) $(time() - 100_000)")
        @test SW.with_store_lock(m) do; :ran end === :ran
    end
    @testset "nesting in one process does not deadlock on its own lock" begin
        m = mktempdir()
        @test SW.with_store_lock(m) do; SW.with_store_lock(m) do; :inner end end === :inner
    end
    @testset "a throw releases it" begin
        m = mktempdir()
        @test_throws ErrorException SW.with_store_lock(m) do; error("boom") end
        @test !isdir(SW._lock_dir(m))    # not leaked, or every later sync waits out the timeout
        @test SW.with_store_lock(m) do; :ran end === :ran
    end
end

# A pull must never delete what has not been pushed yet.
#
# The mirror is not only a copy of the store: local code writes into it and pushes afterwards. A
# pull that replaced `manifests/` wholesale removed anything written since the last push — certain
# loss, not a race — and it surfaced far away as "no sweep descriptor for key …" on a sweep that had
# just been created. It also handed the tar walk files that vanished underneath it.
@testset "a pull merges rather than replacing" begin
    @testset "the flags say so" begin
        # Stated on the function, because the wipe is what a future tidy-up would put back.
        for d in ("manifests", "status", "jobs", "blobs")
            @test SW.sync_flags(d, :in) == false
        end
        # Outbound is unchanged: `jobs/` is hub-owned, and deleting there is how disarming and
        # clearing attempts take effect.
        @test SW.sync_flags("jobs", :out)
        @test !SW.sync_flags("manifests", :out)
    end

    @testset "an unpushed manifest survives a pull" begin
        mktempdir() do mirror
            for d in ("manifests", "status", "jobs"); mkpath(joinpath(mirror, d)); end
            # What the store sends back: one manifest it knows about. Built OUTSIDE the mirror so
            # the fixture cannot contaminate what is being measured, and archived whole — a
            # predicate that matched only `manifests/…` would exclude the DIRECTORY entry and Tar
            # would never descend into it.
            data = mktempdir() do remote
                mkpath(joinpath(remote, "manifests"))
                MS.write_manifest(remote, "from_store", Dict("status" => "ok"))
                SW._archive(remote)
            end

            # What this side wrote and has NOT pushed. Before the fix, the pull deleted it.
            MS.write_manifest(mirror, "written_here", Dict("status" => "ok"))

            @test SW._unarchive(data, mirror)
            @test isfile(joinpath(mirror, "manifests", "written_here.toml"))   # survived
            @test isfile(joinpath(mirror, "manifests", "from_store.toml"))     # and the store's landed
        end
    end
end

@testset "a sync survives the store being written" begin
    # `put_blob` and `_atomic_write` stage a half-written file and rename it into place. That temp
    # file used to live in the directory being shipped, so a transfer running at the same time
    # walked it, stat'd it after it had been renamed away, and aborted the WHOLE sync with
    # "unsupported file type" — which surfaced far away, as a marker that never reached the store.
    @testset "temp files are not staged inside the shipped directories" begin
        mktempdir() do root
            MS.put_blob(root) do io; write(io, "hello"); end
            MS.write_manifest(root, "k", Dict("status" => "ok"))
            # Nothing that is not a blob may sit under blobs/; same for manifests/. `tempname`
            # writes `jl_…`, so the check is that only the known shapes are present.
            blobs = String[]
            for (r, _, fs) in walkdir(joinpath(root, "blobs")), f in fs
                push!(blobs, replace(relpath(joinpath(r, f), root), '\\' => '/'))
            end
            @test all(startswith(p, "blobs/sha256/") for p in blobs)
            mans = readdir(joinpath(root, "manifests"))
            @test all(endswith(f, ".toml") for f in mans)
        end
    end

    @testset "an entry that vanishes mid-walk does not abort the archive" begin
        mktempdir() do root
            write(joinpath(root, "real.txt"), "x")
            # A path that exists when the walk lists its parent and is gone when it is stat'd. A
            # dangling symlink stands in: it is what `lstat` reports for an entry mid-rename, and
            # unlike a race it is deterministic.
            gone = joinpath(root, "vanishing")
            try
                symlink(joinpath(root, "no-such-file"), gone)
            catch
                @test true                      # no symlink support (Windows without privilege)
                return
            end
            data = SW._archive(root)            # must not throw
            @test !isempty(data)
            mktempdir() do dest
                @test SW._unarchive(data, dest)
                @test isfile(joinpath(dest, "real.txt"))
            end
        end
    end
end
