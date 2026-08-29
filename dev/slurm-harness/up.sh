#!/usr/bin/env bash
# Bring the local SLURM cluster up (and generate the ssh identity the hub will use).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
HERE="$(pwd)"
KEY="$HERE/ssh/id_slate"

case "${1:-up}" in
  --down)  docker compose down; exit 0 ;;
  --clean) docker compose down -v; exit 0 ;;
  --logs)  docker compose logs -f "${2:-}"; exit 0 ;;
esac

mkdir -p ssh
printf '*\n!.gitignore\n' > ssh/.gitignore
if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C 'slate-slurm-harness' -f "$KEY"
    echo "generated $KEY"
fi
cp "$KEY.pub" ssh/authorized_keys

docker build -t slate-slurm:latest .
docker compose up -d

echo "waiting for the controller to see both nodes..."
for _ in $(seq 1 60); do
    if docker compose exec -T slurmctld sinfo -h -o '%T' 2>/dev/null | grep -qx 'idle'; then
        break
    fi
    sleep 2
done

docker compose exec -T slurmctld sinfo || true

cat <<EOF

Cluster is up. Add this to ~/.ssh/config so the hub can reach it the same way it reaches a real
login node:

Host slate-slurm
    HostName 127.0.0.1
    Port 2222
    User slate
    IdentityFile $KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Then: ssh slate-slurm sinfo
Shared filesystem: /scratch (all nodes)   Home: /home/slate (all nodes)
EOF
