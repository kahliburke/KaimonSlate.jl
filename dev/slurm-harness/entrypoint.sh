#!/usr/bin/env bash
# Role dispatch for the one-image cluster. Usage: entrypoint.sh <slurmctld|slurmd|slurmdbd|login>
set -euo pipefail

ROLE="${1:?usage: entrypoint.sh <slurmctld|slurmd|slurmdbd|login>}"

start_munge() {
    mkdir -p /run/munge
    chown munge:munge /run/munge
    # Ownership on the baked key can be lost through a volume mount; reassert it or munged exits.
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key
    sudo -u munge /usr/sbin/munged --force
    for _ in $(seq 1 20); do
        [ -S /run/munge/munge.socket.2 ] && break
        sleep 0.25
    done
}

# The shared volumes mount empty and root-owned. Fix them up here rather than in the image, since
# the image's directories are shadowed by the mounts.
prepare_shared() {
    mkdir -p /scratch /home/slate
    # /scratch is a bind mount from the host, where ownership is decided by the Docker VM's file
    # sharing and chown does not necessarily apply. Best effort, and never fatal.
    chown slate:slate /home/slate 2>/dev/null || true
    chown slate:slate /scratch 2>/dev/null || true
    chmod 1777 /scratch 2>/dev/null || true
}

wait_for_tcp() {
    local host="$1" port="$2"
    for _ in $(seq 1 120); do
        (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "timed out waiting for ${host}:${port}" >&2
    return 1
}

start_munge
prepare_shared

case "$ROLE" in
  slurmdbd)
    wait_for_tcp mysql 3306
    # Register the cluster once slurmdbd is answering, so sacct has somewhere to write. Harmless
    # to repeat on restart.
    ( wait_for_tcp localhost 6819 \
      && sacctmgr -i add cluster slate >/dev/null 2>&1 || true ) &
    exec slurmdbd -D
    ;;

  slurmctld)
    wait_for_tcp slurmdbd 6819 || true   # accounting is optional; the controller still starts
    exec slurmctld -D
    ;;

  slurmd)
    wait_for_tcp slurmctld 6817
    exec slurmd -D -N "$(hostname -s)"
    ;;

  login)
    wait_for_tcp slurmctld 6817
    ssh-keygen -A
    install -d -m 700 -o slate -g slate /home/slate/.ssh
    if [ -f /ssh/authorized_keys ]; then
        install -m 600 -o slate -g slate /ssh/authorized_keys /home/slate/.ssh/authorized_keys
    fi
    exec /usr/sbin/sshd -D -e
    ;;

  *)
    echo "unknown role: $ROLE" >&2
    exit 2
    ;;
esac
