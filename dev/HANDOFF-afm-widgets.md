# Handoff — AFM widget hosting in Slate (SlateAFM) + the binary-buffer task

## Goal
Host **Anywidget Front-end Modules (AFM)** in Slate as a *pure extension* (no server fork), so
anywidget-ecosystem widgets run unchanged. Spec: https://anywidget.dev/en/afm/ — an AFM is an ES module
`export default { initialize?, render? }` driving a host `model` (get/set/on/save_changes/send) into an
`HTMLElement`, with `AbortSignal` cleanup.

## Where everything is
- **Worktree**: `/Users/kburke/devel/KaimonSlate-afm`, branch `feat/afm-widgets` (off `main` @ `b003f891`,
  which has `provide_assets!`). **Local + UNPUSHED.**
- **Package**: `examples/extensions/SlateAFM/` — the AFM host extension.
- **Main checkout**: `/Users/kburke/devel/KaimonSlate.jl` (branch `main`). Has the `provide_assets!` port
  committed (`b003f891`, unpushed) and the SEB `pkg_key`/Module/macros refinement **uncommitted** in its
  working tree (that refinement IS committed here on the branch as `8b592f5e`). Reconcile when merging.
- The user's live Slate hub runs from a *different* worktree (`.claude/worktrees/feat+bonito-support`,
  port 8765) — NOT this code. Don't touch it.

## Commits on `feat/afm-widgets` (unpushed)
```
3bec0d89 refactor(SlateAFM): drop afm_example + vendored widget; ext_asset_url is the API
9d26ab56 feat(SlateAFM): composition, css injection, msg wiring, real-widget demo
1794f510 feat(example): SlateAFM — host Anywidget Front-end Modules (AFM)
8b592f5e feat(seb): derive the vendored-asset package key from the module   (pkg_key/Module/@macros)
b003f891 feat(slate): serve package-vendored asset directories (provide_assets!)  [base, on main]
```
History was rewritten (`git filter-branch`) to **expunge** a hand-vendored third-party widget
(`pdbemolstar.js`) — anywidget code must NOT live in this repo. Don't re-add it.

## What works (browser-verified by the user)
Pure Slate extension, no server changes:
- `provide_frontend!` injects `assets/afm-host.js` (inlined via `@pkg_asset`) → registers the
  `SlateAFM.AFM` widget kind via the low-level `slateRegisterWidget(wire/sync/destroy)`.
- **AnyModel** adapter over Slate's single bound value treated as a **traits Dict**: `get`, `set`
  (fires `change:<key>` synchronously — backbone semantics, required for self-redraw), `on`/`off`
  (`change:`, `change`, `msg:custom`), `save_changes` (commits the dict → reactive reader cells), `send`.
- `AbortSignal` cleanup; error-abort (failed hook aborts the signal).
- **Composition**: real `host.getWidget(ref)`/`getModel(ref)` — page-global registry by `id`,
  `initialize()` exports captured, `getWidget` awaits a per-instance `ready` promise (no init race).
- **`css`** param: host injects stylesheet URL(s) before render (deduped).
- **`msg:custom` text both ways** via `slate_on`/`slate_emit` (`afm_on_msg(f,id)` / `afm_emit(id,content)`).
- Accepts every AFM export shape (default object, sync/async factory, legacy named `render`/`initialize`).
- Examples (ours, in `assets/examples/`): `counter`, `slider`, `control`+`readout` (composition).
- **Proven**: loaded `ipymolstar` (PDBe Mol\*) *unchanged* end-to-end. Its ESM is NOT in the repo; to test
  again, refetch: `pip3 download ipymolstar --no-deps -d /tmp/x && unzip the wheel →
  ipymolstar/static/pdbemolstar.js` (8 KB; it CDN-imports the Mol\* plugin). Load with
  `css="https://cdn.jsdelivr.net/npm/pdbe-molstar@3.3.2/build/pdbe-molstar.css"`, `molecule_id="1cbs"`,
  `spin=false`, `height/width` traits — but keep it out of the committed package (notebook-local or a
  runtime fetch, not vendored).

## Public API (`src/SlateAFM.jl`)
- `afm(src; id="", css=[], traits...)` — `src` is an ESM URL; bound value = the traits Dict.
- `ext_asset_url(Pkg, path)` (re-exported from SEB) — the module-reference mechanism for a package-served
  module (this replaced the removed `afm_example`). Or a plain CDN URL.
