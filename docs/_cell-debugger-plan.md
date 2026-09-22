# Cell debugger — state and plan

Line-by-line stepping of a notebook cell, working identically on an in-process kernel, a spawned
worker, and a remote region — and a debugging SPECIALIST you can summon into a session to work on
the code with you.

Branches: `feat/cell-debugger` (KaimonSlate), `feat/acp-backend` (Kaimon,
`~/.julia/dev/Kaimon/.claude/worktrees/acp-backend`). The Kaimon side is no longer only the host:
it now carries an ACP allowlist change this feature needs (§5).

---

## 1. What is built

| layer | file | state |
|---|---|---|
| Stepper | `src/worker_debug.jl` | 58 tests green |
| Kernel API | `src/eval.jl`, `src/gate_kernel.jl` | in-process, `GateKernel`, `PendingKernel` |
| Service + routes + push | `src/server_debug.jl` | live-verified |
| Agent tools | `src/KaimonSlate.jl` (`dbg_*`) | live-verified, local and remote |
| UI | `src/assets/js/debugger.js`, `editor.js`, `view.js`, `notebook.js` | live-verified |

**Stepper.** `debug_start!` / `debug_step!` (`next|into|out|continue`) / `debug_frame` /
`debug_eval_expr` / `debug_marks!` / `debug_stop!`. Included by both `engine.jl` and `worker.jl`,
so the same stepper runs wherever the cell does; `worker.jl` wraps them as `__slate_debug_*` gate
tools, which is the whole of the remote story.

**Breakpoints.** File-and-line, matched by JuliaInterpreter's `endswith` rule — so `cell:<id>`
works as a filename and one mechanism covers a cell's own lines, a method defined in another cell,
and a package file. Settable before a session exists, they survive one, re-arm live, and are
removed on stop (the breakpoint list is process-global, like `compiled_modules`).

**Live push.** Every verb broadcasts `debug:<json>` on the notebook SSE — from the VERBS, not the
routes, because an agent reaches them over MCP and never touches a route. The browser applies what
it is told rather than what it asked for, which is what makes an agent-driven session watchable.

**Ownership.** `DebugSession{cell, side, owner}`; owner is `human` or `agent:<id>`. Starting is
never gated. ENDING someone else's is: an agent calling `stop_debug!` on a human's session blocks
on `request_consent`, and silence is a no. Stepping is deliberately ungated so a person can always
take the controls back mid-thought.

**Asking.** `ask_and_wait` posts a request, broadcasts it, and blocks the caller's tool call on a
channel until answered (15 min). One primitive serves both the specialist's questions and its
consent requests. Answered from the browser (`/debug/answer`) or by the orchestrator
(`dbg_answer`).

**The specialist.** `summon_debugger!` spawns a crew member (`crew = "debugger"`) with the brief in
`_DEBUG_BRIEF`, `permission = "default"`, and an allowlist of exactly the seven `dbg_*` verbs. Its
reasoning and tool calls stream into the notebook's chat. Summoned from the strip's `＋ specialist`
button (with an ACP backend picker) or by the orchestrator via `dbg_summon` with a written brief.

---

## 2. Decisions — do not re-litigate

**NamedTuples, not structs, for wire payloads.** A struct would be `ReportEngine.DebugState` in the
server and `SlateWorker.DebugState` in a worker — two types, one name, no deserialization.

**Nothing pauses.** JuliaInterpreter reifies the frame as a value, so between steps the cell is not
running. No lock is held across a worker round trip, so the `nb.lock` deadlock class does not
apply. This is why JuliaInterpreter and not Infiltrator, which cannot step.

**Values are summarized, never shipped.** `DebugLocal` is `{name, type, size, repr, fresh}`.

**The interpret-set is inferred.** The notebook's namespace, its submodules, and Revise-tracked
packages outside the read-only depot. A property of the machine, so it is displayed rather than
assumed.

**Consent is about ENDING, not joining.** An earlier pass gated starting too; that was wrong.

**`scope`, not `where`** — `where` is a keyword and cannot name a field.

---

## 3. The reframing: "locals" are *remotes*

The pane's job is values that live on another machine and cannot simply be printed. Summaries plus
fetch is therefore the mechanism, not an optimisation. It matters locally too — a 10⁶-element array
is "remote" in the sense that counts.

The half that exists is the summary. **§4.1 is the fetch.**

---

## 4. What is left

### 4.1 Value inspection — the unbuilt half of §3
Click a summary; the far side renders it (plot, table, head); ship the rendered artifact. Reuse the
cell-output renderer and the existing elision / chunked-transfer machinery. Until this lands, the
"locals are remotes" idea is stated but not delivered.

