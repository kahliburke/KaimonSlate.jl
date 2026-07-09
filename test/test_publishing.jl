# Publishing foundation (Phase 1): the XDG home resolver + one-time migration (SlateHome) and the
# publish ledger core + local store (PublishLedger). Pure/isolated — no hub, no `gh`, no network.
using ReTest
using KaimonSlate

const SH = KaimonSlate.SlateHome
const PL = KaimonSlate.PublishLedger
const NS = KaimonSlate.NotebookServer

# Clear every KaimonSlate/XDG home var so a test starts from a known state, then apply overrides.
# FORCE the local ledger backend: default_store() picks a GistStore when `gh` is authenticated,
# and a gist is keyed by GitHub identity — it ignores KAIMONSLATE_HOME, so tests that mutate via
# the NS.publish_* helpers would share (and pollute) the developer's REAL publish gist and leak
# state across testsets. "local" gives each test its own on-disk ledger under its temp home.
_clear() = Dict("KAIMONSLATE_HOME" => nothing, "KAIMONSLATE_CONFIG_HOME" => nothing,
                "KAIMONSLATE_DATA_HOME" => nothing, "KAIMONSLATE_CACHE_HOME" => nothing,
                "KAIMONSLATE_SITES_DIR" => nothing, "XDG_CONFIG_HOME" => nothing,
                "XDG_DATA_HOME" => nothing, "XDG_CACHE_HOME" => nothing,
                "KAIMONSLATE_LEDGER_BACKEND" => "local")
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

    @testset "config edits + deletes survive a save (local-authoritative)" begin
        mktempdir() do tmp
            withenv(_env("KAIMONSLATE_DATA_HOME" => tmp)...) do
                store = PL.LocalStore()
                l = PL.Ledger()
                l.targets["a"] = PL.Target("a", "github-pages"; config = Dict("repo" => "u/a"))
                l.targets["b"] = PL.Target("b", "s3"; config = Dict("dest" => "s3://x"))
                PL.save(store, l)

                # reload, delete target "b" and edit "a", save again
                l2 = PL.load(store)
                delete!(l2.targets, "b")
                l2.targets["a"].config["repo"] = "u/a2"
                PL.save(store, l2)

                back = PL.load(store)
                @test !haskey(back.targets, "b")                   # delete stuck (not resurrected by merge)
                @test back.targets["a"].config["repo"] == "u/a2"   # edit stuck (last-writer)
            end
        end
    end
end

# In-memory GistClient standing in for `gh` — models a shared set of gists two "machines" write to.
mutable struct FakeGist
    id::String
    desc::String
    files::Dict{String,String}
end
mutable struct FakeGh <: PL.GistClient
    gists::Vector{FakeGist}
    next::Int
    creates::Int          # how many gists were created (double-create detector)
end
FakeGh() = FakeGh(FakeGist[], 1, 0)

PL.gist_list(c::FakeGh) = Tuple{String,String}[(g.id, g.desc) for g in c.gists]
PL.gist_read(c::FakeGh, id, filename) =
    (i = findfirst(g -> g.id == id, c.gists); i === nothing ? nothing : get(c.gists[i].files, filename, nothing))
function PL.gist_create(c::FakeGh, desc, filename, content)
    id = "gist$(c.next)"; c.next += 1; c.creates += 1
    push!(c.gists, FakeGist(id, String(desc), Dict(String(filename) => String(content))))
    return id
end
function PL.gist_update(c::FakeGh, id, filename, content)
    i = findfirst(g -> g.id == id, c.gists); i === nothing && error("no gist $id")
    c.gists[i].files[String(filename)] = String(content); return nothing
end

