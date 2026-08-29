#!/usr/bin/env bash
# Ship the batch-fabric sources to the cluster and run the end-to-end sweep on the login node.
#   ./integration.sh [ssh-host]
set -euo pipefail

HOST="${1:-slate-slurm}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCDIR="$(cd "$HERE/../../src" && pwd)"

echo "== shipping sources to $HOST:/scratch/slate/src =="
ssh "$HOST" 'mkdir -p /scratch/slate/src /scratch/slate/cas'
scp -q "$SRCDIR"/memostore.jl "$SRCDIR"/slatetask.jl \
       "$SRCDIR"/batchlauncher.jl "$SRCDIR"/batchsweep.jl \
       "$HOST":/scratch/slate/src/
scp -q "$HERE"/integration.jl "$HOST":/scratch/slate/

echo "== running the sweep on the login node =="
ssh "$HOST" 'cd /scratch/slate && julia --startup-file=no integration.jl'