### 4.2 Server-layer tests
Ownership, consent, ask/answer and summon are verified only by live runs. The stepper has 58 tests;
this layer has none.

### 4.3 The surface question
The conversation is in the chat pane and the frame is in the strip — two places to look. Whether
that wants to become one unified workspace is an open question, deliberately left until there was a
real session to judge from. There now is.

### 4.4 Orchestrator notification
`dbg_ask` blocks the specialist and surfaces the question in the notebook and in `dbg_frame` output,
so an orchestrator that looks will see it. Nothing PUSHES it to a Claude Code session — the
orchestrator has to poll. A bridge from Kaimon's agent bus is the real fix.

### 4.5 Budgets
Nothing enforces a step/turn/wall-clock limit yet. `dbg_done` is required by the brief, not by code.

---

## 5. Traps already paid for

**`:so` is not a JuliaInterpreter command.** Step-out is `:finish`; `so` is Debugger.jl's REPL key.
An unknown command throws, and `_advance!` treats a throw as the run ending — so the session died
instead of stepping out.

**Julia 1.12+ binding world age.** The interpreter creates a global in a newer world than the
reader was compiled in, so `isdefined`/`getfield`/`names` report "not assigned" for one more step.
`invokelatest` must wrap the WHOLE access, not just the call.

**Reach CodeTracking through JuliaInterpreter, not Revise.** It is a dependency of the interpreter,
which is already required; via Revise, frame source silently vanishes wherever Revise isn't loaded.

**`Meta.parseall` does not throw on unfinished code.** It returns an `:incomplete` node and carries
on, so a cell with no `end` builds a frame that dies on the first step.

**Stepping INTO a call is a synthetic breakpoint.** Reading `debug_command`'s return reported a
breakpoint on every `into`. Ask the frame whether its pc carries an armed, active breakpoint.

**`CellOutput.exception` and `value_repr` are nullable.** `isempty(nothing)` is an `iterate` error.

**An ACP agent ignored `allowed_tools`** until `feat/acp-backend` was changed: `ACPClientBackend`
never took the field, and `agent_session.jl` dropped it on the ACP path. An allowlist that silently
does nothing is worse than one not offered — the first specialist called a tool that was never in
its world. Fixed in `acp_backend.jl` (`_acp_decide` checks it BEFORE the preset early-return, or a
permissive preset waves through the very tools the list excluded).

**Tool names are namespace-dependent.** An agent sees `<namespace>_<verb>`, and the namespace is
`slate_dbg` in this checkout and `slate` installed. Derive it (`debug_tool_names()`), never write
it down.

**`lab` widens an allowlist.** Its preset allowance is `mcp__kaimon`, which covers every Kaimon
tool. A specialist needs `permission = "default"`.

**A cell's module bindings survive the last run.** At the start of a session every one already
holds a value and a reader cannot tell it from this run's. Tracked per top-level statement
(`assigned`), not by diffing values — re-running and getting the same answer must not read as
stale. The first specialist to use the pane flagged this unprompted.

**The answerer must drop the ask, not the waiter.** The waiting task tidies up on its own schedule,
so the reply to whoever answered could still list the request they just dismissed — and it lands
after the broadcast that cleared it, so the prompt reappears and sticks.

**Front-end:** a `js"""…"""` pane preserves backslashes. `slateCall` hands the Julia handler a
NamedTuple, not a Dict. `toggleAgent` is a toggle — check `.open` before calling it.

**Never use `hash` for identity that crosses a machine** — it is not stable across Julia versions,
and this is a mixed-version local/remote pair by design. Use `slate_fingerprint`.

**`in_cell` means the cell being stepped**, not "some cell".

---

## 6. Running it

```
SLATE_KAIMON_PATH=~/.julia/dev/Kaimon/.claude/worktrees/acp-backend \
  julia --project=. -m KaimonSlate --port 8902 --ai 2929
```

MCP tools arrive as `slate_dbg_*` on the `kaimon-alt` server (`http://localhost:2929/mcp`);
`kaimon.toml` sets the namespace and is **uncommitted on purpose**. A Slate source change needs
`manage_extension(name="slate_dbg", action="restart")` (~2 min); a KAIMON change needs the whole
hub restarted, since Kaimon is the host.

Demo notebook: `examples/cell_debugger/cell_debugger_demo.jl` — **untracked on purpose, not to be
committed**. `kit`/`net`/`drive` carry a deliberate off-by-one (the smoother stores `acc` before
updating it, so the last reading never reaches the output); `kit_r`/`net_r`/`drive_r` are the same
thing tagged `region=region_test` (host `slate-remote` = `cascadia`).