@testset "PublishLedger — gist backend (self-location)" begin
    @testset "create-on-first-write, then cache the pointer" begin
        mktempdir() do tmp
            gh = FakeGh(); ptr = joinpath(tmp, "pointer.json")
            s = PL.GistStore(; client = gh, pointer_file = ptr)
            @test PL.locate(s) === nothing                         # nothing exists yet
            a = PL.Ledger(); PL.record_event!(a, "d", "t"; id = "e1")
            PL.save(s, a)
            @test gh.creates == 1                                  # exactly one gist created
            @test isfile(ptr)                                      # pointer cached to disk
            @test length(gh.gists) == 1 && gh.gists[1].desc == PL.GIST_MARKER
        end
    end

    @testset "fresh machine self-locates via the marker (no double-create)" begin
        mktempdir() do tmp
            gh = FakeGh()
            m1 = PL.GistStore(; client = gh, pointer_file = joinpath(tmp, "p1.json"))
            a = PL.Ledger(); PL.record_event!(a, "d", "t"; id = "e1"); PL.save(m1, a)

            # second machine: SAME GitHub (shared `gh`), but no local pointer cache
            m2 = PL.GistStore(; client = gh, pointer_file = joinpath(tmp, "p2.json"))
            @test PL.locate(m2) == gh.gists[1].id                  # found by marker, not created
            b = PL.Ledger(); PL.record_event!(b, "d", "t"; id = "e2"); PL.save(m2, b)
            @test gh.creates == 1                                  # list-first prevented a fork

            # the shared gist now carries both machines' events (union merge)
            @test Set(e.id for e in PL.load(m1).documents["d"].events) == Set(["e1", "e2"])
        end
    end
end

# A deploy adapter with scripted behaviour — no gh/aws/network.
struct FakeTarget <: NS.PublishTarget
    name::String
    behavior::Symbol      # :ok | :fail | :throw
end
function NS.publish(t::FakeTarget, nb; kwargs...)
    t.behavior === :throw && error("boom-$(t.name)")
    ok = t.behavior === :ok
    return NS.PublishResult(; ok = ok, url = "https://x/$(t.name)", commit = "c_$(t.name)",
                            status = ok ? "ok" : "failure", log = ok ? "" : "failed-$(t.name)")
end

@testset "PublishTargets — fan-out, isolation, events" begin
    @testset "publish_to_targets preserves order + isolates failures" begin
        targets = NS.PublishTarget[FakeTarget("a", :ok), FakeTarget("b", :throw), FakeTarget("c", :fail)]
        seq = Tuple{Int,Symbol}[]
        results = NS.publish_to_targets(nothing, targets; on_event = (i, ph, _) -> push!(seq, (i, ph)))
        @test [r.ok for r in results] == [true, false, false]      # order preserved, siblings survive a throw
        @test results[1].url == "https://x/a" && results[1].commit == "c_a"
        @test occursin("boom-b", results[2].log)                   # thrown error captured, not propagated
        @test Set(seq) == Set([(i, ph) for i in 1:3 for ph in (:start, :done)])  # start+done per target
    end

    @testset "_record_results! appends one event per target" begin
        led = PL.Ledger()
        res = [NS.PublishResult(; ok = true, url = "u1", commit = "c1", status = "ok"),
               NS.PublishResult(; ok = false, status = "failure", log = "first line\nsecond line")]
        NS._record_results!(led, "doc", ["t1", "t2"], res)
        evs = led.documents["doc"].events
        @test length(evs) == 2 && Set(led.documents["doc"].targets) == Set(["t1", "t2"])
        @test evs[1].target == "t1" && evs[1].url == "u1" && evs[1].commit == "c1" && evs[1].note == ""
        @test evs[2].status == "failure" && evs[2].note == "first line"   # note = first log line
    end
end

