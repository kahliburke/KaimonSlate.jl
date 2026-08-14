#!/usr/bin/env bash
# Bring up Ollama, republish loopback services on 0.0.0.0, then run Kaimon.
#
# Kaimon's TUI is not a client — it starts its own MCP server in-process, so it CANNOT
# attach to a running headless instance (they'd contend for the port). Pass --tui to run
# the dashboard instead of the headless server:
#   docker run -it ... slate:dev --tui
set -euo pipefail

KAIMON_PORT="${KAIMON_PORT:-2828}"
SLATE_PORT="${SLATE_PORT:-8765}"
QDRANT_PORT="${QDRANT_PORT:-6333}"

# Forwarders are individually opt-out; Qdrant is off by default since it's rarely
# wanted from the host. Ollama needs no forwarder — it binds 0.0.0.0 via OLLAMA_HOST.
EXPOSE_KAIMON="${EXPOSE_KAIMON:-1}"
EXPOSE_SLATE="${EXPOSE_SLATE:-1}"
EXPOSE_QDRANT="${EXPOSE_QDRANT:-0}"

log() { printf '[entrypoint] %s\n' "$*"; }

# headless : MCP server, no dashboard (default; lightest)
# tmux     : TUI on a persistent pty — attach any time with
#              docker exec -it <container> tmux attach -t kaimon
#            and detach with Ctrl-B D, leaving Kaimon running
# tui      : TUI in the foreground; requires `docker run -it`
mode="${KAIMON_MODE:-headless}"
case "${1:-}" in
    --tui)  mode=tui;  shift ;;
    --tmux) mode=tmux; shift ;;
esac

# ── Seed the writable depot ───────────────────────────────────────────────────
# Pkg reads registries from every depot but writes only to the first, so `add` and
# `registry update` fail if the mounted depot has no registry of its own.
mkdir -p /work/depot
if [ ! -d /work/depot/registries ] && [ -d /opt/julia-depot/registries ]; then
    log "seeding registries into the mounted depot"
    cp -r /opt/julia-depot/registries /work/depot/registries
fi

# ── Ollama ────────────────────────────────────────────────────────────────────
log "starting ollama on ${OLLAMA_HOST:-0.0.0.0:11434}"
ollama serve &
for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:11434/api/tags" >/dev/null && break
    sleep 1
done || true

if ! ollama list 2>/dev/null | grep -q "${EMBEDDING_MODEL%%:*}"; then
    log "embedding model ${EMBEDDING_MODEL} missing; pulling"
    ollama pull "${EMBEDDING_MODEL}" || log "WARNING: pull failed, semantic search degraded"
fi

# ── Republish loopback services on 0.0.0.0 ────────────────────────────────────
# Kaimon's MCP server binds 127.0.0.1 by design (MCPServer.jl), so a published port
# would reach nothing. socat listens on all interfaces and dials loopback, which also
# makes the peer address 127.0.0.1 — the only source `lax` mode accepts (security.jl).
forward() {
    socat TCP-LISTEN:"$1",fork,reuseaddr TCP:127.0.0.1:"$2" &
    log "forwarding 0.0.0.0:$1 -> 127.0.0.1:$2 ($3)"
}
# Published ports are configurable because some hosts dictate them — Hugging Face Spaces,
# for instance, only routes 7860.
[ "$EXPOSE_KAIMON" = "1" ] && forward "${KAIMON_PUBLISH_PORT:-12828}" "${KAIMON_PORT}" kaimon-mcp
[ "$EXPOSE_SLATE"  = "1" ] && forward "${SLATE_PUBLISH_PORT:-18765}"  "${SLATE_PORT}"  slate-hub
[ "$EXPOSE_QDRANT" = "1" ] && forward "${QDRANT_PUBLISH_PORT:-16333}" "${QDRANT_PORT}" qdrant-http

shutdown() { log "shutting down"; kill 0; }
trap shutdown TERM INT

# ── Kaimon ────────────────────────────────────────────────────────────────────
# Invoke Julia directly instead of the `kaimon` shim. Pkg.Apps bakes the install-time depot
# into that launcher and exports it unconditionally:
#     export JULIA_DEPOT_PATH=/opt/julia-depot
# which overrides the runtime value, so DEPOT_PATH[1] becomes the READ-ONLY baked depot.
# Kaimon then builds its extension env at `first(DEPOT_PATH)/environments/kaimon-ext/<ns>`
# and dies with EACCES as a non-root user — the extension silently never starts. Replicating
# the shim's julia flags here keeps our JULIA_DEPOT_PATH intact.
KAIMON_APP_ENV=/opt/julia-depot/environments/apps/Kaimon
kaimon_run() {
    JULIA_LOAD_PATH="$KAIMON_APP_ENV" \
    exec julia --startup-file=no --threads=auto,2 --gcthreads=1 -m Kaimon "$@"
}
kaimon_cmdline() {
    printf 'JULIA_LOAD_PATH=%s julia --startup-file=no --threads=auto,2 --gcthreads=1 -m Kaimon %s' \
        "$KAIMON_APP_ENV" "$*"
}

case "$mode" in
  tui)
    log "starting kaimon TUI in the foreground on port ${KAIMON_PORT} (needs docker run -it)"
    kaimon_run -p "${KAIMON_PORT}" "$@"
    ;;
  tmux)
    # TUI mode also hosts the MCP server, so this is one instance serving both.
    log "starting kaimon TUI under tmux on port ${KAIMON_PORT}"
    tmux new-session -d -s kaimon "$(kaimon_cmdline -p "${KAIMON_PORT}" "$@")"
    log "attach with:  docker exec -it <container> tmux attach -t kaimon   (detach: Ctrl-B D)"
    # Hold PID 1 for as long as the session lives, so the container's lifetime
    # tracks Kaimon rather than exiting the moment tmux daemonises.
    while tmux has-session -t kaimon 2>/dev/null; do sleep 5; done
    log "tmux session ended; exiting"
    ;;
  *)
    log "starting kaimon --headless -p ${KAIMON_PORT}"
    kaimon_run --headless -p "${KAIMON_PORT}" "$@"
    ;;
esac
