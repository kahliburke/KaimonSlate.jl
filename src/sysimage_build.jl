# The program that builds a region's worker sysimage, run where the region's workers run and in
# their shell (`build_sysimage!`). Its parameters are set above it as constants:
#
#   PROJ     the preparing notebook's environment on this machine: a listed package with no version
#            chosen is pinned to the version it resolves there, and so are Slate's worker packages
#   SYSDIR   the region's image directory, in the machine's depot
#   SPEC     what the region lists: (name, uuid, version, path) for each package
#   INFRA    Slate's worker packages, which every image holds
#   PAYLOAD  the worker's code, traced into the image
#   EXEC     the trace program
#   MINFREE  the memory, in GB, a build needs free before it starts
#   STALE    seconds after which another build's lock is taken over
#   FORCE    build even when the image is current
#
# The image environment is `SYSDIR/env`, made afresh from SPEC and INFRA each time. A package from a
# path is part of the key by its contents, so editing it makes the image out of date. An image is
# built for the CPU it was built on (a native image elsewhere can stop on an illegal instruction), so
# its pointer is `current-<cpu>`. The run prints one `[sysimg] pkg …` line per package the image holds
# and ends with one `[sysimg] result=…` line: current, built, deferred, busy, nocompiler or failed.

import Pkg, TOML, SHA

result(kind, rest = "") = (println("[sysimg] result=", kind, isempty(rest) ? "" : " " * rest); flush(stdout))
mkpath(SYSDIR)

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

# The image environment.
envdir = joinpath(SYSDIR, "env")
try
    rm(envdir; force = true, recursive = true); mkpath(envdir)
    adds = Pkg.PackageSpec[]; devs = String[]
    pinned(name) = (e = get(nbdeps, name, nothing); (e === nothing || haskey(e, "path")) ? "" : String(get(e, "version", "")))
    for (name, uuid, version, path) in SPEC
        if !isempty(path)
            push!(devs, expanduser(path))
        else
            v = isempty(version) ? pinned(name) : version
            push!(adds, isempty(v) ? Pkg.PackageSpec(name = name) : Pkg.PackageSpec(name = name, version = v))
        end
    end
    for name in INFRA
        any(s -> s.name == name, adds) && continue
        e = get(nbdeps, name, nothing)
        if e !== nothing && haskey(e, "path")
            push!(devs, abspath_of(e["path"]))
        else
            v = pinned(name)
            push!(adds, isempty(v) ? Pkg.PackageSpec(name = name) : Pkg.PackageSpec(name = name, version = v))
        end
    end
    Pkg.activate(envdir; io = devnull)
    isempty(devs) || Pkg.develop([Pkg.PackageSpec(path = p) for p in unique(devs)]; io = devnull)
    isempty(adds) || Pkg.add(adds; io = devnull)
catch e
    # The resolver's whole account goes to the log; the step names the clash: the package that could
    # not be placed, and the packages held to one version that it ran into.
    msg = sprint(showerror, e)
    for l in split(msg, '\n'); println("[sysimg] resolve: ", l); end
    stuck = (m = match(r"Unsatisfiable requirements detected for package (\S+)", msg); m === nothing ? "" : m.captures[1])
    held = unique([String(m.captures[1]) * " " * String(m.captures[2])
                   for m in eachmatch(r"([A-Za-z0-9_.]+) \[[0-9a-f]+\] log:\s*\n[\s│]*[├└]─possible versions are: [^\n]*\n[\s│]*[├└]─restricted to versions (\S+) by an explicit requirement", msg)
                   if m.captures[2] != "*"])
    why = isempty(stuck) ? first(replace(msg, '\n' => ' '), 300) :
          "$stuck cannot be installed with the rest" * (isempty(held) ? "" : ": it clashes with " * join(held, ", ") *
          " (held to that version)") * "; the resolver's account is in the activity log"
    result("failed", "reason=the image's packages could not be resolved: " * why)
    exit(0)
end

# The key: Julia, the CPU, the worker's code, and every package the image environment resolved to,
# a path package by its contents.
ctx = SHA.SHA1_CTX()
upd(x) = SHA.update!(ctx, codeunits(string(x, "\n")))
upd(VERSION); upd(cpu)
for f in sort!(filter(f -> endswith(f, ".jl") && !occursin(r"^worker-\d+\.jl$", basename(f)), readdir(PAYLOAD; join = true)))
    upd(basename(f)); SHA.update!(ctx, read(f))