@testset "PublishTargets — ledger config → adapter" begin
    gt = NS.target_from_ledger(PL.Target("gh:p", "github-pages";
        config = Dict("repo" => "u/r", "subdir" => "sub", "private" => true)))
    @test gt isa NS.GithubPagesTarget && gt.repo == "u/r" && gt.subdir == "sub"
    @test gt.branch == "gh-pages" && gt.private && gt.create

    s3 = NS.target_from_ledger(PL.Target("r2:x", "r2";
        config = Dict("dest" => "s3://bucket/p", "endpoint" => "https://ep", "url" => "https://cdn/")))
    @test s3 isa NS.GenericUploadTarget && s3.kind === :s3 && s3.endpoint == "https://ep"

    rs = NS.target_from_ledger(PL.Target("rs", "rsync"; config = Dict("dest" => "host:/var/www")))
    @test rs.kind === :rsync && rs.dest == "host:/var/www"

    # rsync-serve: rsync + a self-hosted Julia static server on the destination host
    sv = NS.target_from_ledger(PL.Target("factorio", "rsync-serve";
        config = Dict("dest" => "u@h:/srv/site", "url" => "http://h:8080/", "bind" => "0.0.0.0", "port" => "9090")))
    @test sv isa NS.RsyncServeTarget && sv.dest == "u@h:/srv/site" && sv.bind == "0.0.0.0"
    @test sv.port == 9090 && sv.delete                              # string port coerced; delete defaults on
    @test NS._split_ssh_dest("u@h:/p") == ("u@h", "/p")
    @test NS._split_ssh_dest("/no-colon") == ("", "/no-colon")
    @test !NS.preflight(NS.RsyncServeTarget(; name = "x", dest = "/no-colon", port = 99999)).ok
    @test "rsync-serve" in NS._TARGET_KINDS

    @test_throws ErrorException NS.target_from_ledger(PL.Target("z", "totally-unknown-kind"))

    # preflight surfaces missing config without touching the network
    @test !NS.preflight(NS.GenericUploadTarget(; name = "x", kind = :s3, dest = "")).ok
    @test NS.preflight(NS.GenericUploadTarget(; name = "x", kind = :bogus, dest = "s3://b")).ok == false

    # zenodo target resolves its token from the secrets provider (never stored in the ledger)
    zt = NS.target_from_ledger(PL.Target("z", "zenodo"; config = Dict("secretRef" => "zenodo-token"));
                               secrets = Dict("zenodo-token" => "TKN"))
    @test zt isa NS.ZenodoTarget && zt.client.token == "TKN"
end

# In-memory Zenodo API — routes the 4-step deposition flow and records what happened.
mutable struct FakeZenodo <: NS.ZenodoClient
    calls::Vector{Tuple{String,String}}
    uploaded::Vector{String}
    metadata::Dict{String,Any}
    published::Bool
    newversioned::Bool
end
FakeZenodo() = FakeZenodo(Tuple{String,String}[], String[], Dict{String,Any}(), false, false)
function NS.zenodo_request(c::FakeZenodo, method, url; json = nothing, file = nothing)
    push!(c.calls, (String(method), String(url)))
    if method == "POST" && url == "/deposit/depositions"
        return (201, Dict("id" => 111, "links" => Dict("bucket" => "https://z/bucket/111")))
    elseif method == "POST" && endswith(url, "/actions/newversion")
        occursin("depositions/111/", url) || return (404, Dict("message" => "no such deposition"))
        c.newversioned = true
        return (201, Dict("links" => Dict("latest_draft" => "https://z/api/deposit/depositions/222")))
    elseif method == "GET" && occursin("depositions/222", url)
        return (200, Dict("id" => 222, "links" => Dict("bucket" => "https://z/bucket/222")))
    elseif method == "PUT" && occursin("/bucket/", url)
        push!(c.uploaded, String(url))
        return (201, Dict("key" => basename(String(url))))
    elseif method == "PUT" && occursin("/deposit/depositions/", url)
        c.metadata = Dict{String,Any}(json["metadata"])
        return (200, Dict("id" => 111))
    elseif method == "POST" && endswith(url, "/actions/publish")
        c.published = true
        return (202, Dict("doi" => "10.5281/zenodo.111",
                          "links" => Dict("record_html" => "https://zenodo.org/record/111")))
    end
    return (404, Dict("message" => "unmocked $method $url"))
end

@testset "Publish service — secrets, targets, view" begin
    # Force the local backend + point all homes at a tempdir so nothing touches the network or real state.
    mktempdir() do tmp
        withenv(_env("KAIMONSLATE_LEDGER_BACKEND" => "local", "KAIMONSLATE_DATA_HOME" => tmp,
                     "KAIMONSLATE_CONFIG_HOME" => joinpath(tmp, "cfg"))...) do
            @testset "secret store keeps values out of the ledger" begin
                @test NS.secret_refs() == String[]
                NS.publish_secret_set!("zenodo-token", "SEKRET")
                @test NS.secret_refs() == ["zenodo-token"]
                @test NS._secrets_load()["zenodo-token"] == "SEKRET"   # value lives only in the config home
                NS.publish_secret_set!("zenodo-token", "")             # empty ⇒ delete
                @test NS.secret_refs() == String[]
            end

            @testset "target add/delete + ledger view shape" begin
                NS.publish_target_set!("gh:site", "github-pages", Dict("repo" => "me/site"))
                NS.publish_target_set!("arch", "zenodo", Dict("secretRef" => "zenodo-token"))
                view = NS.publish_ledger_view()
                @test view["backend"] == "local"
                @test Set(t["name"] for t in view["targets"]) == Set(["gh:site", "arch"])
                @test "github-pages" in view["availableKinds"] && "zenodo" in view["availableKinds"]

                NS.publish_target_delete!("arch")
                @test Set(t["name"] for t in NS.publish_ledger_view()["targets"]) == Set(["gh:site"])
            end
        end
    end
