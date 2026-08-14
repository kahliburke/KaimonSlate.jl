# Slate as a Hugging Face Space.
#
# ⚠️  A SLATE NOTEBOOK EXECUTES ARBITRARY JULIA CODE.
# A *public* Space running this hands anyone on the internet code execution inside the
# container, with its network access and any token you set. Deploy as a **private** Space, or
# as a throwaway demo you accept is untrusted. Never put credentials in a public Space — the
# Kaimon MCP port is left unexposed below for the same reason.
#
# Deploy: copy this file to the root of a Space repo (SDK = docker) and push. It layers on the
# prebuilt image rather than rebuilding Julia, which would blow past the free build limits.

FROM ghcr.io/kahliburke/slate:latest

# The base image already runs as uid 1000 with HOME=/home/app, which is exactly what Spaces
# require — so there's no user juggling to do here.

# Spaces only route port 7860, so publish the Slate hub there. Kaimon's MCP and Qdrant stay
# unexposed: an open MCP endpoint on a public host is a remote code execution service.
ENV SLATE_PUBLISH_PORT=7860 \
    EXPOSE_KAIMON=0 \
    EXPOSE_QDRANT=0

EXPOSE 7860

# Free-tier storage is ephemeral: anything written to /work (added packages, precompile
# caches, notebooks) is lost on restart, so each cold start repeats that work. The baked depot
# at /opt/julia-depot survives, being part of the image.
