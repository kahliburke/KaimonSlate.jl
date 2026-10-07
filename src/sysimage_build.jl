# The program that builds a worker sysimage, run where the region's workers run and in their shell
# (`build_sysimage!`). Its parameters are set above it as constants:
#
#   PROJ     the preparing notebook's environment on this machine: the image holds part of its
#            Manifest, so every package in the image is the version the notebook resolves
#   STORE    the machine's image store, in its depot
#   REGION   the region asking, named in the lock while it builds
#   SPEC     what the region lists: (name, uuid, version, path) for each package
#   INFRA    Slate's worker packages, which every image holds
#   EXEC     the trace program
#   MINFREE  the memory, in GB, a build needs free before it starts
#   STALE    seconds after which another build's lock is taken over
#   FORCE    build even when the image exists
#
# An image is named by what it holds: `STORE/<key>/` where the key hashes Julia and every package in
# it, a package from a path by its contents. Notebooks whose environments agree on those packages share
# one. The directory holds that environment (`env`) and one image per CPU (`<cpu>.so`),
# since a native image built on one CPU can stop on an illegal instruction on another. The run prints
# one `[sysimg] pkg …` line per package the image holds and ends with one `[sysimg] result=…` line:
# current, built, deferred, busy, nocompiler or failed.

import Pkg, TOML, SHA

result(kind, rest = "") = (println("[sysimg] result=", kind, isempty(rest) ? "" : " " * rest); flush(stdout))
mkpath(STORE)

# The CPU, spelled as the boot line's shell spells it, so both name the same pointer. An ARM CPU names
# no model in /proc/cpuinfo; its architecture is the name then, as the shell falls back too.
cpu = try
    l = first(filter(x -> startswith(x, "model name"), readlines("/proc/cpuinfo")))
    replace(strip(split(l, ':')[2]), r"[^A-Za-z0-9._-]" => "_")
catch
    ""
end
isempty(cpu) && (cpu = try; readchomp(`uname -m`); catch; ""; end)

# What the notebook resolves, by name.
nbm = (f = joinpath(PROJ, "Manifest.toml"); isfile(f) ? TOML.parsefile(f) : Dict{String,Any}())
nbdeps = Dict{String,Any}()
for (name, es) in get(nbm, "deps", Dict{String,Any}()), e in es
    nbdeps[name] = e
end
abspath_of(p) = (p = expanduser(String(p)); isabspath(p) ? p : normpath(joinpath(PROJ, p)))

# The image environment: the packages the region lists that the notebook's environment holds, Slate's
# worker packages, and everything they depend on, each exactly as the notebook's Manifest has it. Taken
# from the Manifest rather than resolved, so the image never holds a version the notebook does not, and
# finding that an image is current costs no resolve. A listed package the notebook does not use is left
# out of its image.
roots = String[]
for (name, uuid, version, path) in SPEC
    if haskey(nbdeps, name)
        push!(roots, name)
    else
        println("[sysimg] skip ", name, " (not in the notebook's environment)")
    end
end
for name in INFRA
    haskey(nbdeps, name) && !(name in roots) && push!(roots, name)
end
if isempty(roots)
    result("failed", "reason=the notebook's environment holds none of the packages the image would hold"); exit(0)
end
depnames(e) = (d = get(e, "deps", String[]); d isa AbstractDict ? collect(String, keys(d)) : collect(String, d))
closure = Set{String}(); todo = copy(roots)
while !isempty(todo)
    n = pop!(todo)
    (n in closure || !haskey(nbdeps, n)) && continue
    push!(closure, n); append!(todo, depnames(nbdeps[n]))
end

