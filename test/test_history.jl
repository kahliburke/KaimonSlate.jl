# Durable history store: dedup, diff-derived labels, content round-trip, restore.
# history.jl is self-contained (SHA + JSON), so include it directly.
using ReTest

include(joinpath(@__DIR__, "..", "src", "history.jl"))
using .SlateHistory
const H = SlateHistory

@testset "SlateHistory" begin
    H._ROOT[] = mktempdir()                      # isolate from the real ~/.cache store
    p = "/tmp/__slate_hist_test__.jl"

    @testset "record + dedup" begin
        e1 = H.record!(p, "a\n"; cells = [("a", "md", "a\n")])
        @test e1 !== nothing
        @test e1["seq"] == 1
        # identical content → no new entry, returns nothing
        @test H.record!(p, "a\n"; cells = [("a", "md", "a\n")]) === nothing
        @test length(H.entries(p)) == 1
    end

    @testset "diff-derived labels" begin
        H.record!(p, "a\nb\n"; cells = [("a", "md", "a\n"), ("b", "code", "b\n")])
        H.record!(p, "A\nb\n"; cells = [("a", "md", "A\n"), ("b", "code", "b\n")])
        H.record!(p, "A\n"; cells = [("a", "md", "A\n")])
        labels = [e["label"] for e in H.entries(p)]
        @test labels == ["initial", "added b", "edited a", "deleted b"]   # seed = "initial"
    end

    @testset "rename detection (id change, same content)" begin
        p2 = "/tmp/__slate_rename_test__.jl"
        H.record!(p2, "#%% code id=foo\nx\n"; cells = [("foo", "code", "x\n")])
        e = H.record!(p2, "#%% code id=bar\nx\n"; cells = [("bar", "code", "x\n")])
        @test e["label"] == "renamed foo → bar"                 # not "added bar; deleted foo"
        # a rename and an unrelated add are reported together
        e2 = H.record!(p2, "#%% code id=baz\nx\n\n#%% code id=c\ny\n";
                       cells = [("baz", "code", "x\n"), ("c", "code", "y\n")])
        @test e2["label"] == "renamed bar → baz; added c"
        # rename + content edit (hash changes) → honest fallback to add/delete
        e3 = H.record!(p2, "#%% code id=qux\nz\n\n#%% code id=c\ny\n";
                       cells = [("qux", "code", "z\n"), ("c", "code", "y\n")])
        @test e3["label"] == "added qux; deleted baz"
    end

    @testset "destructive overwrite reports adds AND deletes (not just adds)" begin
        q = "/tmp/__slate_hist_overwrite__.jl"
        H.record!(q, "x\n"; cells = [("x", "code", "x\n")])
        # A whole-notebook rewrite: drop x, add five new cells.
        H.record!(q, "n\n"; cells = [(string("c", i), "code", "$i\n") for i in 1:5])
        lab = H.entries(q)[end]["label"]
        @test occursin("added 5 cells", lab)        # summarized by count when many
        @test occursin("deleted x", lab)            # the deletion is NOT hidden
    end

    @testset "content round-trip + latest" begin
        es = H.entries(p)
        @test H.content(p, es[1]["hash"]) == "a\n"
        @test H.content(p, es[end]["hash"]) == "A\n"
        @test H.content(p, "deadbeef") === nothing
        @test H.latest_hash(p) == es[end]["hash"]
    end

    @testset "source + kind preserved" begin
        H.record!(p, "A\nq\n"; cells = [("a", "md", "A\n"), ("q", "code", "q\n")],
                  source_label = "agent", kind = "draft")
        e = H.entries(p)[end]
        @test e["source"] == "agent"
        @test e["kind"] == "draft"
    end

    @testset "parent chain is linear + append-only" begin
        es = H.entries(p)
        @test es[1]["parent"] === nothing
        for i in 2:length(es)
            @test es[i]["parent"] == es[i - 1]["hash"]
            @test es[i]["seq"] == i
        end
    end

    # The store no longer decides identity: the caller hands it a key, so a notebook that MOVES
    # keeps its history. `Doc(path)` remains the legacy path-derived identity, unchanged.
    @testset "caller-owned identity" begin
        @test H.Doc(p).key == H._key(p)                # legacy identity is still the path hash
        @test H.entries(H.Doc(p)) == H.entries(p)      # …and both call forms reach the same store

        a = H.Doc("doc-fixed", "/tmp/__slate_ident_a__.jl")
        H.record!(a, "x\n"; cells = [("x", "code", "x\n")])
        @test length(H.entries(a)) == 1

        # Same key at a different path = the same document, moved. Its history follows it.
        moved = H.Doc("doc-fixed", "/tmp/__slate_ident_b__.jl")
        H.record!(moved, "x\ny\n"; cells = [("x", "code", "x\n"), ("y", "code", "y\n")])
        @test length(H.entries(moved)) == 2
        @test H.latest_hash(moved) == H.latest_hash(a)         # one store, reached by either path
        @test H.known_paths(moved) ==                          # oldest first → head is the origin
              [abspath("/tmp/__slate_ident_a__.jl"), abspath("/tmp/__slate_ident_b__.jl")]

        # A different key is a different document, even at a path the store already knows.
        @test isempty(H.entries(H.Doc("doc-other", "/tmp/__slate_ident_a__.jl")))
    end

    @testset "relocate! moves a store onto a new key" begin
        from = H.Doc("reloc-old", "/tmp/__slate_reloc__.jl")
        H.record!(from, "q\n"; cells = [("q", "code", "q\n")])
        to = H.Doc("reloc-new", "/tmp/__slate_reloc__.jl")

        @test H.relocate!(from, to)
        @test length(H.entries(to)) == 1               # data arrived
        @test isempty(H.entries(from))                 # and the old key answers with nothing
        @test !H.relocate!(from, to)                   # idempotent: source gone → no-op

        occupied = H.Doc("reloc-taken", "/tmp/__slate_reloc2__.jl")
        H.record!(occupied, "z\n"; cells = [("z", "code", "z\n")])
        @test !H.relocate!(to, occupied)               # never clobbers an existing destination
        @test length(H.entries(occupied)) == 1
    end

    # A fork COPIES: the split keeps the lineage up to that point and the two diverge after, so
    # neither side loses anything.
    @testset "fork! copies the lineage" begin
        src = H.Doc("fork-src", "/tmp/__slate_fork_a__.jl")
        H.record!(src, "1\n"; cells = [("a", "code", "1\n")])
        H.record!(src, "2\n"; cells = [("a", "code", "2\n")])
        dst = H.Doc("fork-dst", "/tmp/__slate_fork_b__.jl")

        @test H.fork!(src, dst)
        @test length(H.entries(dst)) == 2                                   # lineage came along
        @test length(H.entries(src)) == 2                                   # original untouched
        @test H.known_paths(dst) == [abspath("/tmp/__slate_fork_b__.jl")]   # the copy owns its path

        H.record!(dst, "3\n"; cells = [("a", "code", "3\n")])
        @test (length(H.entries(dst)), length(H.entries(src))) == (3, 2)    # …and diverge from here
    end

    # "Don't ask again" is answered per PATH, not per document — one copy going quiet must not
    # silence the notice for the other.
    @testset "silence! is per path" begin
        one = H.Doc("quiet-doc", "/tmp/__slate_quiet_a__.jl")
        two = H.Doc("quiet-doc", "/tmp/__slate_quiet_b__.jl")
        H.record!(one, "s\n"; cells = [("s", "code", "s\n")])
        H.record!(two, "s\nt\n"; cells = [("s", "code", "s\n"), ("t", "code", "t\n")])
        @test isempty(H.quiet_paths(one))

        @test H.silence!(one)
        @test H.quiet_paths(two) == [abspath("/tmp/__slate_quiet_a__.jl")]   # only that path is quiet
        @test H.silence!(one)                                                # idempotent
        @test length(H.quiet_paths(one)) == 1
    end
end
