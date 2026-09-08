# The AI Agent

When KaimonSlate runs under [Kaimon](https://github.com/kahliburke/Kaimon.jl), the **💬
agent** pane drives the notebook through the *same* operations you use — adding, editing,
running, and deleting cells one at a time. It is a live collaborator, not a file-rewriter:
you watch each cell appear and run.

![The agent pane: a chat turn adds a slider and a chart cell, with tool calls shown as friendly chips](./assets/agent-panel.png)

## How it works

The agent is a consumer of Kaimon's agent service. A chat turn is forwarded to an agent
session bound to the notebook; the agent calls the `slate.*` tools; their effects flow
through the normal reactive path, and the agent's event stream is relayed onto the
notebook's SSE so the chat pane updates live (streaming text, tool calls, and figures).

### The tool surface

A selection of the surface. The full set runs to more than forty tools, with the worker, region,
publishing and export ones documented on their own pages.

| Tool | Purpose |
| --- | --- |
| `slate_api` | the index of Slate's cell helpers: one name, several batched, a category, or `all` |
| `slate_read` | the whole notebook — every cell's source + output/error |
| `slate_add_cell` | append a cell, **run it**, return its result |
| `slate_edit_cell` | revise a cell, run it, return its result |
| `slate_run` | run a cell (or all stale) |
| `slate_rename_cell` | give a cell a meaningful id |
| `slate_delete_cell` | remove a cell |
| `slate_pkg` | add or remove a package in the notebook's own environment |
| `slate_view` | **see** a cell's rendered figure (returns the image) |
| `slate_search_docs` / `slate_index_docs` | semantic search of the notebook's package docs |

`slate_api` is the reference the agent reads before writing a cell, so what it writes uses the
helpers that actually exist with their real arguments. `slate_search_docs` searches the same content
under the module name "Slate". The agent also has `slate_inspect`, `slate_eval`, `slate_eval_js` and
`slate_diag`.

`slate_eval` runs code in the notebook's worker **without adding a cell**, and its result lands in
the [scratchpad](notebook-basics.md#The-scratchpad) behind the 🧪 pill, which badges in-flight and
unread runs. Scratch output is read-only text, values and static images, and the panel's 🧹 button
empties it.

Tool calls are shown in the chat with friendly labels (e.g. `➕ add cell`, `🖼 view
figure`) rather than raw `mcp__kaimon__…` names.

!!! tip "The agent can see your plots"
    `slate_view` returns the cell's figure as an image — CairoMakie rasters and ECharts canvas
    snapshots both flow through one interface — so the agent can inspect a chart it made and fix
    it.

## Scoping a turn to a cell — ✨

Click **✨** on a cell header to scope the next turn to that cell. The server sends the
agent that cell's source and output, its **upstream dependency cone**, and its downstream
impact — and instructs it to work *only* there (not survey the whole notebook). A
"focused on cell" banner shows the scope; click ✕ to clear.

## Referencing cells — @id

Type **@** in the chat to autocomplete a cell id; picking one inserts `@id`. The server
expands each `@id` mention into that cell's source and current result, so you can point the
agent at specific cells without it reading everything.

## Models and permissions

Today the in-browser agent runs on **Claude** (via the `claude` CLI) or a **locally-configured
model** (Ollama); support for more agents through **ACP** (the Agent Client Protocol) is planned.

In **☰ → ⚙ Settings**:

- **Agent model** — Sonnet (default), Opus, Haiku, any locally-served model found on your **Ollama**
  or **vmlx** server (both listed automatically), or **Custom…**, which sends an exact model id
  straight through (`ollama:llama3.1`, say). See [Running the Hub](hub.md#Environment-variables).
- **Agent permissions** — `lab` (default: slate/ex/edit tools), `auto` (model
  self-governs), `default` (edits only), or `bypass` (no checks; trusted only).

Both bind when the agent spawns, so changing either reaps the running agent (the transcript
is kept) and the next message respawns on the new setting. A note appears in the chat; if a
turn is in flight you're asked to confirm before it's interrupted.

## Stopping

The **⏹ Stop** button interrupts the in-flight turn. If the agent is wedged, a second press
(**⛔ Force stop**) hard-kills it; the next message spawns a fresh agent (transcript kept).

## Conversation history

The transcript is buffered server-side and **persisted to disk per notebook**, so it
survives both a browser reload and a server restart. The **🧹** button clears it (memory and
disk) and stops the agent.

## Multiple agents on one notebook

A build-floor + version-CAS layer lets several agents (e.g. a [Seaworthy](https://github.com/kahliburke/Seaworthy.jl)
crew) drive one notebook without clobbering each other:

- **Build-floor** — a notebook-scoped lease (`slate_acquire_floor` / `slate_release_floor`).
  While held, only the holder may commit; it auto-expires after idle so a crashed holder
  can't deadlock the notebook.
- **Version-CAS** — when no floor is held, a mutation may carry the `nb.version` it was
  decided against and is rejected if the notebook moved since (lost-update guard).

Both are opt-in, so the solo-agent path is unaffected. Each crew member gets a colored lane
in the chat.

A tool call that reaches the notebook from outside its own chat, such as an agent running in your
terminal or one Kaimon spawned for another notebook, is surfaced in the pane too, marked **⚡
external**. Every write to the notebook is visible in one place. Those are buffered like any other
message, so a reload replays them.

## Tool cells

A `#%% tool` cell holds an `@tool name(arg = value)` call, invoking one of the session's gate tools
in this process and rendering the tool's full declared parameter list beside the result. That turns
an agent's action into a durable, re-runnable part of the document rather than a line in a
transcript.

`slate_tools()` lists what this session exposes. `tool_handle(tc)` threads a background call's run id
into the next call. A tool cell is never swept up by an automatic run, so reopening a notebook or a
reactive update does not re-fire it.

## Working without Kaimon

In standalone mode (no Kaimon) the chat pane reports that the agent service is unavailable —
everything else (cells, widgets, figures, history, export) works.
