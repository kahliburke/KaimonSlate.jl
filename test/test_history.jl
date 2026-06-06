# Durable history store: dedup, diff-derived labels, content round-trip, restore.
# history.jl is self-contained (SHA + JSON), so include it directly.
using Test

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
end
