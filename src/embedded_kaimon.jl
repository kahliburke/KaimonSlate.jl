# ── Embedded Kaimon — the compute/agent host, run for you ─────────────────────────────────────────
#
# Standalone `slate` has no compute gate, so every remote path in `_select_kernel` is unreachable
# (see the `remoteAvailable` refusal there). The gate CLIENT — `ConnectionManager`/`connect_tcp!` —
# lives in Kaimon, not in the small KaimonGate package, so a hub cannot dial a worker without it.
#
# Rather than depend on Kaimon (35 top-level deps for someone who wants notebooks), or relay its
# traffic through a sidecar (a process hop on every eval, on the path the streaming work took from
# p50 26ms to 1ms), `slate --ai` runs the real thing: `kaimon --headless` in an isolated location,
# which starts Slate as its extension exactly as a normal Kaimon install does. The `slate` CLI then
# attaches as a viewer, which it already knows how to do.
#
# Nothing here is a new mechanism. `kaimon --headless` is a first-class mode, headless startup
# already calls `start_extensions!()`, `register_extension()` already writes the registry, and
# app.jl already has viewer mode. This file supplies the isolation and the lifecycle.
#
# Everything the embedded host writes stays under `_embedded_root()`. See `_embedded_env_vars`
# for why that needs BOTH halves of the XDG/KAIMONSLATE precedence to be set explicitly.

"""
    _embedded_root() -> String

Where the embedded Kaimon lives — config, cache, and its Julia environment. Everything it writes
goes under here, so removing this directory removes the install. Override with
`KAIMONSLATE_KAIMON_HOME`.

Deliberately under Slate's CACHE home: it is reconstructible (an env we can rebuild and a config we
can rewrite), and nothing a user authored is kept here.
"""
_embedded_root() = get(ENV, "KAIMONSLATE_KAIMON_HOME", joinpath(SlateHome.cache_home(), "kaimon"))

_embedded_config_home() = joinpath(_embedded_root(), "config")   # → XDG_CONFIG_HOME
_embedded_env()         = joinpath(_embedded_root(), "env")      # → --project

# The gate puts a unix socket under `<XDG_CACHE_HOME>/kaimon/sock/<uuid>-stream.sock`, and a unix
# socket path has a hard length limit (~104 bytes on macOS/BSD, 108 on Linux) that is NOT a path
# limit — it is the size of a struct field, so exceeding it is a hard error, not a truncation. The
# tail the gate appends is ~61 bytes, so the cache home has to be SHORT.
#
# `~/.cache/kaimonslate/kaimon/cache` is 44 bytes for a short username and already overflows by two.
# So measure, and fall back to a short private directory when the tidy location will not fit —
# exactly what `_ssh_mux_dir` does for ssh control sockets, and for the same reason.
const _SOCK_TAIL = 61        # "/kaimon/sock/" + a 36-char UUID + "-stream.sock"
_sock_fits(dir) = length(dir) + _SOCK_TAIL < (Sys.islinux() ? 108 : 104)

function _embedded_cache_home()
    pref = joinpath(_embedded_root(), "cache")
    (_sock_fits(pref) || !Sys.isunix()) && return pref
    alt = joinpath("/tmp", "ks-ai-" * ReportEngine._uid_tag())
    return _sock_fits(alt) ? alt : pref     # nothing else to try; let the gate report it
end