# The key: Julia and every package the image holds, a path package by its contents. Not the worker's
# own code: it is included at each boot, not held in the image, so a Slate update leaves the image as
# good as it was.
ctx = SHA.SHA1_CTX()
upd(x) = SHA.update!(ctx, codeunits(string(x, "\n")))
upd(VERSION)
tree_hash(dir) = bytes2hex(Pkg.GitTools.tree_hash(dir))[1:16]   # git's tree hash, as a Manifest records it
held = String[]
for name in sort!(collect(closure))
    e = nbdeps[name]
    tree = haskey(e, "path") ? "path:" * tree_hash(abspath_of(e["path"])) : String(get(e, "git-tree-sha1", ""))
    line = join((get(e, "uuid", ""), name, get(e, "version", ""), tree), " ")
    upd(line); push!(held, line)
end
key = bytes2hex(SHA.digest!(ctx))[1:16]
dir = joinpath(STORE, key); envdir = joinpath(dir, "env"); target = joinpath(dir, cpu * ".so")
mkpath(dir)

# Written when an image is about to be built: that part of the notebook's Manifest, paths made
# absolute, and a Project naming the roots. Its packages are all in the depot already.
function write_env()
    mkpath(envdir)
    m = Dict{String,Any}(k => v for (k, v) in nbm if k != "deps" && k != "project_hash")
    m["deps"] = Dict{String,Any}(n => [let e = deepcopy(nbdeps[n])
                                           haskey(e, "path") && (e["path"] = abspath_of(e["path"])); e
                                       end] for n in closure)
    open(io -> TOML.print(io, m; sorted = true), joinpath(envdir, "Manifest.toml"), "w")
    open(io -> TOML.print(io, Dict("deps" => Dict(n => nbdeps[n]["uuid"] for n in roots)); sorted = true),
         joinpath(envdir, "Project.toml"), "w")
end
image() = "image=$target bytes=$(filesize(target)) env=$envdir"
println("[sysimg] key=$key cpu=$cpu"); flush(stdout)
for l in held; println("[sysimg] pkg ", l); end

if !FORCE && isfile(target)
    result("current", image()); exit(0)
end
if Sys.which("gcc") === nothing && Sys.which("clang") === nothing && Sys.which("cc") === nothing
    result("nocompiler", "reason=no C compiler (gcc, clang or cc) to link the image"); exit(0)
end

# A link peaks at several GB: on a node short of memory the build is put off rather than killed.
avail = try
    if Sys.islinux()
        parse(Float64, match(r"MemAvailable:\s+(\d+)", read("/proc/meminfo", String)).captures[1]) / 1048576
    elseif Sys.isapple()
        vs = read(`vm_stat`, String); pg = (m = match(r"page size of (\d+)", vs)) === nothing ? 4096 : parse(Int, m.captures[1])
        fp(re) = ((m = match(re, vs)) === nothing ? 0 : parse(Int, m.captures[1]))
        (fp(r"Pages free:\s+(\d+)") + fp(r"Pages inactive:\s+(\d+)")) * pg / 2^30
    else
        Inf
    end
catch
    Inf
end
avail < MINFREE && (result("deferred", "reason=only $(round(avail; digits = 1))GB free, the link needs $(MINFREE)GB"); exit(0))

# One build of an image per CPU at a time. A lock names its builder; one whose process is gone, or that
# is older than any build takes, is taken over rather than waited out.
lk = joinpath(dir, ".building-" * cpu)
if isfile(lk)
    w = split(strip(read(lk, String))); age = time() - mtime(lk)
    gone = length(w) >= 3 && w[2] == gethostname() &&
           (p = tryparse(Int32, w[3]); p !== nothing && ccall(:kill, Cint, (Cint, Cint), p, 0) != 0)
    if !gone && age < STALE
        result("busy", "reason=the same image is being built for $(w[1]), started $(round(Int, age / 60))m ago" *
                       (length(w) >= 2 ? " on $(w[2])" : ""))
        exit(0)
    end
end
write(lk, string(REGION, " ", gethostname(), " ", getpid()))

