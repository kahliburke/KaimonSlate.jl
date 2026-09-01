# ── Authenticating to a cluster that will not take a key ─────────────────────────────────────
#
# Plenty of production clusters refuse public keys outright and want a password plus a second
# factor — a code, or a push you accept on a phone. Slate cannot type either, so `BatchMode=yes`
# (which every ssh call here uses) fails before it starts: "Permission denied (keyboard-interactive)".
#
# The fix is NOT to teach every call site about passwords. It is to make sure a multiplexed MASTER
# connection exists before they run: once one does, `BatchMode=yes` rides it and never sees a
# prompt. So exactly one connection has to be interactive, and only when there isn't one already.
#
#   ensure_master!(host)          →  ssh -O check; if that fails, open one interactively
#   the interactive open          →  ssh -M -N with SSH_ASKPASS pointed at `askpass.sh`
#   askpass.sh                    →  hands the PROMPT TEXT here, blocks for the answer
#   the notebook                  →  shows the prompt, sends back what the user typed
#
# Prompt-DRIVEN rather than scripted, because the conversation varies: password then code, or
# password then a push that just takes a while, or Duo's "passcode or option" menu. Whatever ssh
# asks is what gets shown.
#
# The rendezvous is files in a private directory rather than a socket, so the helper can be plain
# `/bin/sh` — no curl, no Julia, nothing that might be missing on a login node's `$PATH`. An answer
# is written mode 600 in a mode 700 directory and deleted as soon as it is read; it is a secret at
# rest for the milliseconds between the hub writing it and ssh consuming it.

module SshAuth

using Dates

const ASK_SUFFIX = ".ask"
const REPLY_SUFFIX = ".reply"

# Slate's cache home, resolved the same way everywhere that needs it.
function cache_root()
    base = get(ENV, "KAIMONSLATE_CACHE_HOME", "")
    home = get(ENV, "KAIMONSLATE_HOME", "")
    return !isempty(base) ? abspath(expanduser(base)) :
           !isempty(home) ? joinpath(abspath(expanduser(home)), "cache") :
           joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "kaimonslate")
end

"""
    control_path() -> String

The ssh `ControlPath` every part of Slate uses. ONE socket per (user, host, port), shared by the
batch fabric, the regions, and anything else that reaches a host — because authenticating is a
thing a PERSON does, and doing it twice for one cluster because two subsystems each opened their
own connection would be the wrong answer twice over.

`%C` rather than a hash of our own: ssh expands it, and it already distinguishes the things that
make connections different (user, host, port) which a hash of the host string alone does not.
"""
function control_path()
    # A control socket is a Unix domain socket, so the WHOLE path has to fit in `sockaddr_un`: 104
    # bytes on macOS, 108 on Linux. `%C` expands to 40 hex characters and ssh appends a ~17-char
    # suffix while it creates the file, so the directory gets what is left — which a cache home can
    # easily exceed (an isolated one under `.claude/worktrees/…` is past it on its own). Falls back
    # to somewhere short rather than failing with `unix_listener: path too long`, which is what ssh
    # says and is not a sentence that explains itself.
    budget(d) = length(d) + 1 + 40 + 18
    for d in (joinpath(cache_root(), "mux"),
              isempty(get(ENV, "TMPDIR", "")) ? "" : joinpath(ENV["TMPDIR"], "slate-mux"),
              "/tmp/slate-mux")
        isempty(d) && continue
        budget(d) <= 100 || continue
        try; mkpath(d); chmod(d, 0o700); catch; continue; end
        return joinpath(d, "%C")
    end
    # Nothing fit — extremely unlikely, and an unmuxed connection still works (it just re-prompts).
    return ""
end

# Where a prompt and its answer meet. Under the cache home so it is per-user and disposable, and
# 0700 so nothing else on a shared machine can read an answer in flight.
function rendezvous_dir()
    d = joinpath(cache_root(), "sshauth")
    mkpath(d)
    try; chmod(d, 0o700); catch; end
    return d
end

