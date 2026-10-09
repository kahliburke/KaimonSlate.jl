# Every scheduler command Slate sends a cluster, counted. Sites ask users to keep the aggregate rate of
# their scheduler queries low (NERSC asks for one or two a minute across all of a user's jobs), so the
# hub counts what it sends by host, command and the Slate function that sent it, warns when a host's
# last minute goes over budget, and appends one record per host and minute to a history file in the
# hub's cache. `run_there` notes each script it runs; the counting is by the script's text.

# A scheduler client invoked by the script. Not `command -v sinfo` (a check that the tool exists), and
# not text in a heredoc: a batch script's own `srun` lines run later, on the node, as the job.
const _SCHED_CMD = r"(?<![\w./-])(squeue|sacct|sinfo|sbatch|salloc|srun|scancel|scontrol|sprio|sshare|qstat|qsub|qdel|qselect|qalter|pbsnodes)(?![\w-])"
const _HEREDOC = r"<<-?\s*'?\"?(\w+)'?\"?[^\n]*\n.*?\n\s*\1\s*(\n|$)"s

function sched_commands(script::AbstractString)
    s = replace(String(script), _HEREDOC => "\n")
    s = replace(s, r"command\s+-v\s+\w+" => "")
    return String[m.captures[1] for m in eachmatch(_SCHED_CMD, s)]
end

const _SCHED_LOCK = ReentrantLock()
const _SCHED_TOTAL = Dict{Tuple{String,String,String},Int}()          # (host, command, caller) → since the hub started
const _SCHED_RECENT = Tuple{Float64,String,String,String}[]          # (time, host, command, caller), the last `_SCHED_KEEP_S`
const _SCHED_KEEP_S = 600.0
const _SCHED_WARNED = Dict{String,Float64}()                          # host → when it was last warned about
const _SCHED_MINUTE = Ref(0)                                          # the minute the history last covered

"Scheduler commands a host may be sent per minute before the hub warns. `KAIMONSLATE_SCHED_BUDGET` sets it."
sched_budget() = something(tryparse(Float64, get(ENV, "KAIMONSLATE_SCHED_BUDGET", "")), 2.0)

_sched_history_path() = joinpath(SlateHome.cache_home(), "sched_calls.jsonl")

# The Slate function that asked: the first frame on the stack outside the plumbing every remote command
# passes through.
const _SCHED_PLUMBING = (:run_there, :_run_on, :_ssh, :_ssh_test, :note_sched_calls!, :_sched_caller,
                         :stacktrace, :backtrace, :_run_capture)
function _sched_caller()
    for fr in stacktrace()
        f = fr.func
        (f in _SCHED_PLUMBING || startswith(String(f), "#") || startswith(String(f), "kwcall")) && continue
        file = basename(String(fr.file))
        file in ("schedcalls.jl", "remotestore.jl", "boot.jl", "essentials.jl") && continue
        return String(f)
    end
    return "?"
end

"""
    note_sched_calls!(host, script) -> Int

Count the scheduler commands in `script`, sent to `host`. Returns how many it found.
"""
function note_sched_calls!(host::AbstractString, script::AbstractString)
    cmds = sched_commands(script)
    isempty(cmds) && return 0
    h = isempty(host) ? "local" : String(host)
    caller = _sched_caller()
    now = time()
    warn = nothing
    lock(_SCHED_LOCK) do
        _flush_minute!(now)
        for c in cmds
            k = (h, c, caller)
            _SCHED_TOTAL[k] = get(_SCHED_TOTAL, k, 0) + 1
            push!(_SCHED_RECENT, (now, h, c, caller))
        end
        n = count(e -> e[2] == h && now - e[1] <= 60, _SCHED_RECENT)
        if n > sched_budget() && now - get(_SCHED_WARNED, h, 0.0) > _SCHED_KEEP_S
            _SCHED_WARNED[h] = now
            warn = (n, _sched_breakdown(h, 60.0, now))
        end
    end
    warn === nothing ||
        @warn "scheduler: $(warn[1]) commands sent to $h in the last minute, over the budget of $(sched_budget())/min" breakdown = warn[2]
    return length(cmds)