end

@testset "Publish service — repo slug parsing" begin
    @test NS._repo_slug("https://github.com/me/Repo.git") == "me/Repo"
    @test NS._repo_slug("git@github.com:me/Repo.git") == "me/Repo"
    @test NS._repo_slug("https://github.com/me/Repo/") == "me/Repo"
    @test NS._repo_slug("not a url") == ""
end

@testset "Zenodo — deposition flow" begin
    mktempdir() do tmp
        file = joinpath(tmp, "nb.jl"); write(file, "# bundle")
        meta = Dict{String,Any}("upload_type" => "software", "title" => "WG", "creators" => [Dict("name" => "K")])

        @testset "fresh record mints a DOI + returns depositionId" begin
            c = FakeZenodo()
            r = NS._zenodo_deposit(c, "", file, meta)
            @test r.ok && r.doi == "10.5281/zenodo.111"
            @test r.url == "https://zenodo.org/record/111"
            @test r.meta["depositionId"] == "111"                  # persisted back for next-version
            @test c.uploaded == ["https://z/bucket/111/nb.jl"] && c.published
            @test c.metadata["title"] == "WG"                      # metadata was set before publish
            @test !c.newversioned                                  # fresh record, not a new version
        end

        @testset "existing concept → new version" begin
            c = FakeZenodo()
            r = NS._zenodo_deposit(c, "111", file, meta)
            @test r.ok && r.meta["depositionId"] == "222" && c.newversioned
            @test c.uploaded == ["https://z/bucket/222/nb.jl"]     # uploaded into the new draft's bucket
        end

        @testset "an HTTP error aborts cleanly (no publish)" begin
            c = FakeZenodo()
            r = NS._zenodo_deposit(c, "", file, Dict{String,Any}())   # empty metadata → still fine here
            @test r.ok                                            # sanity: happy path
            # force a failure by pointing at an unmocked deposition id
            r2 = NS._zenodo_deposit(c, "999", file, meta)
            @test !r2.ok && occursin("Zenodo HTTP", r2.log) && !endswith(last(c.calls)[2], "/actions/publish")
        end
    end
end

@testset "publish vs archive are different verbs" begin
    mktempdir() do tmp
        withenv(_env("KAIMONSLATE_HOME" => tmp)...) do
            @test NS._is_archive_kind("zenodo")
            @test !NS._is_archive_kind("github-pages")
            @test !NS._is_archive_kind("rsync")
            NS.publish_target_set!("site", "github-pages", Dict{String,Any}("repo" => "u/r"))
            NS.publish_target_set!("doi", "zenodo", Dict{String,Any}("secretRef" => "tok"))
            @test NS.archive_target_names() == ["doi"]
            led = KaimonSlate.PublishLedger.load(KaimonSlate.PublishLedger.default_store())
            # a site publish may not carry an archive along (would mint an immutable DOI)
            @test NS._verb_mismatch(led, ["site"], false) === nothing
            @test occursin("permanent", NS._verb_mismatch(led, ["site", "doi"], false))
            @test occursin("slate.archive", NS._verb_mismatch(led, ["doi"], false))
            # an archive run deposits to archive kinds only
            @test NS._verb_mismatch(led, ["doi"], true) === nothing
            @test occursin("not archive target", NS._verb_mismatch(led, ["doi", "site"], true))
        end
    end
end

