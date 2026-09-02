# The Slate notebook-API registry (`src/slate_api.jl`) and the surfaces it renders: the `slate.api`
# index, drill-down and lookup, plus the DRIFT GUARD that keeps the registry honest.
#
# The drift guard is the point of this file. Everything else in Slate can be discovered by reading
# code; the notebook API cannot — an agent only ever learns a helper EXISTS from this registry, so a
# helper injected into the cell namespace without an entry is invisible no matter how well it works.
# That is not hypothetical: web cells, the JS bridge (`slate_on`/`slate_call`) and `save_asset` all
# shipped and stayed undiscoverable until this test was written.
using ReTest
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

# Names injected into a cell namespace that are deliberately NOT part of the documented API:
# internals (double-underscore plumbing), types a user never constructs by hand, and aliases whose
# documented spelling differs. Anything else MUST have a registry entry — add the entry, or add the
# name here with a reason.
const UNDOCUMENTED_BY_DESIGN = Dict(
    "EChart"      => "the type `echart(…)` returns; users call the constructor function, not this",
    "SlateTable"  => "ditto for `slate_table(…)`",
    "Widget"      => "abstract supertype of the widget constructors",
    "Choice"      => "wrapper for a labeled Select/Radio value; reached via the bound variable",
    "Selection"   => "ditto for multi-selects",
    "indices"     => "helper on a Selection value, documented with the widgets that produce it",
    "Reactive"    => "the type `reactive(…)` returns",
    "slate_off"   => "documented inside the `slate_on` entry (its symmetric counterpart)",
    "slate_call"  => "documented inside the `slate_on` entry (the in-process invoke)",
    "slate_everywhere" => "documented inside the `slate_effect` entry",
    "use_slate_theme!" => "has its own entry",           # kept explicit: both theme names are documented
    "html_str"    => "the `html\"…\"` section macro of a web cell — documented in the `web cell` entry",
    "css_str"     => "ditto",
    "js_str"      => "ditto",
    "web"         => "the `@web` skin — documented as `web cell`",
    "md"          => "the `@md` skin — documented as `markdown`",
    "slate_render_fence" => "emitted by the ```lang fence desugaring, never written by hand — the fence syntax itself is the documented surface (`markdown` entry)",
    "sfile"       => "documented inside the `datadir` entry",
    "bind"        => "documented as `@bind`",
    "trace"       => "documented as `@trace`",
    "asset"       => "documented as `@asset`",
    "use"         => "documented as `@use`",
    "reactive"    => "documented as `reactive` (the macro shares the entry with the function)",
    "onclick"     => "documented as `@onclick`",
    "onchange"    => "documented as `@onchange`",
)

# Every name a cell can see, from the ONE place they are injected — a fresh standalone namespace is
# exactly the contract `_populate_notebook_ns!` installs. Filtered to the helpers: internals start
# with `__`, and a module's own name plus Base's `eval`/`include` come free with any module.
#
# `names` MUST go through `invokelatest`: the helpers are installed with `Core.eval` during this same
# call, so on Julia ≥1.12 they belong to a NEWER world age than this frame — a direct `names(m)` then
# reports an empty module (while `isdefined` still finds each binding) and the drift check silently
# passes on nothing. The `length(inj)` floor below is the backstop if this ever regresses again.
function injected_names()
    m = Module(:DriftProbe)
    RE.standalone!(m; dir = mktempdir())
    skip = (:eval, :include, :__slate_standalone, nameof(m))
    return String[String(n) for n in Base.invokelatest(names, m; all = true)
                  if !startswith(String(n), "__") && !(n in skip) && !startswith(String(n), "#")]
end

# Stands in for `KaimonGate.GateTool` so `create_tools` can be built without Kaimon loaded. The
# handlers reach the gate through `parentmodule(GateTool)`, so the caller/agent accessors live here.
module StubGate
struct GateTool
    name::String
    handler::Function
    timeout_ms::Union{Nothing,Int}
