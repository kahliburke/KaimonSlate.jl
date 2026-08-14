# Kaimon + KaimonSlate + Ollama + managed Qdrant, in one container.
#
# Services all bind loopback inside the container (Kaimon's MCP server does so by design —
# see MCPServer.jl "Binds to 127.0.0.1"), so `socat` republishes each on 0.0.0.0. That both
# makes port publishing work AND keeps Kaimon's `lax` security mode usable: the forwarder
# connects from 127.0.0.1, which is the only source IP `lax` accepts.
#
# Build (arm64, native on Apple Silicon):
#   docker build -t slate:dev docker/
#
# Run (headless MCP server):
#   docker run -d --name slate \
#     -p 8765:18765 -p 2828:12828 \
#     -v "$PWD/depot:/work/depot" -v "$PWD/notebooks:/work/notebooks" \
#     slate:dev
#
# Alongside a local Kaimon — just remap the host side:   -p 2929:12828
# Share Ollama with a local Kaimon:                      -p 11434:11434
# Expose Qdrant too:                    -e EXPOSE_QDRANT=1 -p 6333:16333
#
# TUI instead of headless (they cannot both run — the TUI hosts its own server,
# it does not attach to a running one):
#   docker run -it --rm -p 8765:18765 slate:dev --tui

# Trixie (Debian 13, glibc 2.41), NOT bookworm (2.36): Kaimon's managed Qdrant ships a
# Qdrant_jll binary linked against glibc 2.38, which fails to load on bookworm with
# "version `GLIBC_2.38' not found" — Kaimon then falls back silently and semantic search
# is dead. Same reason this won't run on Ubuntu 22.04 (2.35) or 20.04 (2.31).
FROM julia:1.12-trixie