end

# "squeue ×5 (find_allocation), srun ×2 (_in_allocation)" for one host over the last `window` seconds.
function _sched_breakdown(h::AbstractString, window::Real, now::Real = time())
    by = Dict{Tuple{String,String},Int}()
    for (t, host, c, caller) in _SCHED_RECENT
        (host == h && now - t <= window) || continue
        by[(c, caller)] = get(by, (c, caller), 0) + 1
    end
    return join(("$c ×$n ($caller)" for ((c, caller), n) in sort!(collect(by); by = last, rev = true)), ", ")
end

# Drop what is older than the window, and write each finished minute to the history file: one line per
# host that was sent anything, `{"minute": …, "host": …, "total": n, "by": {"squeue find_allocation": n}}`.
function _flush_minute!(now::Real)
    m = floor(Int, now / 60)
    if _SCHED_MINUTE[] == 0
        _SCHED_MINUTE[] = m
    elseif m > _SCHED_MINUTE[]
        prev = _SCHED_MINUTE[]
        rows = Dict{String,Dict{String,Int}}()
        for (t, h, c, caller) in _SCHED_RECENT
            floor(Int, t / 60) == prev || continue
            d = get!(Dict{String,Int}, rows, h)
            d["$c $caller"] = get(d, "$c $caller", 0) + 1
        end
        if !isempty(rows)
            try
                p = _sched_history_path(); mkpath(dirname(p))
                open(p, "a") do io
                    for (h, d) in sort!(collect(rows); by = first)
                        by = join(("\"" * _jesc(k) * "\": $v" for (k, v) in sort!(collect(d); by = first)), ", ")
                        println(io, "{\"minute\": \"", Dates.format(Dates.unix2datetime(prev * 60), "yyyy-mm-ddTHH:MM"),
                                "Z\", \"host\": \"", _jesc(h), "\", \"total\": ", sum(values(d)), ", \"by\": {", by, "}}")
                    end
                end
            catch
            end
        end
        _SCHED_MINUTE[] = m
    end
    filter!(e -> now - e[1] <= _SCHED_KEEP_S, _SCHED_RECENT)
    return nothing
end
_jesc(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"")

"""
    sched_calls(; window = 600) -> Vector{NamedTuple}

What the hub has sent each host's scheduler: per host, the commands in the last minute and in the last
`window` seconds (each by command and caller), and the total since the hub started.
"""
function sched_calls(; window::Real = _SCHED_KEEP_S)
    now = time()
    lock(_SCHED_LOCK) do
        _flush_minute!(now)
        hosts = sort!(unique!([k[1] for k in keys(_SCHED_TOTAL)]))
        [(; host = h,
            last_minute = count(e -> e[2] == h && now - e[1] <= 60, _SCHED_RECENT),
            window = count(e -> e[2] == h && now - e[1] <= window, _SCHED_RECENT),
            window_s = Float64(window),
            breakdown = _sched_breakdown(h, window, now),
            total = sum(v for (k, v) in _SCHED_TOTAL if k[1] == h)) for h in hosts]
    end
end

"""
    sched_unflushed(host) -> (minute, Dict("command caller" => n))

The counts not yet in the history file: those of the minute in progress (as a unix minute), which is
written once a later minute has a call in it.
"""
function sched_unflushed(host::AbstractString)
    lock(_SCHED_LOCK) do
        d = Dict{String,Int}()
        m = _SCHED_MINUTE[]
        for (t, h, c, caller) in _SCHED_RECENT
            (h == host && floor(Int, t / 60) == m) || continue
            d["$c $caller"] = get(d, "$c $caller", 0) + 1
        end
        (m, d)
    end
end
