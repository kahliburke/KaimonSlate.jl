# One image, several roles (slurmctld / slurmd / slurmdbd / login). The role is chosen by the
# entrypoint argument in docker-compose.yml. Building every role from ONE image is what makes the
# munge key identical everywhere without mounting secrets around.
# SLURM version is chosen by base image, which avoids source builds entirely:
#   ubuntu:22.04   -> slurm-wlm 21.08.5  (floor; older than most live production sites)
#   ubuntu:24.04   -> slurm-wlm 23.11.4  (will NOT start here: no CgroupPlugin=disabled, and
#                                         slurmd insists on a systemd/dbus scope for slurmstepd)
#   debian:trixie  -> slurm-wlm 24.11.5  (default)
# Override with:  docker build --build-arg BASE_IMAGE=ubuntu:22.04 -t slate-slurm:2108 .
ARG BASE_IMAGE=debian:trixie
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ARG JULIA_VERSION=1.12.7

RUN apt-get update && apt-get install -y --no-install-recommends \
        slurm-wlm slurmdbd munge \
        openssh-server sudo rsync curl ca-certificates \
        iproute2 iputils-ping less procps vim-tiny jq \
    && rm -rf /var/lib/apt/lists/*

# Julia, matching the build platform. Not juliaup: a pinned tarball is reproducible and skips a
# network dance on every container start.
RUN set -eux; \
    case "$TARGETARCH" in \
      arm64) JARCH=aarch64; JDIR=aarch64 ;; \
      amd64) JARCH=x86_64;  JDIR=x64 ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://julialang-s3.julialang.org/bin/linux/${JDIR}/${JULIA_VERSION%.*}/julia-${JULIA_VERSION}-linux-${JARCH}.tar.gz" \
         -o /tmp/julia.tgz; \
    mkdir -p /opt/julia; \
    tar -xzf /tmp/julia.tgz -C /opt/julia --strip-components=1; \
    ln -sf /opt/julia/bin/julia /usr/local/bin/julia; \
    rm /tmp/julia.tgz; \
    julia --version

# A fixed munge key baked into the image. Every container runs this same image, so every container
# has the same key and munge authentication just works. DEV ONLY: this key is in the image layer.
RUN dd if=/dev/urandom of=/etc/munge/munge.key bs=1024 count=1 status=none \
    && chown munge:munge /etc/munge/munge.key \
    && chmod 400 /etc/munge/munge.key

# The unprivileged user that owns jobs, matching a real cluster login. UID is pinned so the shared
# /scratch and /home volumes have consistent ownership across containers.
RUN useradd -m -u 1100 -s /bin/bash slate \
    && echo 'slate ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/slate

RUN mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /run/munge \
             /etc/slurm /var/run/sshd \
    && chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm \
    && chown -R munge:munge /run/munge

COPY etc/slurm.conf etc/cgroup.conf /etc/slurm/
COPY etc/slurmdbd.conf /etc/slurm/slurmdbd.conf
RUN chown slurm:slurm /etc/slurm/slurmdbd.conf && chmod 600 /etc/slurm/slurmdbd.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