"""
    _embedded_env_vars(port) -> Vector{Pair{String,Union{String,Nothing}}}

The environment the embedded host runs in. Two halves, and both are required:

1. `XDG_*` point at the isolated location, which is the whole of Kaimon's own resolution — it has
   no `KAIMON_HOME`, its config and cache come from `XDG_CONFIG_HOME`/`XDG_CACHE_HOME` with
   `kaimon` appended.

2. `KAIMONSLATE_*` are pinned back to the user's REAL homes. Headless Kaimon spawns the Slate
   extension as a CHILD, which inherits the vars above, and `SlateHome` reads the same `XDG_*`.
   Without this the embedded Slate would silently get a fresh config, an empty notebook list and a
   different publish ledger. It works only because `SlateHome`'s precedence puts
   `KAIMONSLATE_<HOME>_HOME` above `XDG_*`.

Also: no periodic index sync. Ollama may not be running, and indexing is not why Slate started a
host — same reasoning as the `KAIMONSLATE_NO_AUTOINDEX` the exported-app runner sets.
"""
function _embedded_env_vars(port::Integer)
    real = SlateHome                                   # the user's own homes, resolved BEFORE we repoint XDG
    return [
        "XDG_CONFIG_HOME" => _embedded_config_home(),
        "XDG_CACHE_HOME"  => _embedded_cache_home(),
        "KAIMONSLATE_CONFIG_HOME" => real.config_home(),
        "KAIMONSLATE_DATA_HOME"   => real.data_home(),
        "KAIMONSLATE_CACHE_HOME"  => real.cache_home(),
        "KAIMON_HEADLESS_SYNC_INTERVAL" => "0",
        "KAIMON_QDRANT_PREFIX" => "slate-embedded",
        "KAIMONSLATE_PORT" => string(_PORT[]),         # the hub the extension should bind
        # Julia's own resolution must be OURS, not whatever launched us. The `slate` app shim
        # exports `JULIA_LOAD_PATH=<the KaimonSlate checkout>`, which REPLACES the whole load path —
        # no `@`, so `--project=<embedded env>` names an environment that is then never searched and
        # the host dies with "Package Kaimon not found in current path". Restore the default so
        # `--project` means what it says. (Kaimon's own extension launcher does the same thing for
        # the same reason.)
        "JULIA_LOAD_PATH" => join(("@", "@v#.#", "@stdlib"), Sys.iswindows() ? ';' : ':'),
        "JULIA_PROJECT" => nothing,
    ]
end

"""
    _write_kaimon_config!(port) -> String

Write the embedded host's `config.json` (lax, loopback, no API key) and return its path.

Written rather than left to Kaimon's own first-run path, which produces `:strict` with a generated
API key — that would put a token between this host, the Slate extension it spawns, and any CLI
agent attaching to it, for a single-user local host where there is nothing to authenticate against.

`created_at` is an `Int64` field. Kaimon rounds on read, but write an integer anyway.
"""
function _write_kaimon_config!(port::Integer)
    dir = joinpath(_embedded_config_home(), "kaimon")   # Kaimon appends "kaimon" under XDG_CONFIG_HOME
    mkpath(dir)
    file = joinpath(dir, "config.json")
    cfg = Dict{String,Any}(
        "mode" => "lax",
        "api_keys" => String[],
        "allowed_ips" => ["127.0.0.1", "::1"],
        "port" => Int(port),
        "created_at" => round(Int, time()),
        "editor" => "vscode",
        "qdrant_prefix" => "slate-embedded",
    )
    write(file, JSON.json(cfg, 2))
    Sys.isunix() && (try; chmod(file, 0o600); catch; end)
    return file
end

# Is something already serving on the port the embedded extension would bind? A plain TCP connect:
# this asks "is anyone there", which is the question that matters, and does not need the responder
# to be a Slate hub (whatever it is, we must not fight it for the port).
#
# Uses ReportEngine's existing probe rather than a local `Sockets` call: `Sockets` is not imported
# into this module, so a direct call throws `UndefVarError` — and with the guard's own `catch` that
# read as "port is free", which is the failure mode a guard must never have. It answered false while
# a live hub was sitting on the port, and starting anyway took that hub down.
_hub_port_taken() = !ReportEngine._port_free(_PORT[])

# Where Kaimon comes from: a local checkout when `SLATE_KAIMON_PATH` names one (same override the
# exported-app runner honours), else the registry.
_kaimon_spec() = (p = strip(get(ENV, "SLATE_KAIMON_PATH", ""));
                  isempty(p) ? "Pkg.PackageSpec(name=\"Kaimon\")" :
                               "Pkg.PackageSpec(path=raw\"$(abspath(expanduser(p)))\")")