# socat republishes loopback services; git is needed by Pkg; curl installs Ollama;
# zstd unpacks Ollama's release archive; tmux hosts the TUI on a persistent pty.
# One apt layer, right at the top — it's the most stable thing in the file.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git socat procps zstd tmux \
    && rm -rf /var/lib/apt/lists/*
ENV TERM=screen-256color

# Ollama ships CUDA/ROCm runtimes (~2.1 GB of a 2.23 GB install) that a CPU-only container
# can never use — and on arm64 they're unusable outright. Deleting them must happen in THIS
# layer: a later `rm` leaves the bytes in the earlier layer and reclaims nothing.
# Set STRIP_GPU_LIBS=0 if you intend to run this with `--gpus all` on an NVIDIA host.
ARG STRIP_GPU_LIBS=1
RUN curl -fsSL https://ollama.com/install.sh | sh \
    && if [ "$STRIP_GPU_LIBS" = "1" ]; then \
         rm -rf /usr/local/lib/ollama/cuda_* /usr/local/lib/ollama/rocm* ; \
       fi \
    && du -sh /usr/local/lib/ollama

# The image's depot. At runtime a writable host mount is prepended, so user-added
# extensions land there while everything baked here stays readable.
ENV JULIA_DEPOT_PATH=/opt/julia-depot
RUN mkdir -p /opt/julia-depot /work/depot /work/notebooks

# Precompiled pkgimages carry NATIVE code. Built for the builder's exact CPU, they are rejected
# on an older one and silently recompiled at run time — which would waste every precompile
# baked in below. These are the multi-versioned targets Julia's own binaries ship with, so the
# caches stay valid across the machines people will actually run this on. Dockerfile ENV can't
# branch, so the value goes in a file that each precompiling layer sources.
# TARGETARCH is supplied automatically by BuildKit.
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        echo 'generic;cortex-a57;thunderx2t99;carmel' > /etc/julia_cpu_target; \
    else \
        echo 'generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)' > /etc/julia_cpu_target; \
    fi && cat /etc/julia_cpu_target

# ── Julia packages ────────────────────────────────────────────────────────────
# Kaimon comes from General. KaimonSlate is vendored from its public repo rather than
# resolved through SlateRegistry, so the build needs no credentials; rebuild the image
# to pick up a newer Slate.
# SlateRegistry is public, so no credentials are needed here. It's baked into the depot so
# Kaimon's extension manager — which builds an ISOLATED env and re-resolves — can find
# SlateExtensionsBase, and so a user can `add` extensions into the mounted depot later.
# A registry added from a git URL is CLONED as a directory and comes out 0700 regardless of
# umask, unlike General which arrives as a world-readable tarball. Left alone, the non-root
# runtime user can't read it: registry seeding into the mounted depot fails and the extension
# manager's isolated env can't resolve SlateExtensionsBase, so the hub never starts. Scope the
# chmod to `registries` only — a `chmod -R` over the whole depot would rewrite ~2.6 GB into
# this layer (see the NOTE further down).
RUN julia -e 'using Pkg; \
      Pkg.Registry.add("General"); \
      Pkg.Registry.add(Pkg.RegistrySpec(url = "https://github.com/kahliburke/SlateRegistry.git")); \
      Pkg.add("Kaimon"); Pkg.Apps.add("Kaimon")' \
    && chmod -R a+rX /opt/julia-depot/registries

# ── Everything below is ordered stable → volatile ─────────────────────────────
# LAYER ORDER IS LORE. The `ADD` that busts on a new KaimonSlate commit sits as LATE as
# possible, because everything above it survives a source change. Putting the model pull or
# the Makie pre-warm *after* that bust means every KaimonSlate push re-downloads 639 MB and
# redoes the whole pre-warm — i.e. nearly a full build to pick up a one-line change.

# Pre-install the managed-Qdrant JLL so first run doesn't download it. Depends only on
# Kaimon, so it belongs above the KaimonSlate bust.
RUN julia -e 'using Kaimon, Pkg; \
      env = Kaimon.qdrant_service_env(); \
      Pkg.activate(env); Pkg.add(name="Qdrant_jll"); Pkg.instantiate()' || \
    echo "NOTE: Qdrant_jll pre-install failed; Kaimon will install on first use"

# ── Ollama embedding model, baked in ──────────────────────────────────────────
# qwen3-embedding:0.6b is Kaimon's default (qdrant_tools.jl DEFAULT_EMBEDDING_MODEL)
# and produces 1024-dim vectors. A collection built with a different model is NOT
# interchangeable, so keep this aligned with search.json's embedding_model.
# Depends on nothing but EMBEDDING_MODEL — keep it above the bust.
ARG EMBEDDING_MODEL=qwen3-embedding:0.6b
RUN ollama serve & \
    for i in $(seq 1 60); do curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break; sleep 1; done; \
    ollama pull "${EMBEDDING_MODEL}" && pkill ollama || true

# ── Pre-warm the heavy plotting stack ─────────────────────────────────────────
# Packages AND their precompile caches are depot-wide, not per-environment, so warming these
# here means a notebook worker in its own environment reuses the caches — as long as it
# resolves the same dependency versions, which it will while the image's baked registry
# snapshot is current. Without this, the first notebook touching Makie costs minutes and
# several GB of RAM at run time.
#
# Fetch ONLY examples/Project.toml rather than warming the cloned tree: this layer then
# invalidates when the dependency LIST changes, not when any Julia source file does. Warming
# from the clone instead would redo this whole step on every KaimonSlate commit.
#
# Precompiling in parallel is what makes the build memory-hungry: each worker holds its own
# copy, and CairoMakie + WGLMakie together exhaust an 8 GB Docker VM ("cannot allocate memory"
# / ResourceExhausted), so the worker count is scaled to the builder's RAM below.
#
# Parallelism is derived from the builder's RAM rather than taken as a build ARG. An ARG gets
# interpolated into the RUN text and so becomes part of the CACHE KEY — building once with
# PRECOMPILE_TASKS=4 and again with 2 silently invalidates this ~23 min layer, which is a
# brutal price for a knob that doesn't change the output at all. Reading /proc/meminfo keeps
# the instruction text identical everywhere while still adapting to the machine.
ARG KAIMONSLATE_REF=main
ADD https://raw.githubusercontent.com/kahliburke/KaimonSlate.jl/${KAIMONSLATE_REF}/examples/Project.toml \
    /opt/prewarm/Project.toml
RUN export JULIA_CPU_TARGET="$(cat /etc/julia_cpu_target)" && \
    export JULIA_NUM_PRECOMPILE_TASKS="$(awk '/MemTotal/{printf "%d", ($2 > 14000000) ? 4 : 2}' /proc/meminfo)" && \
    echo "precompile tasks: $JULIA_NUM_PRECOMPILE_TASKS" && \
    julia --project=/opt/prewarm -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# ── KaimonSlate source — the volatile part ────────────────────────────────────
# Bust the clone layer when the branch moves. Without this Docker caches `git clone` on the
# instruction text alone, so the image silently keeps whatever commit it first built with and
# a "rebuild to pick up changes" does nothing.
ADD https://api.github.com/repos/kahliburke/KaimonSlate.jl/commits/${KAIMONSLATE_REF} \
    /tmp/kaimonslate-head.json
RUN git clone --depth 1 --branch "${KAIMONSLATE_REF}" \
        https://github.com/kahliburke/KaimonSlate.jl.git /opt/src/KaimonSlate.jl \
    && grep -m1 '^version' /opt/src/KaimonSlate.jl/Project.toml

# develop both the bundled SDK and the package itself: `[sources]` is gone from
# KaimonSlate now, so SlateExtensionsBase must be supplied explicitly. Also resolve the real
# examples env — cheap, since the pre-warm above already downloaded and compiled its packages.
RUN export JULIA_CPU_TARGET="$(cat /etc/julia_cpu_target)" && julia -e 'using Pkg; \
      Pkg.develop(path="/opt/src/KaimonSlate.jl/lib/SlateExtensionsBase"); \
      Pkg.develop(path="/opt/src/KaimonSlate.jl"); \
      Pkg.instantiate(); \
      Pkg.precompile()' \
    && julia --project=/opt/src/KaimonSlate.jl/examples -e 'using Pkg; Pkg.instantiate()'

# ── Kaimon configuration ──────────────────────────────────────────────────────
# Placed after the model pull so editing config doesn't invalidate that ~1GB layer.
#
# `created_at` MUST be present and integral: security.jl defaults it to `time()`, a Float64,
# which then fails KaimonConfig's Int field — so a config without it silently fails to load
# and Kaimon falls back to the interactive setup wizard, which cannot run in a container.
#
# `lax` = no API key, and only 127.0.0.1 accepted as a source — which is precisely what the
# socat forwarders present, since they dial loopback.
RUN mkdir -p /root/.config/kaimon && \
    printf '{"extensions":[{"auto_start":true,"enabled":true,"project_path":"/opt/src/KaimonSlate.jl"}]}\n' \
      > /root/.config/kaimon/extensions.json && \
    printf '{"allowed_ips":["127.0.0.1","::1"],"api_keys":[],"mode":"lax","port":2828,"editor":"vscode","created_at":%s,"gate_setup_version":1,"global_install_dismissed":true}\n' \
      "$(date +%s)" > /root/.config/kaimon/config.json

# ── Run as uid 1000, not root ─────────────────────────────────────────────────
# Everything the container writes to a bind mount takes the container user's ownership, so
# running as root leaves root-owned notebooks and depot files the host user can't edit.
# uid 1000 is the first non-system user on most Linux hosts (`ubuntu`, and Hugging Face
# Spaces mandates exactly this uid), so files land owned by you.
#
# The Kaimon *cache* has to move too, not just the config: the Qdrant_jll pre-installed above
# lives under `kaimon_cache_dir()/service-env`, which is HOME-relative — leave it in /root and
# the running user silently re-downloads it.
# Ownership is uid:GROUP 0, and everything the app writes is group-writable. Docker always
# adds gid 0 to the process, so the image runs correctly under ANY uid — the host passes
# `--user $(id -u)` when its user isn't 1000 (slate-remote-4's `ubuntu` is 1001, Hugging Face
# Spaces mandates 1000) and files on the bind mount come out owned by that user. One image,
# no per-host rebuild. Same trick OpenShift requires.
ARG APP_UID=1000
RUN useradd -m -u ${APP_UID} -g 0 -s /bin/bash app \
    && cp -a /root/.config /home/app/.config \
    && if [ -d /root/.cache ]; then cp -a /root/.cache /home/app/.cache; fi \
    && chown -R ${APP_UID}:0 /home/app /work /opt/src \
    && chmod -R g+rwX /home/app /work /opt/src
# NOTE: do NOT `chmod -R` /opt/julia-depot. Touching every file rewrites the whole 2.6 GB
# depot into this layer (+2.6 GB to the image). It's also pointless: root builds it under
# umask 022, so it's already world-readable. The ONE exception is `registries` — a
# git-cloned registry lands 0700 — and that's chmod'd at the point it's added, above.

# ── Runtime configuration ─────────────────────────────────────────────────────
# Writable depot first: Pkg installs there, and reads fall through to the baked one.
ENV JULIA_DEPOT_PATH=/work/depot:/opt/julia-depot \
    PATH=/work/depot/bin:/opt/julia-depot/bin:$PATH \
    KAIMON_QDRANT_MANAGED=always \
    OLLAMA_HOST=0.0.0.0:11434 \
    EMBEDDING_MODEL=${EMBEDDING_MODEL}

# Internal (loopback) ports keep each tool's own default; socat republishes them
# on the +10000 range, which is what you publish to the host.
EXPOSE 12828 18765 16333 11434

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Strip CRLF: a checkout on Windows (git autocrlf) otherwise yields
# "bad interpreter: /usr/bin/env bash^M". chmod because Windows carries no exec bit.
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

# USER comes last: everything above writes root-owned files under /usr/local, which a
# non-root user cannot chmod.
USER ${APP_UID}
# Docker does NOT update HOME when USER changes — without this it stays /root, which the
# new user cannot read, and Kaimon would look for its config and caches in the wrong place.
ENV HOME=/home/app

WORKDIR /work/notebooks
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
