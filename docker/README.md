# Slate in a container

One image containing Kaimon (MCP server), KaimonSlate, Ollama with an embedding model, and
Kaimon-managed Qdrant. Intended for testing Slate without installing a Julia toolchain.

Windows, macOS and Linux all run the same **Linux** image — on Windows through Docker
Desktop's WSL2 backend. There is no Windows-native image; pick the build matching your CPU
(`linux/amd64` for Intel/AMD including Windows, `linux/arm64` for Apple Silicon).

## Build

```sh
docker build -t slate:dev docker/
```

Builds for the host architecture. For both at once (slow — the foreign half is emulated):

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t slate:dev docker/
```

Building each architecture natively on its own machine is much faster than emulation.

## Run

**macOS / Linux**

```sh
docker run -d --name slate \
  -p 8765:18765 -p 2828:12828 \
  -v "$PWD/depot:/work/depot" \
  -v "$PWD/notebooks:/work/notebooks" \
  slate:dev
```

**Windows (PowerShell)**

```powershell
docker run -d --name slate `
  -p 8765:18765 -p 2828:12828 `
  -v "${PWD}\depot:/work/depot" `
  -v "${PWD}\notebooks:/work/notebooks" `
  slate:dev
```

Then open <http://localhost:8765>.

On Windows, bind mounts that cross into the Windows filesystem (`C:\...`) are **markedly
slower** than paths inside WSL2 — a Julia depot is exactly the kind of many-small-files
workload that suffers. Prefer either a named volume:

```powershell
docker volume create slate-depot
docker run -d --name slate -p 8765:18765 -v slate-depot:/work/depot slate:dev
```

or a directory inside the WSL2 filesystem (`\\wsl$\Ubuntu\home\<user>\slate`).

## Ports

Services bind loopback inside the container and are republished on `0.0.0.0` by `socat`, so
publish the **1xxxx** port, not the service's own.

| Service | Internal | Publish | Default |
|---|---|---|---|
| Slate hub | 8765 | `-p 8765:18765` | on |
| Kaimon MCP | 2828 | `-p 2828:12828` | on |
| Qdrant HTTP | 6333 | `-e EXPOSE_QDRANT=1 -p 6333:16333` | off |
| Ollama | 11434 | `-p 11434:11434` | binds `0.0.0.0` directly |

Running alongside a local Kaimon: remap the host side, e.g. `-p 2929:12828`, and point your
agent's MCP config at `http://localhost:2929`.

Sharing the container's Ollama with a local Kaimon: publish `11434` and set the local
Ollama host accordingly.

## TUI vs headless

The container runs `kaimon --headless` by default. Kaimon's TUI **hosts its own MCP
server** — it does not attach to a running one — so the two cannot run together. To get the
dashboard, run it *instead* of headless:

```sh
docker run -it --rm -p 8765:18765 slate:dev --tui
```

## Adding extension packages

The image's depot is read-only at `/opt/julia-depot`; the mount at `/work/depot` comes first
in `JULIA_DEPOT_PATH`, so anything you install lands there and survives container restarts.

```sh
docker exec -it slate julia -e 'using Pkg; Pkg.add("StarRating")'
```

`StarRating` is the sample extension — a star-rating `@bind` control — and is public, so that
works with no credentials. Extensions whose repositories are **private** additionally need
GitHub credentials in the container; simplest is a token at run time:

```sh
docker run -d --name slate -e GITHUB_TOKEN=ghp_... ... slate:dev
```

Alternatively bake an extension into a derived image, which needs no runtime credentials:

```dockerfile
FROM slate:dev
RUN julia -e 'using Pkg; Pkg.add("StarRating")'
```

## Notes

- First build is long (Julia precompilation plus a ~1 GB embedding model) and the image is
  several GB.
- The embedding model is `qwen3-embedding:0.6b` (1024-dim). A Qdrant collection built with a
  different model is not interchangeable, so this container's index is separate from any
  index built on your host with another model.
- Security is Kaimon's `lax` mode: no API key. It works only because the `socat` forwarders
  make every connection appear to originate from `127.0.0.1`. Do not expose these ports to an
  untrusted network.
