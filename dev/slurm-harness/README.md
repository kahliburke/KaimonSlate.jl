# Local SLURM cluster for batch-fabric development

A six-container SLURM cluster with a shared filesystem, reachable over ssh exactly the way a real
login node is. Nothing in the batch fabric can be tested without it.

    ./up.sh              build and start (generates an ssh keypair on first run)
    ./smoke.sh           verify everything the batch fabric depends on
    ./up.sh --logs c1    follow one service
    ./up.sh --down       stop, keep volumes
    ./up.sh --clean      stop and delete volumes

`up.sh` prints an `~/.ssh/config` block. Once it is in place:

    ssh slate-slurm sinfo

## Layout

| container | role |
|---|---|
| `login` | ssh entry point, SLURM client tools, Julia. The only thing the hub talks to. |
| `slurmctld` | controller |
| `c1`, `c2` | compute nodes, 4 cores each (8 slots total) |
| `slurmdbd` + `mysql` | accounting, so `sacct` works |

Partitions: `compute` (default, no time limit) and `short` (10 min cap, for exercising backfill).

Shared across every node: `/scratch` (put the CAS here) and `/home/slate`.

The hub reaches this cluster over ssh and never mounts its filesystem, which is the same
constraint a laptop has against a real cluster.

## SLURM version

Default is **24.11.5**, from `debian:trixie`. Version is chosen by base image, so there are no
source builds:

    docker build --build-arg BASE_IMAGE=ubuntu:22.04 -t slate-slurm:2108 .

| base image | SLURM | works in a container |
|---|---|---|
| `ubuntu:22.04` | 21.08.5 | yes |
| `ubuntu:24.04` | 23.11.4 | **no**, see below |
| `debian:trixie` | 24.11.5 | yes (default) |

**23.11 cannot run in this harness.** From 23.11, slurmd places slurmstepd in a systemd scope over
dbus at startup, and initialises a cgroup context even under `TaskPlugin=task/none` and
`ProctrackType=proctrack/linuxproc`. Containers have neither systemd nor dbus, and running
`privileged` with `cgroup: host` does not help because the requirement is dbus, not privilege.
24.x added `CgroupPlugin=disabled`, which is the clean opt-out and what `etc/cgroup.conf` uses.
21.08 predates the behaviour entirely.

This is a limitation of *containerising* 23.11, not of supporting it. A real 23.11 site runs
slurmd on a real node under systemd, where none of this applies. The batch fabric shells out to
`sbatch`/`squeue`/`scancel`/`sacct` and never links libslurm or speaks the RPC protocol, so it is
insensitive to the site's version. Keep it that way.

## What the harness cannot test

- **Cross-ISA heterogeneity.** Every container shares the host's architecture, so
  `JULIA_CPU_TARGET` multiversioning and per-architecture depots cannot be exercised locally.
  Different `CPUs`/`RealMemory` per partition is the most heterogeneity available here.
- **Real filesystem semantics.** A Docker volume is not Lustre or NFS. Close-to-open consistency
  delays and metadata-server pressure will not reproduce, so those code paths need care that the
  harness will not force.
- **Queue waits.** Eight slots means jobs mostly start immediately. Pending-state handling has to
  be provoked deliberately, for example by submitting more work than fits or using
  `--begin=now+60`.

## Dev-only shortcuts

- The munge key is baked into the image, so it is in an image layer and identical for anyone who
  builds it.
- The ssh keypair in `ssh/` is generated locally and gitignored.
- `StrictHostKeyChecking no`, because host keys regenerate on rebuild.
- Database passwords are in `docker-compose.yml` in plaintext.

None of this is suitable outside a laptop.
