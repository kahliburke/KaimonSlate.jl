# The notebook file format: a file says which format it is written in (none = 1), is read in that
# format's grammar and written in the current one, and a notebook whose update changes something
# opens only once the update is agreed to, keeping a copy of the original beside it.

using ReTest
using KaimonSlate
const RE = KaimonSlate.ReportEngine
const NS = KaimonSlate.NotebookServer

const V1 = """
#%% md id=intro
# A study

#%% sweep id=scan cluster=hpc
@sweep(grid) do p
    p.x
end

#%% sweep id=more
@sweep(grid) do p
    p.y
end

# ╔═╡ Slate.sweep · per-cell scheduler options (the ⎈ on a sweep cell)
#   {"cell":"scan","options":{"licenses":"x@y"}}
# ╚═╡
"""

@testset "format: an old notebook reads in its own grammar and writes in the current one" begin
    r = RE.parse_report(V1)
    @test r.meta["format"] == 1
    @test [c.kind for c in r.cells if c.id in ("scan", "more")] == [RE.JOB, RE.JOB]
    @test r.meta["jobopts"]["scan"]["licenses"] == "x@y"
    ch = RE.format_changes(r)
    @test length(ch) == 2 && occursin("2 `sweep` cells become `job` cells", ch[1]) && occursin("Slate.job", ch[2])
    out = RE.serialize_report(r)
    @test occursin("#%% job id=scan cluster=hpc", out) && !occursin("#%% sweep", out)
    @test occursin("# ╔═╡ Slate.job", out) && !occursin("Slate.sweep", out)
    @test occursin("#   format = $(RE.FORMAT)", out)
    back = RE.parse_report(out)
    @test back.meta["format"] == RE.FORMAT && isempty(RE.format_changes(back))
    @test RE.serialize_report(back) == out                          # stable once current

    # In the current format `sweep` is not a kind: it stays a tag, as any unknown token does.
    cur = RE.parse_report("#%% sweep id=s\n1\n\n# ╔═╡ Slate.config\n#   format = 2\n# ╚═╡\n")
    @test cur.cells[1].kind === RE.CODE && :sweep in cur.cells[1].flags

    # Format 1 ran a campaign in a code cell; it becomes a job, as a sweep does.
    camp = RE.parse_report("#%% code id=size\n@campaign(size, vary = (x,), satisfy = (r,))\n\n#%% code id=other\ny = 2\n")
    @test camp.cells[1].kind === RE.JOB && camp.cells[2].kind === RE.CODE
    @test only(RE.format_changes(camp)) == "1 cell running a campaign becomes a `job` cell"

    # An old notebook with nothing the update changes has nothing to ask about.
    plain = RE.parse_report("#%% code id=a\nx = 1\n")
    @test plain.meta["format"] == 1 && isempty(RE.format_changes(plain))
end

@testset "format: a notebook to update is not opened until the update is agreed to" begin
    dir = mktempdir()
    path = joinpath(dir, "study.jl")
    write(path, V1)
    e = try; NS.load_notebook(path; id = "study", inactive = true); nothing; catch x; x; end
    @test e isa NS.NotebookNeedsUpdate && e.format == 1 && length(e.changes) == 2
    @test read(path, String) == V1                                   # declined: the file is untouched
    @test readdir(dir) == ["study.jl"]
    j = NS._needs_update_json(e)
    @test j["needs_update"] && j["current"] == RE.FORMAT && startswith(j["backup"], "study.format1.") && endswith(j["backup"], ".jl")

    # Agreed: the original is kept beside it, the file is written in the current format.
    up = NS.update_notebook_format!(path)
    @test isfile(up.backup) && dirname(up.backup) == dir && read(up.backup, String) == V1
    @test length(up.changes) == 2
    now = read(path, String)
    @test occursin("#%% job id=scan", now) && occursin("format = $(RE.FORMAT)", now)
    @test NS.update_notebook_format!(path).backup == ""              # already current: nothing to do
    @test length(readdir(dir)) == 2
end