"""
    _ensure_embedded_env!(; online = nothing) -> Bool

Build the embedded host's environment if it isn't there. `online` is fed each line of Pkg output so
a caller can narrate it — the first run installs Kaimon and precompiles, which takes minutes and
must not look like a hang.

The DEPOT is deliberately shared with the user's own. A private depot would make removal a single
`rm -rf`, but it would also re-download and re-precompile every dependency from scratch, which is
the thing most likely to make `--ai` feel broken. Isolation of config/cache/tmp is what was asked
for, and that is orthogonal to where package artifacts live.
"""
function _ensure_embedded_env!(; online = nothing)
    env = _embedded_env()
    isfile(joinpath(env, ".ready")) && return true
    mkpath(env)
    # Kaimon's extension launcher puts THIS env on the extension's `JULIA_LOAD_PATH` so the
    # extension can reach Kaimon and its deps ("for Gate, LoggingExtras, etc." in its own comment).
    # But a LOAD_PATH entry only offers what its project DECLARES in `[deps]` — a manifest entry is
    # not enough. An env holding only Kaimon therefore satisfies `using Kaimon` and then fails the
    # generated script's `using LoggingExtras`, which is a transitive dep here and a direct one in
    # the Kaimon checkout that shape was designed around.
    #
    # So declare Kaimon's own direct deps here too. They are already installed as transitive deps,
    # so this adds Project.toml entries rather than downloads.
    code = """
        import Pkg
        Pkg.activate(raw"$env")
        Pkg.add($(_kaimon_spec()))
        import Kaimon
        let pf = joinpath(pkgdir(Kaimon), "Project.toml")
            deps = collect(keys(get(Pkg.TOML.parsefile(pf), "deps", Dict{String,Any}())))
            filter!(!=("Kaimon"), deps)
            isempty(deps) || Pkg.add(deps; preserve = Pkg.PRESERVE_ALL)
        end
        """
    ok = NotebookServer._instantiate_env!(env; code = code, online = online, quiet = true)
    # `.ready` is a claim that the env WORKS, so verify it rather than trusting the installer's exit
    # code: a half-resolved env still spawns, and the failure then surfaces as a Julia stack trace in
    # a log file nobody knows to open. One subprocess, once, on the path that already takes minutes.
    ok = ok && _embedded_kaimon_loads()
    ok && write(joinpath(env, ".ready"), string(round(Int, time())))
    return ok
end

# Can the embedded env actually load Kaimon? The question `.ready` is asserting.
function _embedded_kaimon_loads()
    try
        return success(pipeline(`$(Base.julia_cmd()) --project=$(_embedded_env()) --startup-file=no
                                 -e "import Kaimon"`; stdout = devnull, stderr = devnull))
    catch
        return false
    end
end

# The running embedded host, when WE started it. `nothing` when we attached to one the user was
# already running — which must never be stopped on our way out.
const _EMBEDDED = Ref{Any}(nothing)

"""
    start_embedded_kaimon!(port; online = nothing) -> Bool

Bring up `kaimon --headless` on `port`, isolated under [`_embedded_root`](@ref). Returns whether it
was started. Idempotent: a second call with one already running is a no-op.

The host starts the Slate extension itself (headless startup calls `start_extensions!`), so the
sequence is: build the env, write the lax config, register Slate into the ISOLATED registry, spawn.
Registration goes through the ordinary `register_extension()` — it resolves Kaimon's config dir
from `XDG_CONFIG_HOME` at call time, so running it under the isolated environment writes the
isolated registry with no special-casing.
"""
function start_embedded_kaimon!(port::Integer; online = nothing)
    _EMBEDDED[] === nothing || return false
    note = msg -> (online === nothing || (try; online(String(msg)); catch; end); nothing)
    # A previous run that was killed outright can leave its host or extension behind, still holding
    # the hub port — which would make this start fail on a port clash for a reason that has nothing
    # to do with this run. Clear our own leftovers first; nobody else's are candidates.
    _reap_embedded_strays!()
    # The host's extension binds KAIMONSLATE_PORT. Refuse if something already answers there: it is
    # somebody else's hub, and starting anyway displaces a running notebook server. This lives HERE
    # rather than only in the CLI because any caller can reach this function, and the default port is
    # the one an existing Slate extension is most likely to be on. (Learned the hard way: calling
    # this directly in a test took down the author's live hub.)
    if _hub_port_taken()
        error("slate --ai: a hub is already answering on port $(_PORT[]), which the embedded " *
              "extension would bind. Give this one its own port (`--port`), or attach to the " *
              "hub that is already running instead of starting another.")
    end
    note("Preparing the Kaimon host (first run installs and precompiles — this takes a few minutes)")
    _ensure_embedded_env!(; online = online) ||
        error("slate --ai: could not build the Kaimon environment in $(_embedded_env()) — see the output above")
    _write_kaimon_config!(port)
    envv = _embedded_env_vars(port)
    # Register under the ISOLATED config dir, not the user's. `_kaimon_dir()` reads XDG_CONFIG_HOME
    # at call time and refuses when the directory is absent, so create it first.
    withenv(envv...) do
        mkpath(_kaimon_dir())
        register_extension(; announce = false)
    end
    note("Starting the Kaimon host on port $port")
    cmd = addenv(`$(Base.julia_cmd()) --project=$(_embedded_env()) --startup-file=no
                  -m Kaimon --headless --port $port`, envv...)
    log = joinpath(_embedded_root(), "kaimon.log")
    mkpath(dirname(log))
    # Delimited per run. The log is appended to, and the failure report below shows its tail — so
    # without a marker a run that writes NOTHING (an exec that dies before any output) reports the
    # previous run's stack trace as though it were this one's. That sent this exact investigation
    # chasing an error that had already been fixed.
    io = try
        h = open(log, "a")
        println(h, "\n=== slate --ai · host starting on port $port at $(Dates.now()) ===")
        flush(h)
        h
    catch
        devnull
    end
    proc = run(pipeline(cmd; stdin = devnull, stdout = io, stderr = io); wait = false)
    _EMBEDDED[] = proc
    # A host that dies on boot (a port already taken, a broken env) otherwise looks identical to one
    # that is merely slow: the caller waits out its whole deadline and then reports "not answering
    # yet", with the actual reason sitting in a log file. Give it a moment to fail, and if it does,
    # say why HERE with the tail of what it wrote.
    for _ in 1:20
        sleep(0.25)
        process_running(proc) || break
    end
    if !process_running(proc)
        _EMBEDDED[] = nothing
        error("slate --ai: the Kaimon host exited immediately (code $(proc.exitcode)).\n" *
              _log_tail(log, 12) * "\nFull log: $log")
    end
    @info "slate: embedded Kaimon host started" port root = _embedded_root() log
    return true
