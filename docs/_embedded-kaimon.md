# Embedded Kaimon for standalone Slate — design note

Status: **design only, nothing built.** Working note, untracked (`docs/_*.md` convention).

Kaimon file/line references are against `~/.julia/dev/Kaimon` as of 2026-09-09. They are the
perishable part of this note — re-check before relying on them.

## The problem

Standalone `slate` (a user who installed KaimonSlate and *not* Kaimon) has the remote-execution
feature present in the code and non-functional. In `_select_kernel` (`src/server.jl:286`) the
entire remote branch sits inside `if ReportEngine.gate_available()`, which is false without
`Main.Kaimon`. So:

- a `runon` baked into the `.jl` footer is ignored and the notebook runs locally
- `RUNON_DEFAULT` from `slate.json` is ignored
- `remote`-tagged cells and `regionon` do nothing
- the `_rlog` line that would record the decision is itself inside the gate branch, so there is
  not even a log entry

Meanwhile the runloc pill, Settings → "where new notebooks run", and the new-notebook picker all
still offer the choice. You pick a host, it accepts, and it runs on your laptop.

The same check gates LOCAL workers, which is why standalone uses an in-process kernel at all.

## The approach

`slate --ai [port]` brings up a **headless Kaimon in an isolated location**, which starts Slate as
its extension exactly as a normal Kaimon install does. Slate's CLI then attaches as a viewer.

Nothing new is invented. Three existing things are reused:

- `kaimon --headless` is a first-class mode (`Kaimon/src/kaimon_lifecycle.jl`, "headless
  housekeeping"; `(@main)(ARGS)` at :670; `KAIMON_HEADLESS_SYNC_INTERVAL` documented at :17-23;
  `kaimon_tools.jl:259` refers to `kaimon --headless >>log &` as ordinary usage)
- Kaimon's extension spawn, which produces a Slate hub with `Main.Kaimon` present — the topology
  that gets the most real-world testing
- `app.jl`'s viewer/waiting mode (`_startup_mode` :149, `_ext_autostarts`, `_slate_registered`,
  `register_extension()`). The CLI already knows how to attach to an extension hub; today it just
  gives up when Kaimon is absent.

Because Kaimon is genuinely present in that process, there is no capability matrix to maintain: the
agent pane, doc search and image view all answer truthfully instead of needing per-feature gates.

### Alternatives considered and rejected

**Slate depends on Kaimon.** 35 top-level deps imposed on someone who wants notebooks.

**Slate depends on KaimonGate.** KaimonGate is small (6 deps, all stdlib bar ZMQ), but it is the
*server* half. The client Slate's hub needs lives in Kaimon: `ConnectionManager`
(`Kaimon/src/gate_client_manager.jl:7`), `connect_tcp!` (`gate_client_discovery.jl:398`). Moving
the `gate_client_*` files into KaimonGate is viable — ~3,500 lines across 8 files, external surface
only `Dates`, `JSON`, `Serialization`, `Sockets`, `ZMQ` — but it is upstream work, and the embedded
process makes it unnecessary. Keep it in mind only if the embedded approach fails.

**Sidecar that relays gate traffic.** `_connect!` (`gate_kernel.jl:911`) uses the client for ALL
gate traffic, not just provisioning — every eval, reactive event, stream message and blob. A relay
puts a process hop and a serialization boundary on the hot path, which is the path the event-driven
stream work took from p50 26ms to 1ms. Rejected.

## Isolation

Requirement: everything the embedded Kaimon writes lands in a known Slate-specific location.

**Achievable today, no Kaimon change.** Kaimon has no `KAIMON_HOME`; it resolves config and cache
from `XDG_CONFIG_HOME` / `XDG_CACHE_HOME` (appending `kaimon`), `LOCALAPPDATA`/`APPDATA` on
Windows. Single source of truth at `Kaimon/src/Kaimon.jl:49-93`. Setting those two vars on the
spawned process relocates its logs, `curve/server.key`, extension state and the rest.

**The trap.** Headless Kaimon spawns the Slate extension as a child, which inherits those vars —
and `SlateHome._resolve` (`src/slate_home.jl:35-43`) reads the same XDG vars. Isolating Kaimon
naively would also relocate embedded-Slate's config, publish ledger and cache, and the user would
lose their notebook list and settings.

It works only because `SlateHome`'s precedence is `KAIMONSLATE_<HOME>_HOME` > `KAIMONSLATE_HOME` >
XDG > default. So: set XDG to the private location for Kaimon, and pin
`KAIMONSLATE_CONFIG_HOME` / `_DATA_HOME` / `_CACHE_HOME` explicitly to the user's real homes.
Kaimon isolated, Slate unaffected. Write this down wherever the spawn happens; it is not obvious.

**Depot — open decision.**

