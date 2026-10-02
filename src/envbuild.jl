# ── Building a project's environment on another machine ─────────────────────────────────────
# One way to put a local project's environment on a remote host, used by both kinds of remote work:
# a region's worker and a batch sweep's tasks. The local Manifest is reproduced exactly, each package
# developed from a local checkout is shipped beside it and the paths rewritten to the copies, and the
# result is instantiated by a Julia started in the machine's shell (`setup`: its julia, depot, module
# fix and prologue). Part of `Sweep` because the worker submits sweeps too and has no hub code.

# The name a local project's environment has on another machine: its folder's name and a hash of its
# path. A region's worker and a sweep's tasks both run in this one, so whatever loaded it on a machine
# (a region's prepare, a test task) has tested it for both.
function proj_key(p)
    s = String(p); isempty(s) && return "detached"
    ap = abspath(expanduser(s))
    replace(basename(rstrip(ap, '/')), r"[^A-Za-z0-9._-]" => "_") * "-" * bytes2hex(SHA.sha1(codeunits(ap)))[1:8]
end

"Where project `p`'s environment lives on a remote machine, relative to its home directory."
shared_env(p) = ".cache/kaimonslate/remote/" * proj_key(p)

# `path = "."` resolves to the env dir itself, and on Windows `abspath` keeps the trailing
# separator there (`C:\...\proj\`) while on unix it does not. These paths are compared against
# env dirs to skip the project itself and handed to rsync, where a trailing separator changes
# what gets copied, so normalise it away. A bare root (`C:\`, `/`) is left alone.
function strip_trailing_sep(p::AbstractString)
    s = String(p)
    q = rstrip(s, ('/', '\\'))
    isempty(q) && return s                                    # "/" — a unix root
    (Sys.iswindows() && length(q) == 2 && q[2] == ':') && return s   # "C:\" — a drive root
    return q
end

# Dev'd dependencies in a Manifest = entries carrying a `path` (a local checkout, `Pkg.develop`). Returns
# name => absolute-local-path. Registry deps have no path; git deps have a `repo-url` (they clone on the
# remote straight from the Manifest, so need no special handling). Paths may be relative to the env dir.
# A line-scan of the stable `[[deps.Name]]` … `path = "…"` format — no TOML dep needed on the hub side.
function dev_deps(manifest::AbstractString, envdir::AbstractString)
    out = Pair{String,String}[]
    isfile(manifest) || return out
    curname = ""
    for line in eachline(manifest)
        m = match(r"^\[\[deps\.(.+?)\]\]\s*$", line)
        if m !== nothing; curname = String(m.captures[1]); continue; end
        startswith(strip(line), "[") && (curname = "")           # entered some other table → out of a deps block
        isempty(curname) && continue
        pm = match(r"^\s*path\s*=\s*\"(.*)\"\s*$", line)
        pm === nothing && continue
        p = String(pm.captures[1])
        push!(out, curname => strip_trailing_sep(isabspath(p) ? p : abspath(joinpath(envdir, p))))
        curname = ""
    end
    return out
end

