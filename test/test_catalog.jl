# Extension catalog — the data layer behind the Extensions gallery.
#
# The gallery has to open under every condition the network can produce: artifact reachable, cache
# only, nothing but the local registry clone. Those degradations are the point of the design, so
# they're what's asserted here. Nothing in this file touches the network — `fetch_catalog` is
# exercised through its cache, and the local fallback through the depot's real registries.
using ReTest
import JSON

include("../src/slate_home.jl")     # module SlateHome — the cache home the catalog writes under

# The catalog service layer reads `SlateHome`, `JSON`, `HTTP` and `Pkg` from its enclosing module.
# Pull the pure pieces in against a local stand-in rather than booting the whole server: these are
# the parse/merge/degrade decisions, and they don't need a running notebook.
module CatalogUnderTest
    using HTTP, JSON
    import Pkg
    import ..SlateHome
    # Stubs for the two things the service layer calls into that belong to the server proper.
    struct InProcessKernel end
    _notebook_adds(nb) = nb
    include("../src/server_catalog.jl")
end
const C = CatalogUnderTest

"Point every SlateHome home at a fresh tempdir for the duration of `f`."
function with_temp_home(f)
    dir = mktempdir()
    old = get(ENV, "KAIMONSLATE_HOME", nothing)
    ENV["KAIMONSLATE_HOME"] = dir
    try; f(dir); finally
        old === nothing ? delete!(ENV, "KAIMONSLATE_HOME") : (ENV["KAIMONSLATE_HOME"] = old)
        rm(dir; recursive = true, force = true)
    end
end

const GOOD = JSON.json(Dict("schema" => 1, "registry" => "SlateRegistry", "entries" => [
    Dict("name" => "StarRating", "title" => "Star Rating", "version" => "0.1.1",
         "tagline" => "A ★ rating control", "categories" => ["controls"],
         "snippet" => "using StarRating", "tier" => "rich"),
    Dict("name" => "GlobeSlate", "version" => "0.1.0", "description" => "3D charts.",
         "categories" => ["visualization"], "tier" => "described"),
]))

@testset "catalog document parsing" begin
    entries = C._parse_catalog(GOOD)
    @test entries !== nothing && length(entries) == 2
    @test entries[1]["name"] == "StarRating"

    # A catalog URL that 404s to a styled HTML page, or a truncated download, must NOT be cached as
    # if it were data — otherwise the gallery is poisoned until the TTL expires and the user sees an
    # empty list with no explanation.
    @test C._parse_catalog("<!DOCTYPE html><html><body>404</body></html>") === nothing
    @test C._parse_catalog("{\"schema\":1,\"entries\":") === nothing          # truncated
    @test C._parse_catalog("{\"schema\":1}") === nothing                      # no entries
    @test C._parse_catalog("{\"entries\":{}}") === nothing                    # entries not a list
    @test C._parse_catalog("{\"entries\":[{\"title\":\"no name\"}]}") === nothing
    @test C._parse_catalog("[]") === nothing                                  # not an object
    # JSON.jl parses objects into `JSON.Object`, not `Dict`. Accepting only `Dict` rejects every
    # real catalog while every negative case above still passes — so assert the concrete type the
    # parser actually produces, not just that valid input is accepted.
    @test JSON.parse(GOOD) isa AbstractDict
    @test !(JSON.parse(GOOD) isa Dict)
end

@testset "catalog: cache round-trip" begin
    with_temp_home() do _
        @test C._read_cached_catalog() === nothing        # nothing cached yet
        C._write_cache!(GOOD, "\"etag-1\"")
        @test C._read_etag() == "\"etag-1\""
        cached = C._read_cached_catalog()
        @test cached !== nothing && length(cached) == 2
        @test isfile(joinpath(C.catalog_cache_dir(), "catalog.json"))

        # A response with no ETag clears a stale one, so the next request doesn't send an
        # If-None-Match the server can't honour (which would 304 us onto bytes we no longer trust).
        C._write_cache!(GOOD, "")
        @test C._read_etag() == ""
    end
end

