#!/usr/bin/env bash
# slate-serve-bootstrap.sh — remote half of the `rsync-serve` publish target.
# Idempotent: run on every publish. Expects slate_serve.jl already copied to the
# control dir. Args: NAME ROOT BIND PORT
set -euo pipefail
NAME="$1"; ROOT="$2"; BIND="$3"; PORT="$4"
CTRL="$HOME/.local/share/slate-serve/$NAME"
mkdir -p "$CTRL"

cat > "$CTRL/Project.toml" <<EOF
[deps]
HTTP = "cd3eb016-35fb-5094-929b-558a96fad6f3"

[compat]
HTTP = "2"
EOF

JULIA="$(command -v julia || true)"
[ -z "$JULIA" ] && { echo "ERROR: julia not found on PATH on the remote host" >&2; exit 3; }

# One-time env setup (HTTP resolve + precompile). Cheap on reruns (Manifest present).
if [ ! -f "$CTRL/Manifest.toml" ]; then
  "$JULIA" --project="$CTRL" -e 'using Pkg; Pkg.add(name="HTTP", version="2"); Pkg.precompile()'
fi

# Prefer a persistent systemd --user service; fall back to nohup where user systemd
# isn't available (no session bus).
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/slate-serve-$NAME.service" <<EOF
[Unit]
Description=Slate static site ($NAME)
After=network.target

[Service]
Environment=SLATE_SERVE_ROOT=$ROOT
Environment=SLATE_SERVE_HOST=$BIND
Environment=SLATE_SERVE_PORT=$PORT
ExecStart=$JULIA --project=$CTRL $CTRL/slate_serve.jl
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable "slate-serve-$NAME.service" >/dev/null 2>&1 || true
  systemctl --user restart "slate-serve-$NAME.service"
  loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true   # survive logout/reboot
  echo "OK: systemd --user slate-serve-$NAME serving $ROOT on $BIND:$PORT"
else
  pkill -f "slate_serve.jl.*$NAME" 2>/dev/null || true
  SLATE_SERVE_ROOT="$ROOT" SLATE_SERVE_HOST="$BIND" SLATE_SERVE_PORT="$PORT" \
    setsid nohup "$JULIA" --project="$CTRL" "$CTRL/slate_serve.jl" > "$CTRL/serve.log" 2>&1 &
  echo "OK: nohup slate-serve-$NAME serving $ROOT on $BIND:$PORT (no user systemd)"
fi