# Every 30s while it runs: how long, how many processes the build has and the memory they hold, and
# what the node has left. PackageCompiler prints nothing while it compiles the image.
memkb(f, k) = try; m = match(Regex(k * ":\\s+(\\d+)"), read(f, String)); m === nothing ? 0 : parse(Int, m.captures[1]); catch; 0; end
gb(kb) = round(kb / 2^20; digits = 1)
function tree()
    pr = try; open(`ps -eo pid=,ppid=,rss=`); catch; nothing; end   # its own `ps` is left out by pid
    me = pr === nothing ? 0 : try; getpid(pr); catch; 0; end
    rows = pr === nothing ? Vector{Int}[] :
           [parse.(Int, split(l)) for l in eachline(pr) if length(split(l)) == 3 && parse(Int, split(l)[1]) != me]
    kids = Dict{Int,Vector{Int}}(); rss = Dict{Int,Int}()
    for (p, pp, r) in rows; push!(get!(kids, pp, Int[]), p); rss[p] = r; end
    seen = Int[]; todo = copy(get(kids, getpid(), Int[]))
    while !isempty(todo); p = pop!(todo); push!(seen, p); append!(todo, get(kids, p, Int[])); end
    (length(seen), sum((get(rss, p, 0) for p in seen); init = 0))
end

try
    write_env()
    builder = joinpath(STORE, "builder"); Pkg.activate(builder; io = devnull)
    if !isfile(joinpath(builder, "Project.toml")) || !occursin("PackageCompiler", read(joinpath(builder, "Project.toml"), String))
        Pkg.add("PackageCompiler"; io = devnull)
    end
    Pkg.instantiate(; io = devnull)
    exec = joinpath(dir, "precompile_exec.jl"); write(exec, EXEC)
    pkgs = (f = joinpath(envdir, "Project.toml"); isfile(f) ? sort!(collect(keys(get(TOML.parsefile(f), "deps", Dict{String,Any}())))) : String[])
    println("[sysimg] baking $(length(pkgs)) package(s) and the worker's code → $target"); flush(stdout)
    # Each thread emitting the image holds its own share of it; short of memory, one is slower but fits.
    avail < 16 && (ENV["JULIA_IMAGE_THREADS"] = "1"; println("[sysimg] $(round(avail; digits = 1))GB free: emitting the image on one thread"); flush(stdout))
    @eval import PackageCompiler
    t0 = time(); beat = Timer(30; interval = 30) do _
        e = round(Int, time() - t0); n, kb = tree()
        println("[sysimg] building · $(e ÷ 60)m$(e % 60)s · $n process$(n == 1 ? "" : "es") · $(gb(kb)) GB · node $(gb(memkb("/proc/meminfo", "MemAvailable"))) GB free"); flush(stdout)
    end
    # Linked beside its name and moved onto it, so a worker never boots a half-written image.
    tmp = joinpath(dir, ".$cpu-$(getpid()).so")
    try
        Base.invokelatest(PackageCompiler.create_sysimage, pkgs; sysimage_path = tmp, project = envdir,
                          precompile_execution_file = exec)
    finally
        close(beat)
    end
    mv(tmp, target; force = true)
    # Prime the package caches against the new image here, not under the first real worker.
    try
        println("[sysimg] priming package caches against the new image…"); flush(stdout)
        run(pipeline(`$(Base.julia_cmd()[1]) --sysimage=$target --project=$envdir --startup-file=no $exec`;
                     stdout = devnull, stderr = devnull))
    catch e
        println("[sysimg] prime skipped ($(first(sprint(showerror, e), 80)))")
    end
    result("built", image())
catch e
    msg = sprint(showerror, e)
    why = occursin("ProcessSignaled(9)", msg) ?
          "the compiler was killed (signal 9), most likely for lack of memory: the node had $(round(avail; digits = 1))GB free when the build started" :
          replace(first(msg, 300), '\n' => ' ')
    result("failed", "reason=" * why)
finally
    rm(lk; force = true); rm(joinpath(dir, ".$cpu-$(getpid()).so"); force = true)
end