@testset "sites: titles, removal hygiene, purge plumbing" begin
    mktempdir() do tmp
        withenv(_env("KAIMONSLATE_HOME" => tmp, "KAIMONSLATE_SITES_DIR" => joinpath(tmp, "sites"))...) do
            NS.publish_target_set!("gh", "github-pages", Dict{String,Any}("repo" => "u/r"))
            NS.publish_site_set!("stat-mech", ["gh"], "", "Stat Mech")
            led = PL.load(PL.default_store())
            s = led.sites["stat-mech"]
            @test s.title == "Stat Mech" && s.targets == ["gh"] && s.home == ""
            PL.save(PL.default_store(), led)                       # title survives the JSON round-trip
            @test PL.load(PL.default_store()).sites["stat-mech"].title == "Stat Mech"
            NS.publish_site_set!("blog", String[])                 # untitled → "" (build falls back to the name)
            @test PL.load(PL.default_store()).sites["blog"].title == ""
            v = NS.publish_ledger_view()                           # the manager view carries the title
            sv = [x for x in v["sites"] if x["name"] == "stat-mech"][1]
            @test sv["title"] == "Stat Mech"

            # deleting a target detaches it from sites — no dangling destination refs
            NS.publish_target_delete!("gh")
            @test PL.load(PL.default_store()).sites["stat-mech"].targets == String[]

            # deleting a site removes the definition AND its local canonical build
            dir = NS._site_dir("stat-mech")
            mkpath(dir); write(joinpath(dir, "index.html"), "x")
            NS.publish_site_delete!("stat-mech")
            @test !haskey(PL.load(PL.default_store()).sites, "stat-mech")
            @test !isdir(dir)

            # purge: generic kinds are a documented no-op (only self-hosted kinds can undeploy)
            r = NS.purge_deployed!(NS.GenericUploadTarget(; name = "x", kind = :s3, dest = "s3://b"))
            @test !r.ok && occursin("purge isn't supported", r.log)
        end
    end
end

@testset "site subpaths within a target" begin
    mktempdir() do tmp
        withenv(_env("KAIMONSLATE_HOME" => tmp, "KAIMONSLATE_SITES_DIR" => joinpath(tmp, "sites"))...) do
            NS.publish_target_set!("bucket", "s3", Dict{String,Any}("dest" => "s3://b", "url" => "https://cdn/"))
            NS.publish_target_set!("gh", "github-pages", Dict{String,Any}("repo" => "u/r"))
            NS.publish_target_set!("cf", "cloudflare-pages", Dict{String,Any}("project" => "p"))

            # paths persist + round-trip
            NS.publish_site_set!("stat", ["bucket"], "", "Stat"; paths = Dict("bucket" => "stat-mech"))
            led = PL.load(PL.default_store())
            @test led.sites["stat"].paths == Dict("bucket" => "stat-mech")
            PL.save(PL.default_store(), led)
            @test PL.load(PL.default_store()).sites["stat"].paths["bucket"] == "stat-mech"

            # a DIFFERENT subpath on the same target is fine; the SAME location clashes
            NS.publish_site_set!("blog", ["bucket"], "", ""; paths = Dict("bucket" => "blog"))
            @test_throws ErrorException NS.publish_site_set!("dup", ["bucket"]; paths = Dict("bucket" => "blog"))
            # root vs subpath don't clash; two roots on one target DO
            NS.publish_site_set!("root1", ["gh"])
            @test_throws ErrorException NS.publish_site_set!("root2", ["gh"])
            # re-saving the SAME site to its own location is allowed (not a self-clash)
            NS.publish_site_set!("stat", ["bucket"], "", "Stat 2"; paths = Dict("bucket" => "stat-mech"))

            # with_subpath transforms path-based adapters; root-only kinds error
            s3 = NS.target_from_ledger(led.targets["bucket"])
            sub = NS.with_subpath(s3, "stat-mech")
            @test sub.dest == "s3://b/stat-mech" && sub.url == "https://cdn/stat-mech/"
            @test NS.with_subpath(s3, "") === s3                       # empty subpath = identity
            gh = NS.with_subpath(NS.target_from_ledger(led.targets["gh"]), "blog")
            @test gh.subdir == "blog"
            @test_throws ErrorException NS.with_subpath(NS.target_from_ledger(led.targets["cf"]), "x")
        end
    end
end