end
# Mirrors KaimonGate's constructor — `create_tools` declares a silence budget on the tools that
# block silently. There is no caller-facing override by design.
GateTool(name::AbstractString, handler::Function;
         timeout_ms::Union{Nothing,Integer} = nothing) =
    GateTool(String(name), handler, timeout_ms === nothing ? nothing : Int(timeout_ms))
current_caller() = nothing
current_agent_id() = nothing
end

@testset "slate api registry" begin
    @testset "no undocumented cell helper (drift guard)" begin
        inj = injected_names()
        # Guard the guard: if `standalone!` ever stops populating the probe module (or `names` stops
        # reporting what it injects), the drift check would PASS vacuously — which is the one failure
        # mode a coverage test must not have. Pin a floor and a few known-injected helpers.
        @test length(inj) > 40
        @test all(n -> any(x -> lstrip(x, '@') == n, inj), ["echart", "bind", "slate_table", "web", "save_asset"])

        documented = Set(lowercase(lstrip(e.name, '@')) for e in NS.SLATE_API)
        allowed = Set(lowercase(lstrip(k, '@')) for k in keys(UNDOCUMENTED_BY_DESIGN))
        missing_docs = [n for n in inj
                        if !(lowercase(lstrip(n, '@')) in documented) &&
                           !(lowercase(lstrip(n, '@')) in allowed)]
        # One assertion carrying the whole list, so a failure names every gap at once rather than
        # stopping at the first.
        @test isempty(missing_docs) ||
              error("cell helpers injected but NOT in SLATE_API (document them in src/slate_api.jl, " *
                    "or add them to UNDOCUMENTED_BY_DESIGN with a reason): " * join(sort(missing_docs), ", "))
    end

    @testset "every entry is complete" begin
        bad_summary = [e.name for e in NS.SLATE_API if isempty(strip(e.summary)) || length(e.summary) > 110]
        @test isempty(bad_summary) ||
              error("entries need a ONE-LINE summary (non-empty, ≤110 chars): " * join(bad_summary, ", "))
        # A `docbinding` that no longer resolves renders an EMPTY entry — the failure mode of pointing
        # at a renamed/moved function. Catch it here rather than in an agent's context.
        empty_doc = [e.name for e in NS.SLATE_API if isempty(strip(NS._entry_markdown(e)))]
        @test isempty(empty_doc) ||
              error("entries render no documentation (a stale docbinding?): " * join(empty_doc, ", "))
        @test allunique(lowercase(e.name) for e in NS.SLATE_API)
    end

    @testset "index is cheap and complete" begin
        toc = NS.slate_api_reference()
        full = NS.slate_api_reference("all")
        # Every helper is NAMED in the index — that is its whole job — and it stays a small fraction
        # of the full reference, which is why the default call is affordable.
        @test all(e -> occursin(e.name, toc), NS.SLATE_API)
        @test length(toc) < length(full) ÷ 4
        @test occursin("slate_api(\"echart\")", toc)          # tells the reader how to drill in
        # The index must NOT be writable-from: it carries no signatures.
        @test !occursin("echart(kind, x, y", toc)
    end

    @testset "drill-down, batching and categories" begin
        one = NS.slate_api_reference("echart")
        @test occursin("Express", one) && !occursin("### @bind", one)
        # BATCHED: three helpers, one call — the thing that makes a cheap index workable.
        many = NS.slate_api_reference("echart @bind slate_table")
        @test occursin("### echart", many) && occursin("### @bind", many) && occursin("### slate_table", many)
        @test NS.slate_api_reference("echart, @bind") == NS.slate_api_reference("echart @bind")
        # PARTIAL batch: a named helper is still served, and the token that resolved to nothing says
        # so — never a bare "no match" that silently drops what the caller correctly named.
        part = NS.slate_api_reference("echart binding")
        @test occursin("### echart", part) && occursin("No entry named `binding`", part) &&
              occursin("@bind", part)
        # …but a token that merely FILTERS an entry keeps working as a phrase query, not a partial batch.
        filt = NS.slate_api_reference("slate_table format")
        @test occursin("### slate_table", filt) && !occursin("No entry named", filt)
        # A category returns its members and nothing else.
        wid = NS.slate_api_reference("Widgets")
        @test occursin("### Slider", wid) && occursin("### TableSelect", wid) && !occursin("### echart", wid)
        @test occursin("### web cell", NS.slate_api_reference("web cells"))
        # An exact helper name beats a category of the same spelling.
        @test occursin("### display", NS.slate_api_reference("display"))
    end

    @testset "lookup routes by concept, and a miss suggests" begin
        # Routing keywords carry a name-blind query to the right entry, even when the prose never
        # spells the phrase — this is what replaces "guess the name and grep".
        @test occursin("echart", NS.slate_api_reference("log axis"))
        @test occursin("TableSelect", NS.slate_api_reference("clickable row"))
        @test occursin("save_asset", NS.slate_api_reference("large data"))
        @test occursin("slate_on", NS.slate_api_reference("javascript"))
        # A near-miss (a typo, a plural) routes SOMEWHERE instead of dead-ending.
        near = NS.slate_api_reference("sliderz")
        @test occursin("Did you mean", near) && occursin("Slider", near)
        # A sigil must not hide the nearest entry: "bindings" is a near-miss for `@bind`.
        @test occursin("@bind", NS.slate_api_reference("bindings"))
        @test occursin("No Slate API entry", NS.slate_api_reference("zzzznope"))
    end

    @testset "the newly documented surface is reachable" begin
        # Each of these shipped BEFORE it was documented; assert the entry teaches the non-obvious bit,
        # not merely that a section exists.
        web = NS.slate_api_reference("web cell")
        @test occursin("root", web) && occursin("echo", web)              # the JS scope
        @test occursin("{{", web) && occursin("escap", lowercase(web))     # per-section escaping
        @test occursin("slateCall", web)
        on = NS.slate_api_reference("slate_on")
        @test occursin("slateCall", on) && occursin("progress", lowercase(on))
        @test occursin("slate_off", on)                                    # the teardown counterpart
        @test occursin("re-run", NS.slate_api_reference("slate_on_cleanup"))
        @test occursin("save_asset", NS.slate_api_reference("save_asset"))
        md = NS.slate_api_reference("markdown")
        @test occursin("{{", md) && occursin("standalone", lowercase(md))
        @test occursin("everywhere", lowercase(NS.slate_api_reference("slate_effect")))
        @test occursin("Makie", NS.slate_api_reference("use_slate_theme!"))
    end

    @testset "the cheatsheet is rendered from the registry" begin
        # The in-app agent's prompt is generated, not hand-maintained — so a new helper reaches it
        # automatically, and it can never again fall behind what actually ships.
        cs = NS._SLATE_CHEATSHEET
        @test all(e -> occursin(e.name, cs), NS.SLATE_API)
        @test occursin("slate_api(", cs)                                   # the trigger to drill in
        @test !occursin("echart(:line, x, y; title=", cs)                  # no writable-from signatures
    end

    @testset "tool handlers pass their optional args (gate ABI)" begin
        # Every optional GateTool param must be a KEYWORD arg. A positional can only be omitted
        # from the END, so a tool with two optional positionals cannot be called with just the
        # second one — and the gate's dispatcher used to reflect `first(methods(handler))`, which
        # for an optional positional can be the zero-arity method, dropping the argument SILENTLY
        # while the schema still advertised it (`slate.api(topic=…)` returned the index for every
        # topic that way). This asserts the shape that has neither problem.
        tools = KaimonSlate.create_tools(StubGate.GateTool)
        @test length(tools) > 20                                        # guard the guard
        optional_positional = String[]
        for t in tools
            arities = unique(Int(m.nargs) for m in methods(t.handler))
            length(arities) > 1 && push!(optional_positional, t.name)
        end
        @test isempty(optional_positional) ||
              error("slate tools with an OPTIONAL POSITIONAL arg — it can only be omitted from " *
                    "the END, so make it a keyword arg: " * join(sort(optional_positional), ", "))

        # …and the end-to-end behaviour that shape protects: a topic must reach the registry.
        api = only(t for t in tools if t.name == "api").handler
        @test occursin("### echart", api(topic = "echart"))
        @test occursin("— index", api())
    end

    # The worker PROCESS lifecycle is one tool with an action, not one tool per verb: an agent that
    # wants a fresh worker should find `restart` next to `reap` rather than reaching for whichever
    # name sounds closest. Where the worker runs is not part of the interface.
    @testset "worker lifecycle is one tool with four actions" begin
        tools = KaimonSlate.create_tools(StubGate.GateTool)
        names = [t.name for t in tools]
        @test "worker" in names
        # The verbs it replaced are gone — a stale name must fail loudly, not linger as a second way.
        @test isempty(intersect(names, ["reap_worker", "remote_workers", "whereis"]))

        w = only(t for t in tools if t.name == "worker").handler
        @test occursin("Unknown action", w(action = "bounce"))
        # Every action names what it needs instead of failing silently or guessing.
        @test occursin("Give a notebook", w(action = "restart"))
        @test occursin("Give a notebook", w(action = "status"))
        @test occursin("host and port", w(action = "reap"))
        @test occursin("port", w(action = "reap", host = "somehost"))
        # `status` is the default, so a bare notebook argument is the common read.
        @test w(notebook = "") == w(notebook = "", action = "status")

        # Every action takes the same arguments — the caller never selects a local or remote form.
        kw = Base.kwarg_decl(only(methods(w)))
        @test Set(kw) == Set([:notebook, :host, :port, :action])
    end

    @testset "declared timeout budgets" begin
        tools = KaimonSlate.create_tools(StubGate.GateTool)
        byname = Dict(t.name => t for t in tools)

        # The cell-eval tools PROMOTE past the grace window, so their budget only has to outlast
        # that window — and it's derived from the grace so the two can't drift. A hardcoded value
        # here would silently become too small the moment someone raised KAIMONSLATE_SCRATCH_GRACE.
        expected = round(Int, (NS._scratch_grace() + 120) * 1000)
        for n in ("run", "add_cell", "edit_cell")
            @test byname[n].timeout_ms == expected
            @test byname[n].timeout_ms > round(Int, NS._scratch_grace() * 1000)
        end

        # These genuinely block AND stay silent, so their budget must cover the whole operation.
        for n in ("pkg", "publish", "archive")
            @test byname[n].timeout_ms == 1_800_000
        end
        for n in ("export_pdf", "index_docs")
            @test byname[n].timeout_ms == 900_000
        end

        # No budget where one would be wrong. `site_publish` reports progress (`_say`), so the
        # inactivity refresh already keeps it alive; `run_on` returns straight away and leaves
        # the drain to an @async task. Declaring budgets here would paper over that distinction.
        @test byname["site_publish"].timeout_ms === nothing
        @test byname["run_on"].timeout_ms === nothing
    end

    @testset "search records carry summary + keywords" begin
        recs = NS.slate_api_records()
        @test all(r -> r["module"] == "Slate", recs) && length(recs) == length(NS.SLATE_API)
        @test any(r -> r["name"] == "web cell", recs)
        # The routing keywords ride into the semantic index, so `search_docs` answers a name-blind
        # question the same way `slate.api` does.
        r = only(filter(r -> r["name"] == "TableSelect", recs))
        @test occursin("keywords:", r["doc"]) && occursin("drill down", r["doc"])
        @test !isempty(NS.slate_api_version())
    end
end