@testset "catalog: fetch degrades to cache without network" begin
    with_temp_home() do _
        # Unreachable URL + a warm cache ⇒ the cache is served and the failure is reported, not raised.
        withenv("KAIMONSLATE_CATALOG_URL" => "http://127.0.0.1:9/catalog.json") do
            C._write_cache!(GOOD, "")
            # Fresh cache: inside the TTL, so no request is even attempted.
            entries, meta = C.fetch_catalog()
            @test length(entries) == 2 && meta["source"] == "cache"

            # force=true attempts the network, fails, and still returns the cached entries.
            entries2, meta2 = C.fetch_catalog(; force = true)
            @test length(entries2) == 2
            @test meta2["source"] == "cache" && !isempty(get(meta2, "error", ""))
        end
    end
end

@testset "catalog: fetch degrades to the local registry with no cache at all" begin
    with_temp_home() do _
        withenv("KAIMONSLATE_CATALOG_URL" => "http://127.0.0.1:9/catalog.json") do
            entries, meta = C.fetch_catalog(; force = true)
            @test meta["source"] == "local"          # no artifact, no cache → the depot's registry
            @test !isempty(get(meta, "error", ""))
            # Whatever it found, it must be shaped like catalog entries — the gallery renders these.
            @test all(e -> haskey(e, "name") && haskey(e, "version"), entries)
        end
    end
end

@testset "catalog: local registry fallback" begin
    # Against a registry name that cannot exist, the fallback is empty rather than an error — an
    # unknown registry is a configuration state, not a crash.
    withenv("KAIMONSLATE_CATALOG_REGISTRY" => "NoSuchRegistry-$(rand(UInt32))") do
        @test isempty(C.local_registry_entries())
        @test C.catalog_registry_installed() == false
    end
    # The real one, if this machine has it installed: entries must be installable-shaped.
    if C.catalog_registry_installed()
        es = C.local_registry_entries()
        @test !isempty(es)
        @test all(e -> !isempty(e["name"]) && haskey(e, "uuid") && e["tier"] == "bare", es)
        @test issorted([lowercase(e["name"]) for e in es])
    end
end

@testset "catalog: configuration overrides" begin
    withenv("KAIMONSLATE_CATALOG_URL" => "https://example.test/c.json",
            "KAIMONSLATE_CATALOG_REGISTRY" => "MyRegistry",
            "KAIMONSLATE_CATALOG_REGISTRY_URL" => "https://example.test/reg") do
        @test C.catalog_url() == "https://example.test/c.json"
        @test C.catalog_registry_name() == "MyRegistry"
        @test C.catalog_registry_url() == "https://example.test/reg"

        # slate.json wins over the env var (same precedence as the "remote" block).
        C._CATALOG_CFG[] = Dict{String,Any}("url" => "https://cfg.test/c.json")
        @test C.catalog_url() == "https://cfg.test/c.json"
        @test C.catalog_registry_name() == "MyRegistry"          # unset key falls through to env
        # An empty or non-string config value is ignored rather than blanking the setting.
        C._CATALOG_CFG[] = Dict{String,Any}("url" => "", "registry" => 42)
        @test C.catalog_url() == "https://example.test/c.json"
        @test C.catalog_registry_name() == "MyRegistry"
        C._CATALOG_CFG[] = Dict{String,Any}()
    end
    # Defaults point at the curated registry.
    @test occursin("SlateRegistry", C.catalog_registry_url())
    @test endswith(C.catalog_url(), ".json")
end

@testset "catalog: gallery view annotates install state" begin
    # `catalog_view` joins the catalog against the notebook's env. The stub `_notebook_adds` returns
    # the notebook itself, so a NamedTuple stands in for a LiveNotebook's env probe.
    nb = (adds   = [Dict("name" => "StarRating", "version" => "0.1.1")],
          parent = [Dict("name" => "GlobeSlate", "version" => "0.1.0")],
          detached = false, parentpath = "", kernel = nothing)
    with_temp_home() do _
        withenv("KAIMONSLATE_CATALOG_URL" => "http://127.0.0.1:9/catalog.json") do
            C._write_cache!(GOOD, "")
            v = C.catalog_view(nb)
            star  = only(filter(e -> e["name"] == "StarRating", v["entries"]))
            globe = only(filter(e -> e["name"] == "GlobeSlate", v["entries"]))
            @test star["installed"] && star["installedVersion"] == "0.1.1"
            # A package inherited from the parent project is present but not a notebook add — the
            # gallery must not offer to install it again, so both flags are reported separately.
            @test !globe["installed"] && globe["inParent"] && globe["installedVersion"] == "0.1.0"
            # Categories are collected across entries for the filter chips.
            @test v["categories"] == ["controls", "visualization"]
            @test haskey(v, "registryInstalled") && haskey(v, "manageable")
        end
    end
