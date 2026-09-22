#!/usr/bin/env julia
# Dev helper: start an embedded Kaimon host (the `slate --ai` path) for THIS worktree, so the
# MCP toolset is available against the worktree's own hub instead of the installed extension's.
#
# Usage:
#   julia --project=. dev/aihub.jl [mcp_port]          # default 2929
#
# Env (all optional):
#   SLATE_KAIMON_PATH=<dir>  build the host against a local Kaimon checkout, not the registry
#   KAIMONSLATE_PORT=8902    the hub the spawned extension binds
#   KAIMONSLATE_HOME=<dir>   state home (default: <worktree>/.kaimonslate-dev)
#
# The home is pinned on purpose. `_embedded_env_vars` deliberately points the child extension at
# the user's REAL Slate homes so `--ai` sees their actual notebooks; for a worktree experiment that
# is the wrong trade, because a prototype should not be able to write their publish ledger.
using Sockets

const ROOT = dirname(@__DIR__)
if get(ENV, "KAIMONSLATE_HOME", "") == "" && get(ENV, "KAIMONSLATE_CONFIG_HOME", "") == ""
    ENV["KAIMONSLATE_HOME"] = joinpath(ROOT, ".kaimonslate-dev")
end
if get(ENV, "KAIMONSLATE_PORT", "") == ""
    s = Sockets.listen(Sockets.localhost, 0)
    ENV["KAIMONSLATE_PORT"] = string(Int(Sockets.getsockname(s)[2]))
    close(s)
end

using KaimonSlate
const SH = KaimonSlate.SlateHome
SH.ensure_homes!()

const MCP_PORT = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 2929
const HUB_PORT = parse(Int, ENV["KAIMONSLATE_PORT"])

println("""
┌ KaimonSlate --ai host
│  worktree : $ROOT
│  kaimon   : $(get(ENV, "SLATE_KAIMON_PATH", "(registry)"))
│  mcp      : $MCP_PORT
│  hub      : http://127.0.0.1:$HUB_PORT
└  building the host env (first run precompiles; minutes)…
""")
flush(stdout)

KaimonSlate.start_embedded_kaimon!(MCP_PORT; online = m -> (println("  ", m); flush(stdout))) ||
    error("an embedded host is already running in this process")

println("\n✓ host up — MCP on $MCP_PORT, hub on http://127.0.0.1:$HUB_PORT")
flush(stdout)

atexit(() -> (try; KaimonSlate.stop_embedded_kaimon!(); catch; end))
while true; sleep(3600); end