"""
    askpass_script() -> String

Path to the helper ssh calls for each prompt. Written on demand so it always matches this version,
and kept beside the rendezvous it uses.

ssh passes the prompt text as the helper's first argument; the helper publishes it, waits for a
reply, and prints the reply on stdout. That is the whole of the askpass protocol.
"""
function askpass_script()
    d = rendezvous_dir()
    p = joinpath(d, "askpass.sh")
    # Raw string: this is shell, and every `$` in it belongs to the shell rather than to Julia.
    src = replace(raw"""
    #!/bin/sh
    # Written by KaimonSlate (src/sshauth.jl). Answers one ssh prompt by asking the notebook.
    set -u
    dir="${SLATE_SSHAUTH_DIR:?}"
    id="${SLATE_SSHAUTH_ID:-x}-$(date +%s)-$$"
    ask="$dir/$id@ASK@"
    reply="$dir/$id@REPLY@"

    # The prompt as ssh phrased it, behind the host it is for. One line each, because a prompt is
    # one line; anything stranger is still safe to show verbatim.
    umask 077
    printf '%s\t%s\n' "${SLATE_SSHAUTH_HOST:-?}" "$1" > "$ask"

    # Wait for the notebook. The limit is generous because a push notification is answered by a
    # human reaching for a phone, not by a machine.
    n=0
    limit=${SLATE_SSHAUTH_TIMEOUT:-300}
    while [ ! -f "$reply" ]; do
        n=$((n + 1))
        [ "$n" -gt "$((limit * 10))" ] && { rm -f "$ask"; exit 1; }
        sleep 0.1
    done

    cat "$reply"
    rm -f "$reply" "$ask"
    """, "@ASK@" => ASK_SUFFIX, "@REPLY@" => REPLY_SUFFIX)
    # Rewrite only when it differs, so a running ssh never sees the file change underneath it.
    cur = isfile(p) ? read(p, String) : ""
    if cur != src
        tmp = p * ".tmp"
        write(tmp, src); chmod(tmp, 0o700); mv(tmp, p; force = true)
    end
    return p
end

"""
    pending() -> Vector{NamedTuple}

Prompts waiting for an answer: `(; id, host, prompt, at)`, oldest first. Read by the hub, which
shows them and calls `answer!`.
"""
function pending()
    d = rendezvous_dir()
    out = NamedTuple[]
    for f in sort(readdir(d))
        endswith(f, ASK_SUFFIX) || continue
        p = joinpath(d, f)
        txt = try; read(p, String); catch; continue; end
        parts = split(chomp(txt), '\t'; limit = 2)
        length(parts) == 2 || continue
        push!(out, (; id = f[1:end-length(ASK_SUFFIX)], host = String(parts[1]),
                      prompt = String(parts[2]), at = try; mtime(p); catch; 0.0; end))
    end
    sort!(out; by = x -> x.at)
    return out
end

"""
    answer!(id, text) -> Bool

Hand one prompt its answer. Written mode 600; the helper deletes it the moment it has been read.
"""
function answer!(id::AbstractString, text::AbstractString)
    d = rendezvous_dir()
    isfile(joinpath(d, id * ASK_SUFFIX)) || return false
    p = joinpath(d, id * REPLY_SUFFIX)
    tmp = p * ".tmp"
    open(io -> print(io, text), tmp, "w")
    chmod(tmp, 0o600)
    mv(tmp, p; force = true)     # atomic: the helper never reads half an answer
    return true
end

"Abandon a prompt — the user dismissed the dialog, so ssh should give up rather than hang."
function cancel!(id::AbstractString)
    d = rendezvous_dir()
    for s in (ASK_SUFFIX, REPLY_SUFFIX); rm(joinpath(d, id * s); force = true); end
    return nothing
end

"Forget prompts nobody ever answered, so a stale one cannot surface in a later session."
function sweep_stale!(; older_than::Real = 900)
    d = rendezvous_dir()
    now = time()
    for f in readdir(d)
        (endswith(f, ASK_SUFFIX) || endswith(f, REPLY_SUFFIX)) || continue
        p = joinpath(d, f)
        try; now - mtime(p) > older_than && rm(p; force = true); catch; end
    end
    return nothing
end

end # module SshAuth
