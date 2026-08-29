#!/usr/bin/env bash
# Verify the harness supports everything the batch fabric depends on. Runs entirely through ssh to
# the login node, which is the same path the hub will use.
set -uo pipefail

HOST="${1:-slate-slurm}"
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo "== harness smoke test against '$HOST' =="

echo "-- ssh + client tools"
if ssh -o BatchMode=yes "$HOST" true 2>/dev/null; then ok "ssh non-interactive"; else bad "ssh non-interactive"; exit 1; fi
check "whoami" "$(ssh "$HOST" whoami 2>/dev/null)" "slate"

echo "-- scheduler visible"
NODES=$(ssh "$HOST" "sinfo -h -o '%n' | sort | tr '\n' ',' " 2>/dev/null)
check "both compute nodes present" "$NODES" "c1,c2,"
IDLE=$(ssh "$HOST" "sinfo -h -t idle -o '%D' -p compute" 2>/dev/null | tr -d ' \n')
check "both nodes idle" "$IDLE" "2"

echo "-- srun on a compute node"
WHERE=$(ssh "$HOST" "srun -p compute -n1 hostname -s" 2>/dev/null)
if [ "$WHERE" = "c1" ] || [ "$WHERE" = "c2" ]; then ok "srun landed on $WHERE"; else bad "srun landed on '$WHERE'"; fi

echo "-- shared filesystem"
STAMP="smoke-$$-$RANDOM"
ssh "$HOST" "srun -p compute -n1 sh -c 'echo $STAMP > /scratch/$STAMP.txt'" >/dev/null 2>&1
check "compute-node write visible on login node" "$(ssh "$HOST" "cat /scratch/$STAMP.txt 2>/dev/null")" "$STAMP"

echo "-- array job (the fan-out primitive)"
ssh "$HOST" "mkdir -p /scratch/$STAMP.d" >/dev/null 2>&1
JID=$(ssh "$HOST" "sbatch --parsable -p compute --array=1-8 -o /dev/null \
        --wrap='echo \$SLURM_ARRAY_TASK_ID > /scratch/$STAMP.d/\$SLURM_ARRAY_TASK_ID'" 2>/dev/null)
if [ -n "$JID" ]; then ok "array submitted as $JID"; else bad "array submit"; fi
for _ in $(seq 1 60); do
    n=$(ssh "$HOST" "ls /scratch/$STAMP.d 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
    [ "$n" = "8" ] && break
    sleep 2
done
check "all 8 array elements wrote output" "$(ssh "$HOST" "ls /scratch/$STAMP.d | wc -l" 2>/dev/null | tr -d ' ')" "8"

echo "-- batched poll (one squeue for many jobs)"
ssh "$HOST" "squeue -h -o '%i %T' -j $JID" >/dev/null 2>&1 && ok "squeue -j accepts the array id" || bad "squeue -j"

echo "-- job naming as the dedup token"
ssh "$HOST" "sbatch -p compute --job-name=keytest-abc123 -o /dev/null --wrap='sleep 20'" >/dev/null 2>&1
sleep 2
NAMED=$(ssh "$HOST" "squeue -h --name=keytest-abc123 -o '%i' | wc -l" 2>/dev/null | tr -d ' ')
if [ "$NAMED" -ge 1 ]; then ok "squeue --name finds a job by key"; else bad "squeue --name (got '$NAMED')"; fi
ssh "$HOST" "scancel --name=keytest-abc123" >/dev/null 2>&1 && ok "scancel by name" || bad "scancel by name"

echo "-- accounting (sacct, for explaining failures)"
if ssh "$HOST" "sacct -n -j $JID -o JobID,State 2>/dev/null | head -1" 2>/dev/null | grep -q .; then
    ok "sacct returns records"
else
    bad "sacct returns records (accounting may still be initialising)"
fi

echo "-- julia present on compute nodes"
JV=$(ssh "$HOST" "srun -p compute -n1 julia --version" 2>/dev/null)
case "$JV" in
  "julia version"*) ok "julia on a compute node ($JV)" ;;
  *)                bad "julia on a compute node (got '$JV')" ;;
esac

echo "-- dependency=singleton (duplicate submission guard)"
ssh "$HOST" "sbatch -p compute --job-name=single-xyz --dependency=singleton -o /dev/null --wrap='sleep 5'" >/dev/null 2>&1 && \
    ok "singleton dependency accepted" || bad "singleton dependency accepted"
ssh "$HOST" "scancel --name=single-xyz" >/dev/null 2>&1

ssh "$HOST" "rm -rf /scratch/$STAMP.txt /scratch/$STAMP.d" >/dev/null 2>&1

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