end
function tree_hash(dir)
    h = SHA.SHA1_CTX()
    for (root, dirs, files) in walkdir(dir)
        filter!(d -> d != ".git", dirs)
        for f in sort(files)
            p = joinpath(root, f)
            SHA.update!(h, codeunits(relpath(p, dir))); SHA.update!(h, read(p))
        end
    end
    bytes2hex(SHA.digest!(h))[1:16]
end
md = (f = joinpath(envdir, "Manifest.toml"); isfile(f) ? TOML.parsefile(f) : Dict{String,Any}())
held = String[]
for name in sort!(collect(keys(get(md, "deps", Dict{String,Any}())))), e in md["deps"][name]
    tree = haskey(e, "path") ? "path:" * tree_hash(abspath_of(e["path"])) : String(get(e, "git-tree-sha1", ""))
    line = join((get(e, "uuid", ""), name, get(e, "version", ""), tree), " ")
    upd(line); push!(held, line)
end
key = bytes2hex(SHA.digest!(ctx))[1:16]
target = joinpath(SYSDIR, key * ".so"); curf = joinpath(SYSDIR, "current-" * cpu)
image() = "image=$target bytes=$(filesize(target)) env=$envdir"
println("[sysimg] key=$key cpu=$cpu"); flush(stdout)
for l in held; println("[sysimg] pkg ", l); end

if !FORCE && isfile(curf) && strip(read(curf, String)) == key && isfile(target)
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

# One build per region at a time. A lock names its builder; one whose process is gone, or that is
# older than any build takes, is taken over rather than waited out.
lk = joinpath(SYSDIR, ".building")
if isfile(lk)
    w = split(strip(read(lk, String))); age = time() - mtime(lk)
    gone = length(w) >= 3 && w[2] == gethostname() &&
           (p = tryparse(Int32, w[3]); p !== nothing && ccall(:kill, Cint, (Cint, Cint), p, 0) != 0)
    if !gone && age < STALE
        result("busy", "reason=another build started $(round(Int, age / 60))m ago" * (length(w) >= 2 ? " on $(w[2])" : ""))
        exit(0)
    end
end
write(lk, string(key, " ", gethostname(), " ", getpid()))
isfile(curf) && rm(curf; force = true)   # this CPU's workers start without an image while it builds

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
    builder = joinpath(dirname(SYSDIR), "builder"); Pkg.activate(builder; io = devnull)
    if !isfile(joinpath(builder, "Project.toml")) || !occursin("PackageCompiler", read(joinpath(builder, "Project.toml"), String))
        Pkg.add("PackageCompiler"; io = devnull)
    end
    Pkg.instantiate(; io = devnull)
    exec = joinpath(SYSDIR, "precompile_exec.jl"); write(exec, EXEC)
    pkgs = (f = joinpath(envdir, "Project.toml"); isfile(f) ? sort!(collect(keys(get(TOML.parsefile(f), "deps", Dict{String,Any}())))) : String[])
    println("[sysimg] baking $(length(pkgs)) package(s) and the worker's code → $target"); flush(stdout)
    # Each thread emitting the image holds its own share of it; short of memory, one is slower but fits.
    avail < 16 && (ENV["JULIA_IMAGE_THREADS"] = "1"; println("[sysimg] $(round(avail; digits = 1))GB free: emitting the image on one thread"); flush(stdout))
    @eval import PackageCompiler
    t0 = time(); beat = Timer(30; interval = 30) do _
        e = round(Int, time() - t0); n, kb = tree()
        println("[sysimg] building · $(e ÷ 60)m$(e % 60)s · $n process$(n == 1 ? "" : "es") · $(gb(kb)) GB · node $(gb(memkb("/proc/meminfo", "MemAvailable"))) GB free"); flush(stdout)
    end
    try
        Base.invokelatest(PackageCompiler.create_sysimage, pkgs; sysimage_path = target, project = envdir,
                          precompile_execution_file = exec)
    finally
        close(beat)
    end
    tmpc = curf * ".tmp"; write(tmpc, key); mv(tmpc, curf; force = true)   # publish the pointer atomically
    keep = Set(strip(read(f, String)) * ".so" for f in readdir(SYSDIR; join = true)
               if startswith(basename(f), "current-") && !endswith(f, ".tmp"))
    for f in readdir(SYSDIR; join = true)
        (endswith(f, ".so") && !(basename(f) in keep)) && rm(f; force = true)   # images no CPU's pointer names
    end
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
    rm(lk; force = true)
end
