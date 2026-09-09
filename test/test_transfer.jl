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