| | private `JULIA_DEPOT_PATH` | shared depot, private env |
|---|---|---|
| removal | one `rm -rf` | packages remain in the shared depot |
| first `--ai` | re-downloads + re-precompiles 35 deps; GBs, long | reuses existing artifacts, far faster |
| resolution isolation | total | total (separate environment) |

Recommendation: **shared depot, private environment.** First-run cost is the thing most likely to
make `--ai` feel broken, and the config/cache/tmp isolation actually being asked for is orthogonal
to where package artifacts live.

**Ports.** The embedded gate and MCP must not fight a Kaimon the user later installs.
`--ai [port]` covers MCP; the gate port needs the same treatment.

## Security: lax, deliberately

`security_mode = :lax` is the point, not a shortcut. This whole path exists for someone on their
own machine who wants their notebook to use another box they already have, and an agent to be able
to drive it. Simple security needs, and lax is the configuration that matches them.

Kaimon has three modes (`:strict`, `:relaxed`, `:lax` —
`Kaimon/src/kaimon_lifecycle.jl:441-445`), settable at startup via `start!(; security_mode=…)`
(`kaimon_tools.jl:246`) or `set_security_mode`.

Lax skips the API-key path entirely: both the client
(`gate_client_discovery.jl:81`, `:435`) and `Kaimon.jl:227` guard token use on
`config.mode != :lax && !isempty(config.api_keys)`. So there is no key to generate, store in the
isolated config, or plumb through to the Slate extension and to CLI agents. One less provisioning
step, and it matches Slate's own posture (no authentication at any bind address).

**Where the assumption stops.** A shared machine. There, every local account can reach the MCP
endpoint, and it executes code as the owning user — the same exposure catalogued for Slate's own
hub in issue #27's follow-up (`start_hub`'s docstring says so outright; `_request_allowed` is
browser-origin defence, not auth). That is a different deployment with different needs, and the
answer is to expose the mode rather than to complicate this path. Keeping `security_mode` a
settable value rather than a hardcoded `:lax` is enough to leave that door open.

**Qdrant.** `KAIMON_QDRANT_PREFIX` (`Kaimon/src/Kaimon.jl:231`) namespaces collections away from a
real Kaimon's.

## Ollama is opportunistic

Ollama may or may not be running. Do not probe, wait for, or auto-start it.

- CLI agents do not touch it — that is Claude Code over MCP, no embeddings.
- `/api/help` does not touch it — exact-name lookup is Julia introspection in the worker. The docs
  panel's most useful half, including name completion, works with Ollama absent.
- `/api/docsearch` degrades, and is already written to return nothing without an index.
- `ollama:`-prefixed agent models need it (`Kaimon/src/agent_session.jl:160`); anything else is the
  claude CLI.

Run the embedded Kaimon with `KAIMON_HEADLESS_SYNC_INTERVAL=0`. Otherwise its periodic full index
sync retries against an Ollama that is not there — noise and wasted work for a service Slate did
not start it for. Same reasoning as the existing `KAIMONSLATE_NO_AUTOINDEX=1` in `_run_script`
(`src/server_export.jl:3457-3459`).

## Extension registration

Two routes, either acceptable:

- programmatic, in the headless process
- the normal `kaimon.toml` scan — Slate already ships one at its project root, so point the
  embedded Kaimon's extension search at Slate's own directory

## Provisioning is visible in the TUI

First `--ai` pays a real install and precompile — minutes. It must narrate rather than appear hung.
The machinery exists: the bring-up banner and `src/prepare.jl`'s stage classifier already render
"Precompiling k/N · <pkg>" for cold notebook opens, and `_prep_stage` is the hook.

## Open questions

1. Does headless Kaimon auto-start the Slate extension, or must Slate register first?
   `_ext_autostarts` suggests registration is the trigger.
2. Ownership on exit. If `slate --ai` spawned the Kaimon it attached to, quitting should stop it —
   otherwise a headless host lingers. Attaching to a Kaimon the user already runs must NOT kill it.
3. Should `runon` without `--ai` bootstrap the whole host? Silently doing so feels wrong. Erroring
   with "this needs `slate --ai`" is better, and is a better fix for the silent-`runon` bug than a
   bare warning.

## Build order

1. **Silent `runon`** — independent, a live bug today, ships from Slate whenever. Say that a remote
   was requested and could not be honoured, and name the flag that fixes it.
2. **`--ai [port]`** — env isolation, on-demand install, headless spawn, registration, TUI
   provisioning, ownership-on-exit.
3. **In-browser agent pane** — falls out of 2 for free, since Kaimon's `agent_*` tools are then
   genuinely registered. `_agent_call` (`src/server_agentsessions.jl:157`) dispatches those through
   `call_tool`, which resolves against the tools registered in that process.
