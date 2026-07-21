# SlateExtensionsBase.jl — an extension SDK for Slate

## Problem (from disberd's critique, verified against the code)

External packages that want to add Slate widgets/renderers/etc. must either:
- depend fully on **KaimonSlate** (heavy; and it can't even be *seen* in the notebook env,
  since the worker runs a Base+stdlib injected namespace and never `using`s KaimonSlate — so
  a weakdep/extension can never trigger), or
- reverse-engineer a pile of **undocumented conventions**: injected globals they can't
  `import` (`Widget`, `custom_widget`, `WebPage`, `slate_emit`, `slate_on`, `@bind`),
  hand-rolled `Base.show(MIME"text/html")` boilerplate to emit a registration `<script>`,
  and a copy-pasted `task_local_storage()[:slate_ctx]` convention.

Evidence: `GiacSlate` and `NeuroSlate` both already extend Slate with **zero** KaimonSlate
dependency — but via exactly those conventions. NeuroSlate even reimplements
`slate_context()`/`_ctx_field` as a private copy of Slate's task-local shape (drifts silently).

## Key enabling fact

The `@bind` sink already reduces a `Widget` to `(name, kind::String, params::Dict, value)`
before it crosses to the engine (`widgets.jl` `_do_bind`). The struct identity never crosses a
process boundary — worker and server only agree on the `{kind, params, default}` *shape*. So a
lean **interface** package is sufficient; no heavyweight shared compiled type is required.
Version skew reduces to Pkg compat on a small, slow-moving package (the AbstractPlutoDingetjes
trade).

## The extension surface (what real packages use)

1. **Input controls (@bind)** — Julia `custom_widget("kind")` → `Widget`; front-end
   `slateRegisterWidget("kind", {wire, sync, destroy})`.
2. **Rich output** — `WebPage`, `@asset`, `Base.show(MIME"text/html")`; package's renderer JS.
3. **JS→Julia RPC** — `slate_on` / `window.slateCall`.
4. **Julia→JS push** — `slate_emit` / `window.slateOnStream`.
5. **Editor** — `slateRegisterEditorExtension` (front-end only).
6. **Execution context** — task-local `:slate_ctx` =
   `(; region, notebook, side, emit, regions, effect)` (`capture.jl` `_build_slate_ctx`).
7. **Cell effects** — `ctx.effect(:everywhere; names)` → region-worker propagation.

## Package: `SlateExtensionsBase.jl` (Base + stdlib only)

### Controls
- `Widget`, `Choice`, `Selection`, `indices` (moved from `widgets.jl`).
- `to_widget(x)::Widget` — identity on `Widget`; `@bind` calls it first, so a package can
  define its own type and overload it (typed ctor + docstring + dispatch).