- `afm_on_msg(f, id)`, `afm_emit(id, content)`.
- **Install model** (documented, NOT built — this is the parked "Q2" discussion): tier 1 CDN URL, tier 2
  package-served via `ext_asset_url`, tier 3 = a local-file helper OR shell out to a `pip`/`python` on
  `PATH` to fetch a PyPI anywidget's `_esm`/`_css`/trait-defaults into a served scratch dir. **The user
  wants NO Python/Conda dependency in the package** — system-tool shell-out or manual only.

## ✅ DONE: binary buffers (both directions, real binary — no base64)
AFM `model.send(content, callbacks, buffers)` (JS→Julia) and `on("msg:custom", (content, buffers))`
(Julia→JS) now carry real `ArrayBuffer`s over the established Slate binary WebSocket — **no base64**.

**What shipped (spans the KaimonSlate worktree + SlateAFM):**
- **Julia→JS**: `afm_emit(id, content; buffers)` emits a JSON content frame `{content, mid, nbuf}` + one
  `UInt8` `SlateBinary` frame per buffer (meta `{mid, bi, nbuf}`); the host shim reassembles by `mid` and
  fires `on("msg:custom", content, buffers)` with real `ArrayBuffer`s. Fixed a real KaimonSlate gap: the
  **in-process kernel's `slate_emit` ignored `SlateBinary`** (`src/eval.jl`) — it now routes onto the binary
  frame path like the worker does.