end

@testset "catalog: version drift" begin
    @test C._is_older("0.1.0", "0.1.1")
    @test C._is_older("0.1.0", "0.2.0")
    @test !C._is_older("0.1.1", "0.1.1")
    @test !C._is_older("0.2.0", "0.1.1")            # ahead of the registry (a local build) is not stale
    # A dev checkout reports no version. Offering to "update" it would replace the user's working
    # copy with a registry release, so an unparseable pair is never reported as out of date.
    @test !C._is_older("", "0.1.1")
    @test !C._is_older("0.1.0", "")
    @test !C._is_older("main", "0.1.1")
    @test C._is_older("0.1.0-dev", "0.1.0")         # prereleases still compare
end

@testset "catalog: gallery flags updatable entries" begin
    nb = (adds   = [Dict("name" => "StarRating", "version" => "0.1.0")],   # registry has 0.1.1
          parent = [Dict("name" => "GlobeSlate", "version" => "0.0.9")],   # registry has 0.1.0
          detached = false, parentpath = "", kernel = nothing)
    with_temp_home() do _
        withenv("KAIMONSLATE_CATALOG_URL" => "http://127.0.0.1:9/catalog.json") do
            C._write_cache!(GOOD, "")
            v = C.catalog_view(nb)
            star  = only(filter(e -> e["name"] == "StarRating", v["entries"]))
            globe = only(filter(e -> e["name"] == "GlobeSlate", v["entries"]))
            @test star["installed"] && star["updatable"]
            # Drift is reported for an inherited package too — it's just updated in the parent.
            @test globe["inParent"] && globe["updatable"]
            @test v["installedCount"] == 2 && v["updatableCount"] == 2
        end
    end
end

@testset "catalog: asset urls resolve against the catalog url" begin
    # The build mirrors imagery into the artifact as artifact-relative paths. Left alone the browser
    # resolves those against the NOTEBOOK's origin and 404s every card.
    withenv("KAIMONSLATE_CATALOG_URL" => "https://example.test/reg/catalog.json") do
        es = C._resolve_asset_urls!(Any[Dict{String,Any}(
            "name" => "P", "screenshots" => ["assets/P/a.png", "https://cdn.test/b.png"],
            "video" => "assets/P/v.webm", "icon" => "★")])
        @test es[1]["screenshots"] == ["https://example.test/reg/assets/P/a.png", "https://cdn.test/b.png"]
        @test es[1]["video"] == "https://example.test/reg/assets/P/v.webm"
        @test es[1]["icon"] == "★"                  # an emoji is not a path
    end
end

@testset "catalog: registry identity uses fields Pkg actually has" begin
    # `RegistryInstance` has `repo`, not `url`. Reading `r.url` throws a FieldError, which surfaced
    # as "could not add the SlateRegistry registry" — and ONLY on a machine that doesn't already
    # have it, i.e. the only machine the add path ever runs on. A test that mocks the registry type
    # would not have caught it, so this asserts against the real Pkg API.
    import Pkg
    r = first(Pkg.Registry.reachable_registries())
    @test hasfield(typeof(r), :repo)
    @test !hasfield(typeof(r), :url)

    # The comparison tolerates the spellings a user actually pastes.
    same = C._same_registry
    fake = (name = "X", repo = "https://github.com/o/R.git")
    @test same(fake, "https://github.com/o/R")
    @test same(fake, "https://github.com/o/R.git")
    @test same(fake, "https://github.com/o/R/")
    @test !same(fake, "https://github.com/o/Other")
    # A registry with no repo recorded must not match everything.
    @test !same((name = "Y", repo = ""), "https://github.com/o/R")
end

@testset "catalog: install and update refuse an empty name" begin
    @test C.catalog_install!(nothing, "  ")["ok"] == false
    @test C.catalog_update!(nothing, "")["ok"] == false
end