# Remote Julia code that rewrites each dev dep's path — in the Manifest (if present) AND in Project.toml's
# `[sources]` — to its shipped `devsrc` location. Julia ≥1.11's resolver reads the `[sources]` path, so a
# dev dep dangles unless BOTH are redirected. Returns "" when there's nothing to rewrite. Shared so the
# origin-env replication and the parent-project provision rewrite paths identically.
function devpaths_script(projrel::AbstractString, rewrites::Vector{Tuple{String,String}})
    isempty(rewrites) && return ""
    io = IOBuffer()
    println(io, "import Pkg, TOML")
    println(io, "proj = joinpath(homedir(), raw\"$projrel\")")
    println(io, "mf = joinpath(proj, \"Manifest.toml\")")
    println(io, "if isfile(mf)")
    println(io, "  data = TOML.parsefile(mf)")
    println(io, "  deps = get(data, \"deps\", Dict{String,Any}())")
    for (name, rp) in rewrites
        println(io, "  if haskey(deps, raw\"$name\")")
        println(io, "    for e in deps[raw\"$name\"]; e isa AbstractDict && (e[\"path\"] = joinpath(homedir(), raw\"$rp\")); end")
        println(io, "  end")
    end
    println(io, "  open(mf, \"w\") do _io; TOML.print(_io, data); end")
    println(io, "end")
    println(io, "pf = joinpath(proj, \"Project.toml\")")
    println(io, "if isfile(pf)")
    println(io, "  pdata = TOML.parsefile(pf)")
    println(io, "  src = get!(() -> Dict{String,Any}(), pdata, \"sources\")")
    # A workspace member declares no `[sources]` of its own — it inherits the workspace root's, and
    # only the member dir is shipped. So ADD an entry for a dev dep that has none, not just rewrite.
    # Guarded on the dep being declared: Pkg rejects a source naming a package the project doesn't
    # list, which an indirect (manifest-only) path dep would be.
    println(io, "  decl = union(keys(get(pdata, \"deps\", Dict{String,Any}())), keys(get(pdata, \"extras\", Dict{String,Any}())))")
    for (name, rp) in rewrites
        println(io, "  let e = get(src, raw\"$name\", nothing)")
        println(io, "    if e isa AbstractDict && haskey(e, \"path\")")
        println(io, "      e[\"path\"] = joinpath(homedir(), raw\"$rp\")")
        # An existing entry without a `path` is a git source — leave it, its url/rev still resolve.
        println(io, "    elseif e === nothing && raw\"$name\" in decl")
        println(io, "      src[raw\"$name\"] = Dict{String,Any}(\"path\" => joinpath(homedir(), raw\"$rp\"))")
        println(io, "    end")
        println(io, "  end")
    end
    println(io, "  isempty(src) && delete!(pdata, \"sources\")")
    println(io, "  open(pf, \"w\") do _io; TOML.print(_io, pdata); end")
    println(io, "end")
    return String(take!(io))
end

"""
    run_julia_there(host, code; setup = "", what = "julia", timeout = 4h, online = nothing) -> (ok, out)

Run `code` as a Julia script on `host`, in the machine's shell `setup`. The script travels as a file,
since quoting it through two shells mangles it. Pkg work runs for minutes on a cluster filesystem, so
the deadline is hours, and `online` gets each line of output as it arrives.
"""
function run_julia_there(host::AbstractString, code::AbstractString; setup::AbstractString = "",
                         what::AbstractString = "julia", timeout::Real = 4 * 3600.0, online = nothing)
    remote = ".cache/kaimonslate/" * string("slate-", bytes2hex(rand(UInt8, 6)), ".jl")
    put_file(String(host), Vector{UInt8}(codeunits(code)), remote) ||
        return (false, "could not send the script for $what to $host")
    q = shq_path(remote)
    pre = isempty(setup) ? "export PATH=\"\$HOME/.juliaup/bin:\$PATH\"; " : setup
    return run_there(String(host), pre * "julia --startup-file=no " * q * "; rc=\$?; rm -f " * q * "; exit \$rc";
                     timeout, online)
end

"""
    devsources_script(projects, rewrites) -> String

Julia code that points the `[sources]` of each shipped package's own Project.toml at the shipped
copies. A package developed from a checkout often develops another the same way, by a relative path
that means nothing on the other machine; the environment's own files are rewritten by
`devpaths_script`, and these are the rest. `projects` and the rewrite targets are paths relative to
the home directory, or absolute.
"""
function devsources_script(projects::Vector{String}, rewrites::Vector{Tuple{String,String}})
    (isempty(projects) || isempty(rewrites)) && return ""
    io = IOBuffer()
    println(io, "import TOML")
    print(io, "let devs = Dict(")
    print(io, join(("raw\"$n\" => joinpath(homedir(), raw\"$p\")" for (n, p) in rewrites), ", "))
    println(io, ")")
    print(io, "  for pf in [")
    print(io, join(("joinpath(homedir(), raw\"$p\", \"Project.toml\")" for p in projects), ", "))
    println(io, "]")
    println(io, "    isfile(pf) || continue")
    println(io, "    d = TOML.parsefile(pf); s = get(d, \"sources\", nothing)")
    println(io, "    s isa AbstractDict || continue")
    println(io, "    for (k, e) in s; e isa AbstractDict && haskey(e, \"path\") && haskey(devs, k) && (e[\"path\"] = devs[k]); end")
    println(io, "    open(io -> TOML.print(io, d), pf, \"w\")")
    println(io, "  end")
    println(io, "end")
    return String(take!(io))
end