- **JS→Julia binary UPLINK** (new KaimonSlate-core feature): `wscall.js` gained a binary frame ENCODER and
  `slateCall(channel, args, onProgress, buffers)` — buffers ride as native binary WS frames (same
  `encode_binary_frame` layout, dtype UInt8) correlated by call id, sent before the JSON call (which carries
  `nbuf`). The hub decodes them (`_decode_uplink_frame` in `server_complete.jl`, using the hub's JSON for the
  tiny meta — SEB needs nothing), accumulates per call id in `_ws_calls`, and injects them into the call as
  `args.__slate_buffers::Vector{Vector{UInt8}}` (crossing to a worker via the gate's Serialization). Added
  `_slate_args(::Vector{UInt8}) = x` (`src/widgets.jl`) so raw buffers aren't exploded into `Vector{Any}`.
- **Also fixed**: SlateAFM's `__slate_frontend` used `slate_on("SlateAFM.msg") do a …` — a do-block, which
  binds the closure as the FIRST arg, so `slate_on(channel, f)` registered under the closure's gensym name
  instead of the channel (no message ever reached Julia). Now an explicit `slate_on(channel, f)` call.
- **Tests**: `test/test_wscall_binary.jl` (frame round-trip, `_slate_args` byte passthrough, in-process
  `SlateBinary` routing) — 19 assertions, green.
- **Verified**: full browser round-trip works (`model.send` UInt8Array → Julia handler → reversed bytes back
  as an `ArrayBuffer`), and server-side by feeding a synthetic frame through the real decode+dispatch.

**Dev-loop note:** the widget shim (`afm-host.js`) registers PROCESS-GLOBALLY, so a changed shim only reaches
the browser after a **fresh hub process** (revise+reopen is not enough for the injected JS) — restart the
side hub, then hard-reload the page.

### Original transport notes (kept for reference)
AFM `model.send(content, callbacks, buffers)` (JS→Julia) and `on("msg:custom", (content, buffers))`
(Julia→JS), where `buffers` are `ArrayBuffer`/`DataView[]`.

**Transport reality (already investigated):**
- **Julia→JS has real binary**: `slate_emit_bin` + `SlateExtensionsBase.encode_binary_frame` →
  self-describing binary WS frame `[u8 ver=1][u16 chanLen][chan][u16 metaLen][metaJSON][u8 dtype][u8 rank]
  [rank×u32 dims][raw LE bytes]`; `src/assets/js/wscall.js` `_dispatchBinary` decodes it to a **typed
  array** delivered via `window.onCellStream(channel, {…meta, d: TypedArray, dims})`. dtype table
  (`_TYPED`): `[Float32,Float64,Int32,Int16,Uint8]`. Wire-up: `src/server.jl:146` `_wire_callbacks!`
  `register_bin_emit!` → `_ws_broadcast_bin!`; `src/eval.jl` ~L104 documents the `slate_emit_bin` path.
- **JS→Julia has NO native binary**: `wscall.js` `slateCall` does `ws.send(JSON.stringify({args}))` — JSON
  only. A browser→server binary frame protocol does NOT exist (would be real KaimonSlate server work).

**Agreed plan (user was confirming "this way" vs a full server uplink — reconfirm on resume):**
- **Julia→JS**: build on `encode_binary_frame` (true binary). Deliver each AFM buffer as a `Uint8` typed
  array; correlate the message's `content` (a normal `slate_emit`) with its N buffer frames via a message
  id in `meta` so the host can assemble `on("msg:custom", content, buffers)`.
- **JS→Julia**: **base64-in-JSON** interim (`slateCall("SlateAFM.msg", {ch, content, buffers:[b64…]})`,
  Julia base64-decodes to `Vector{UInt8}`). No server change. Flag true-binary uplink as a separate task.

**Files to touch:**
- `examples/extensions/SlateAFM/assets/afm-host.js` — `makeModel`: `send(content,cb,buffers)` (base64 the
  buffers into the slateCall payload); `_recv(content, buffers)` and the `slateOnStream(msgCh,…)`/binary
  hook so `on("msg:custom")` gets real `ArrayBuffer`s from typed-array frames. Currently `send` ignores
  buffers and `_recv` passes `m.buffers` (undefined).
- `examples/extensions/SlateAFM/src/SlateAFM.jl` — `afm_emit(id, content; buffers=[])` emits content +
  per-buffer binary frames (via SEB `encode_binary_frame`/`slate_emit_bin`); `slate_on("SlateAFM.msg")`
  handler base64-decodes incoming buffers before calling the registered handler.
- Reference: `src/assets/js/wscall.js`, `src/eval.jl`, and `lib/SlateExtensionsBase/src/binary.jl`
  (`encode_binary_frame`, `SlateBinary`).
- Add a demo: e.g. a widget that sends/receives a small `Uint8Array` to prove both directions.

## Running environment
- Owned hub: gate session **`a296ea1f`** (name `afm-worktree`) runs a KaimonSlate hub on **:8791** serving
  `afm_demo`. `H` is the hub, `KaimonSlate.find_live(H, "afm_demo")` → the notebook. SlateAFM is
  `Pkg.develop`'d into this session's env.
- Unrelated owned hub: session `b021676a` on :8790 (GlobeSlate globe demo) — ignore/close.
- If the session is gone: `start_session(/Users/kburke/devel/KaimonSlate-afm)`, then in it:
  `import Pkg; Pkg.develop(path=".../SlateAFM"); using KaimonSlate; H=KaimonSlate.start_hub(port=8791);
  KaimonSlate.open_notebook!(H, ".../SlateAFM/notebooks/afm_demo.jl"; autorun=true)`.

## Dev-loop gotchas (READ THIS)
1. **Hot-reload SlateAFM.jl**: `import Revise, SlateAFM; Revise.revise(SlateAFM)` works. (The bare
   `Revise.revise()` is stripped by the gate — always pass the module.)
2. **`afm-host.js` is INLINED, not served.** After editing it: `SlateAFM.__slate_frontend((c,f)->nothing)`
   then `KaimonSlate.NotebookServer._refresh_extensions!(nb)` to re-read it into the registry, then reload
   the browser (normal reload — it's page state, not cached).
3. **Served `/ext-assets` modules are `Cache-Control: immutable`** → editing an example `.js` needs a
   **hard** browser reload (Cmd-Shift-R). (Doesn't apply to the inlined `afm-host.js`.)
4. **Dev-dep dance**: committing reverts `Project.toml` (the temp `SlateAFM` dev-dep is removed for clean
   commits), so `import SlateAFM` breaks afterward — `Pkg.develop(path=…SlateAFM)` again. Always
   `git checkout -- Project.toml` before committing (it's a temp dev-dep, not part of the feature).
5. **`manage_repl restart` TIMES OUT** on a live hub (teardown hangs) and drops the session (frees the
   port). To reload from a clean process: start a fresh session + re-`develop` + `start_hub` + open.
6. **Pick up `.jl` cell edits**: `close_notebook!` + `open_notebook!(…; autorun=true)`.
7. **Testing is browser-side** (DOM/WebGL/interactivity) — the agent can't see it; the user eyeballs.
   Verify server-side with `ex()` (`nb.assets`, a cell's `output.binds[1].params/value`, the echart/spec)
   and `curl http://127.0.0.1:8791/ext-assets/SlateAFM/…`.

## Also parked
- ~~Binary buffers~~ — DONE (see above).
- Q2 install-mechanism discussion (system-pip/local-file, no Python dep).
- SEB refinement is uncommitted in the `main` working tree (dup of `8b592f5e`) — reconcile on merge.
- `main`'s `b003f891` (provide_assets) is unpushed.
