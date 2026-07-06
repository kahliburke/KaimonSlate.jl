# Publishing foundation (Phase 1): the XDG home resolver + one-time migration (SlateHome) and the
# publish ledger core + local store (PublishLedger). Pure/isolated — no hub, no `gh`, no network.
using ReTest
using KaimonSlate

const SH = KaimonSlate.SlateHome
const PL = KaimonSlate.PublishLedger

# Clear every KaimonSlate/XDG home var so a test starts from a known state, then apply overrides.
_clear() = Dict("KAIMONSLATE_HOME" => nothing, "KAIMONSLATE_CONFIG_HOME" => nothing,
                "KAIMONSLATE_DATA_HOME" => nothing, "KAIMONSLATE_CACHE_HOME" => nothing,
                "KAIMONSLATE_SITES_DIR" => nothing, "XDG_CONFIG_HOME" => nothing,
                "XDG_DATA_HOME" => nothing, "XDG_CACHE_HOME" => nothing)
_env(pairs...) = merge(_clear(), Dict(pairs...))

@testset "SlateHome — XDG home resolution" begin
    @testset "KAIMONSLATE_HOME shortcut → config/data/cache subdirs" begin
        withenv(_env("KAIMONSLATE_HOME" => "/tmp/ks")...) do
            @test SH.config_home() == "/tmp/ks/config"
            @test SH.data_home() == "/tmp/ks/data"
            @test SH.cache_home() == "/tmp/ks/cache"
            @test SH.sites_dir() == "/tmp/ks/cache/sites"          # under cache home by default
        end
    end

    @testset "per-home override beats KAIMONSLATE_HOME" begin
        withenv(_env("KAIMONSLATE_HOME" => "/tmp/ks",
                     "KAIMONSLATE_CONFIG_HOME" => "/elsewhere/cfg")...) do
            @test SH.config_home() == "/elsewhere/cfg"             # override wins
            @test SH.data_home() == "/tmp/ks/data"                 # others still from the shortcut
        end
    end

    @testset "XDG vars → kaimonslate namespace subdir" begin
        withenv(_env("XDG_CONFIG_HOME" => "/xc", "XDG_DATA_HOME" => "/xd",
                     "XDG_CACHE_HOME" => "/xk")...) do
            @test SH.config_home() == "/xc/kaimonslate"
            @test SH.data_home() == "/xd/kaimonslate"
            @test SH.cache_home() == "/xk/kaimonslate"
        end
    end

    @testset "defaults (all unset) → ~/.config|.local/share|.cache" begin
        withenv(_clear()...) do
            h = homedir()
            @test SH.config_home() == joinpath(h, ".config", "kaimonslate")
            @test SH.data_home() == joinpath(h, ".local", "share", "kaimonslate")
            @test SH.cache_home() == joinpath(h, ".cache", "kaimonslate")
        end
    end

    @testset "KAIMONSLATE_SITES_DIR is the most-specific sites override" begin
        withenv(_env("KAIMONSLATE_HOME" => "/tmp/ks", "KAIMONSLATE_SITES_DIR" => "/custom/sites")...) do
            @test SH.sites_dir() == "/custom/sites"
        end
    end

    @testset "named locations hang off the homes" begin
        withenv(_env("KAIMONSLATE_HOME" => "/tmp/ks")...) do
            @test SH.config_file() == "/tmp/ks/config/slate.json"
            @test SH.secrets_file() == "/tmp/ks/config/secrets.json"
            @test SH.ledger_dir() == "/tmp/ks/data/ledger"
        end
    end
end

@testset "PublishLedger — document identity" begin
    # git ids fold trailing .git/slash and separator differences to one canonical value
    a = PL.docid_git("notebooks/wg.jl", "https://github.com/u/Repo.git")
    b = PL.docid_git("notebooks/wg.jl", "https://github.com/u/Repo/")
    c = PL.docid_git("notebooks\\wg.jl", "https://github.com/u/Repo")
    @test a == b == c
    @test PL.docid_git("notebooks/other.jl", "https://github.com/u/Repo") != a
    @test length(a) == 40                                          # sha1 hex
    @test PL.docid_local("/abs/nb.jl") == PL.docid_local("/abs/nb.jl")
    @test PL.docid_local("/abs/nb.jl") != PL.docid_local("/abs/other.jl")
end

@testset "PublishLedger — record + JSON round-trip" begin
    l = PL.Ledger()
    l.targets["gh:portfolio"] = PL.Target("gh:portfolio", "github-pages";
        config = Dict("repo" => "u/portfolio", "branch" => "gh-pages"))
    l.sites["portfolio"] = PL.SiteGroup("portfolio"; target = "gh:portfolio", home = "home-doc")
    ev = PL.record_event!(l, "doc1", "gh:portfolio"; url = "https://x/", commit = "abc123")

    doc = l.documents["doc1"]
    @test ev.id != "" && ev.ts != "" && ev.status == "ok"          # auto id/ts, default status
    @test doc.targets == ["gh:portfolio"]                          # target auto-registered on the doc
    @test length(doc.events) == 1 && doc.events[1].url == "https://x/"

    round = PL.from_json(PL.to_json(l))
    rdoc = round.documents["doc1"]
    @test rdoc.events[1].id == ev.id && rdoc.events[1].commit == "abc123"
    @test round.targets["gh:portfolio"].kind == "github-pages"
    @test round.targets["gh:portfolio"].config["repo"] == "u/portfolio"
    @test round.sites["portfolio"].home == "home-doc"
    @test round.version == PL.LEDGER_VERSION
end

@testset "PublishLedger — union merge" begin
    a = PL.Ledger(); PL.record_event!(a, "d", "t"; id = "e1", note = "first")
    a.documents["d"].title = "Original"
    b = PL.Ledger(); PL.record_event!(b, "d", "t2"; id = "e2", note = "second")
    b.documents["d"].title = "Updated"; b.documents["d"].slug = ""   # empty slug must not blank existing

    PL.merge!(a, b)
    doc = a.documents["d"]
    @test Set(e.id for e in doc.events) == Set(["e1", "e2"])        # events unioned
    @test Set(doc.targets) == Set(["t", "t2"])                      # targets unioned
    @test doc.title == "Updated"                                   # last-writer for non-empty metadata

    # re-merging the same b adds nothing (idempotent on event ids)
    PL.merge!(a, b)
    @test length(a.documents["d"].events) == 2
end

@testset "PublishLedger — LocalStore load-merge-save" begin
    mktempdir() do tmp
        withenv(_env("KAIMONSLATE_DATA_HOME" => tmp)...) do
            store = PL.LocalStore()
            @test PL.locate(store) === nothing                     # nothing persisted yet
            @test isempty(PL.load(store).documents)                # empty ledger, not an error

            a = PL.Ledger(); PL.record_event!(a, "d", "t"; id = "e1")
            PL.save(store, a)
            @test PL.locate(store) !== nothing && isfile(store.path)

            # a second, independent writer's event must union in (not clobber e1)
            b = PL.Ledger(); PL.record_event!(b, "d", "t"; id = "e2")
            PL.save(store, b)

            reloaded = PL.load(store)
            @test Set(e.id for e in reloaded.documents["d"].events) == Set(["e1", "e2"])
        end
    end
end