- `register_kind!(kind; coerce, reconcile, wrap)` — per-kind registry replacing the string
  if-chains in `coerce_bind`/`_reconcile_bind`. Core registers its built-ins through the SAME
  seam (dogfood — the extension point can't rot).

### Output
- `WebPage` (moved from `widgets.jl`).
- `register_widget_js(kind, js) -> <displayable>` — renders to the boot `<script>` calling
  `slateRegisterWidget`; deletes `GiacSlate`'s `MathfieldBoot` boilerplate.

### Execution context (canonical, replaces the copied convention)
- `slate_context()` — the task-local `:slate_ctx` (or `nothing`).
- typed accessors: `slate_region()`, `slate_regions()`, `slate_notebook()`,
  `slate_emit(channel, value)`, `slate_effect(kind; names, data...)`.
- Documents the `:slate_ctx` NamedTuple shape as the published contract.

### Front-end contract (documented JS globals; no Julia dep)
`slateRegisterWidget`, `slateRegisterEditorExtension`, `slateCall`/`slateOnStream`,
`Slate.runFragment`, `Slate.asset`.

## KaimonSlate changes
- Add dep on `SlateExtensionsBase`; the worker loads it as its one real dep.
- `_populate_notebook_ns!` injects the base's `Widget`/`WebPage`/`slate_context`/etc. instead
  of private copies; concrete constructors (`Slider`, `TableSelect`, …) stay in core.
- `_build_slate_ctx` builds the base's documented context shape.
- Built-in kinds registered via `register_kind!` (if we do the dogfood refactor).

## Downstream (proof the SDK is sufficient)
- **GiacSlate**: `import SlateExtensionsBase`; ship `Mathfield()` as a typed `to_widget`; drop
  `MathfieldBoot` for `register_widget_js`.
- **NeuroSlate**: `import SlateExtensionsBase`; delete private `slate_context`/`_ctx_field`.

## Progress / decisions (landed)

Worktree `feat/widget-interface-pkg` (at `../KaimonSlate-widgets`). All uncommitted.

**Decisions made with the user:**
- Architecture **A** (lean base pkg), broadened to a full **extension SDK** (not just widgets).
- Package name **SlateExtensionsBase**, lives in the monorepo at `lib/SlateExtensionsBase`.
- Refactor scope: **full dogfood** (built-ins ride `register_kind!`), sequenced package-first.
- Worker env delivery: **consolidate** the three single-package worker envs (worker_revise +
  worker_ee + a proposed worker_seb) into ONE `src/worker_infra/` env, one LOAD_PATH insert.
- Versioning: **independent + compat guard** (SEB versions by contract stability; a monorepo test
  asserts KaimonSlate's `[compat]` covers lib SEB's version). *(guard test still TODO)*
- Remote SEB delivery: **register SEB in General** like KaimonGate (bare hosts add infra by name);
  ~3-day new-package hold, so local testing covers the migration meanwhile.

**Built + verified:**
- `lib/SlateExtensionsBase` — controls.jl (Widget/Choice/Selection/`to_widget`/`register_kind!` +
  `coerce_bind`/`reconcile_bind`/`wrap_value`), output.jl (WebPage/`register_widget_js`), context.jl
  (`slate_context` + accessors). Base + stdlib Base64 only. **66 unit tests green.** Fixed a latent
  Symbol-keyed-dict bug (one-arg `Choice` hash).
- `src/worker_infra/` — consolidated env (Revise 3.16.1 + ExpressionExplorer 1.1.4 + SEB 0.1.0 path),
  Manifest committed.
- KaimonSlate `Project.toml` — SEB dep via `[sources]` path.
- `src/widgets.jl` — dropped local Widget/Choice/Selection/WebPage; `import`s SEB; built-in kinds
  registered via `register_kind!`; `@bind` → `to_widget`; `_do_bind` handles the "?" placeholder.
- `gate_kernel.jl` single `_INFRA_ENV` insert; `server_history.jl` infra filter; comments in
  `worker.jl`/`macroexpand.jl`/`remote.jl`. `test/test_bind.jl` updated (`reconcile_bind`/`wrap_value`).
- **Full KaimonSlate suite: 4336 pass, 0 fail.**

**Remaining (phase 1 + beyond):**
- Live **worker boot** test (unit suite is in-process; the SlateWorker + worker_infra LOAD_PATH path
  needs a real gate worker) — on the live server.
- Compat-guard test; optional `_build_slate_ctx` → SEB accessors.
- **Sample extension** package + notebook (task 2) — end-to-end proof of the seam.
- **Remote** SEB delivery on `slate-remote` (region name NOT rega/regb) — after registration or via
  shipped source.
- Port **GiacSlate** (typed `Mathfield` via `to_widget`, drop `MathfieldBoot`) + **NeuroSlate**
  (delete private `slate_context`) onto SEB (task 3).

## Field feedback → future extension points / roadmap

From real extension attempts (disberd — PlutoPlotly.jl author; a CesiumJS satellite-streaming
notebook: 300 sats / 3000 ground cells, buffered position windows fetched from Julia as the Cesium
clock nears the buffer edge). Captured as test cases the SDK design should accommodate:

1. **Package-vendored, disk-backed front-end libraries** — a package (e.g. a hypothetical
   `CesiumSlate`) should vendor JS libs that CAN'T be single-file-minified (Cesium ships
   assets/workers; likewise `echarts-gl`), served from disk, **pinned + offline-capable**, as long
   as the package is loaded — WITHOUT forking KaimonSlate's `assets/vendor.json`. Current rails:
   `assets/vendor.json` (pkg→version+baseURL, cached offline, served `/assets/vendor/<pkg>/<sub>`),
   `@use` (importmap→CDN), the public/file route, `save_asset`. **Gap:** none is *package-registered*
   from pkgdir. → a NEW SDK extension point: a package declares a front-end resource dir; Slate
   serves it from a stable package-scoped route (offline/pinned), and it travels in a static export.
   Must fit the remote-worker model (server serves the files; package loads on the worker).
2. **`@asset` package-relative** — today it's a literal string, notebook-relative only. Want a
   pkgdir-anchored resolver (a `pkg_asset`-style macro/fn) so a package ships its own assets. Fits
   the same extension point.
3. **Out-of-order / DAG reactivity** (SEPARATE track — reactive model, not the SDK): reactivity
   currently requires the reader cell BELOW the writer. disberd asks whether Pluto-style
   position-independent DAG reactivity is planned. Needs a product decision.
4. **Diff-based reactive output updates + binary transport** (SEPARATE track — transport/perf):
   only send what changed between reactive re-renders (Pluto's big win), esp. large arrays/tables/
   plots where few points move. Partly already available — `slate_on`/`slate_progress` move BINARY
   over the WebSocket (no JSON needed). Output-diffing is a future optimization, orthogonal to SDK.

## Resolve/instantiate trap + env-prep consolidation (in progress)

Because `widgets.jl` now unconditionally `using SlateExtensionsBase`, EVERY worker boot requires SEB.
A plain notebook gets it from `worker_infra`; an EXTENSION notebook's env *declares* SEB (via the
extension dep) → Julia resolves it from that env, bypassing worker_infra → crashes if the env is
stale/uninstantiated. Two root causes found & fixed:

1. **Forked env dropped `[sources]` + kept relative dev paths.** `_seed_notebook_env!` copied the
   parent's deps/compat/Manifest but not `[sources]`, and the Manifest's SEB `path="../…"` (relative
   to the parent) dangled from the scratch fork dir → "SEB not installed" crash.
2. **No local staleness detection.** The per-notebook env
   (`~/.julia/environments/kaimonslate/<nb>-<hash>`) persists; `_select_kernel` branched only on
   "does Project.toml exist" → a fork seeded before the parent gained SEB stayed stale forever; a
   restart just reused it. The REMOTE provisioner already had staleness + rebuild-on-failure; local
   didn't.

Fix (DRY, per steer): new **`src/envprep.jl`** — shared policy included into ReportEngine + SlateWorker:
`seed_env_project!` (deps/compat/`[sources]` with dev paths made ABSOLUTE + Manifest path-deps
absolutised), `env_parent_fingerprint`/`stamp_env!`/`env_stale` (fingerprint the parent so a change is
detected). `worker.jl _seed_notebook_env!` uses it + stamps. `server.jl`: `_instantiate_env!`
generalized (`code` kwarg, returns ok); new self-healing `_rebuild_notebook_env!` (re-seed + subprocess
develop+instantiate + reset-and-retry, mirroring remote's `build_env!`); `_select_kernel` rebuilds a
stale fork BEFORE spawn. Existing forks have no `.slate-parent` stamp → read stale → auto-rebuilt.
REMAINING: refactor remote.jl to adopt the shared fingerprint/staleness (its rsync-rewrite is the
remote transport of the same dev-path rule); register SEB in General = the durable end of dev-path
fragility. custom_controls left broken until the extension restarts (per steer — no manual env delete).

## Package front-end registry — INCOMPLETE (finish GiacSlate on it FIRST)

SEB `frontend.jl` (`register_widget!`/`provide_frontend!`) is committed but **DORMANT — it does
nothing yet** (no hub wiring). This is half-built scaffolding; treat it as NOT done. Completing
GiacSlate on it is the #1 next task ([[finish-features-completely]]). "Done" =

1. **Hub harvests the `:frontend` cell-effect + injects the script** into the page (live shell +
   static export). SEB already declares it via `ctx.effect(:frontend; id, js)`; the hub side (harvest
   in `run_capture`/`CellOutput.effects` → page injection) is missing.
2. **`slate_on` HANDLER auto-registration** — the registry as designed only carries front-end
   SCRIPTS, but GiacSlate's real breakage is the missing `giac_src`/`giac_tex` Julia handlers. Add a
   context `:on` accessor (SEB `slate_context`) so `__init__` can register handlers into the
   notebook's `__slate_handlers`. WITHOUT THIS the boot cell can't be deleted.
3. **Convert GiacSlate** to `__init__` auto-registration (widget JS + editor-ext JS + giac handlers);
   DELETE `mathfield_boot`/`inline_math_boot` + boot cells (no compat shims).
4. **Live-validate**: `custom_controls` + `laplace_lesson` work with ONLY `using GiacSlate`.

THEN extend to `provide_assets!(dir)` — package-scoped served route + whole-dir publish-sibling for
Cesium/echarts-gl (standalone single-file can't inline heavy asset trees — served/pinned mode).

## Open scope fork (resolved — see Progress above)
- **Full dogfood** — rewrite core coerce/reconcile as `register_kind!` calls (cleanest;
  touches load-bearing bind logic; needs the bind test suite green).
- **Conservative** — base owns types + `to_widget` + the unknown-kind hook; core keeps its
  existing if-chain and only routes *unknown* kinds through the registry (smaller blast radius).
</content>
</invoke>
<invoke name="AskUserQuestion">
<parameter name="questions">[{"question": "How aggressive should the core refactor be when wiring KaimonSlate onto SlateExtensionsBase?", "header": "Refactor scope", "multiSelect": false, "options": [{"label": "Full dogfood (Recommended)", "description": "Rewrite core's coerce_bind/_reconcile_bind string if-chains as register_kind! calls, so built-in widgets ride the exact same extension seam third parties do. Cleanest and self-testing; touches load-bearing bind logic, so I'll keep the bind test suite green throughout."}, {"label": "Conservative", "description": "Base owns Widget/Choice/WebPage/to_widget + slate_context + an unknown-kind hook. Core keeps its existing coerce/reconcile if-chain and only routes UNKNOWN kinds through the registry. Smaller blast radius, but built-ins and extensions use slightly different paths."}, {"label": "Just the package first", "description": "Build SlateExtensionsBase.jl standalone (types + interface + context + docs) and prove it by porting GiacSlate/NeuroSlate onto it, BEFORE touching KaimonSlate's injection at all. Lowest risk; core rewiring is a follow-up once the SDK shape is validated."}]}]