end

# Last `n` non-blank lines THIS RUN wrote, indented, for an error message. Only lines after the
# final run marker count: the log is appended to, so without that cut a run that produced no output
# would be reported using the previous run's failure.
function _log_tail(path::AbstractString, n::Int)
    lines = try; readlines(path); catch; return ""; end
    i = findlast(l -> startswith(l, "=== slate --ai · host starting"), lines)
    i === nothing || (lines = lines[(i + 1):end])
    filter!(!isempty ∘ strip, lines)
    isempty(lines) && return "    (the host wrote nothing before exiting)"
    return join(("    " * l for l in last(lines, n)), "\n")
end

"""
    stop_embedded_kaimon!() -> nothing

Stop the embedded host, if THIS process started it. A host the user was already running is left
alone — `_EMBEDDED` is only set by [`start_embedded_kaimon!`](@ref), so attaching never adopts one.
"""
function stop_embedded_kaimon!()
    p = _EMBEDDED[]
    p === nothing && return nothing
    _EMBEDDED[] = nothing
    try
        process_running(p) && kill(p)          # SIGTERM: the host stops its own extensions on the way out
    catch
    end
    for _ in 1:20                              # give it that chance before forcing anything
        process_running(p) || break
        sleep(0.25)
    end
    _reap_embedded_strays!()
    return nothing
end

"""
    _reap_embedded_strays!() -> Int

Kill processes belonging to THIS Slate's embedded host that outlived it, and return how many. The
host is supposed to stop its extensions on SIGTERM; when it does not (or when it was killed
outright) they are reparented to init and keep holding their hub port, so the next `--ai` finds the
port taken and refuses to start.

Identification is exact rather than by command line: every embedded process was launched with
`XDG_CONFIG_HOME` pointing into our private root, and nothing else on the machine has that. So a
Kaimon the user runs themselves, and its Slate extension, are never candidates — which is the whole
point, since the two are meant to coexist.
"""
function _reap_embedded_strays!()
    mine = _embedded_config_home()
    n = 0
    for pid in vcat(_pids_matching("Kaimon"), _pids_matching("KaimonSlate"))
        pid == getpid() && continue
        _proc_env(pid, "XDG_CONFIG_HOME") == mine || continue
        _kill_pid(pid); n += 1
    end
    n > 0 && @info "slate: cleaned up $n leftover process(es) from a previous embedded Kaimon"
    return n
end

# One environment variable of a running process, or "" when it can't be read. `ps -E` on macOS,
# /proc on Linux; unsupported elsewhere, where this simply finds nothing and reaps nothing.
function _proc_env(pid::Integer, name::AbstractString)
    try
        if Sys.islinux()
            raw = read("/proc/$pid/environ", String)
            for kv in split(raw, '\0'; keepempty = false)
                startswith(kv, name * "=") && return String(kv[(length(name) + 2):end])
            end
        elseif Sys.isapple()
            out = readchomp(pipeline(`ps -Eww -p $pid`; stderr = devnull))
            m = match(Regex("(?:^|\\s)" * name * "=(\\S*)"), out)
            m === nothing || return String(m.captures[1])
        end
    catch
    end
    return ""
end
