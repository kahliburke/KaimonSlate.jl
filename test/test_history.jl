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
        @test labels == ["added a", "added b", "edited a", "deleted b"]
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
