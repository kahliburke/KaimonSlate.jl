# Changelog

Notable changes to SlateExtensionsBase, newest first. This package versions separately from
KaimonSlate, which lives in the same repository; see the root `CHANGELOG.md` for that.

Two things to know about the published GitHub releases for this package:

- Their auto-generated **"Merged pull requests" and "Closed issues" lists belong to KaimonSlate**,
  not to this package. TagBot reports everything merged since the previous tag of any kind in the
  repository, so a SlateExtensionsBase release lists notebook features that never touched `lib/`.
  Those lists are left out here, and only changes to this package are recorded.
- Five releases went out with no notes written. Those entries are reconstructed from the commits
  that touched `lib/SlateExtensionsBase`, and say so.

## [Unreleased]

## [0.11.1] - 2026-10-07

### Added

`HookLogger(inner, handle; min_level, shouldlog)` is a logger whose behaviour is supplied as
functions, called in the latest world. A package compiled into a sysimage runs in the world the image
was built in, and a custom compiler (GPUCompiler's, for one) asks the current logger for its level
while inferring. A logger type defined outside the image is invisible from there; this one is in the
image along with this package.

`slate_on(channel) do args … end`, the do-block form. A do-block passes the function first, which
previously registered the pair the wrong way round and left the channel unreachable.

### Fixed

A `WebPage`'s script runs in a block of its own. A cell that rendered again, or two cells, declared
the same top-level `const` or `let` twice in the page's one global scope, and the browser rejected
the whole script. A top-level `function` is still visible to the page's markup.

## [0.11.0] - 2026-10-04

### Breaking

`Choice`'s `Base` methods are narrowed to scalar value types. A `Symbol`-valued `Choice` no longer
compares or converts as its value; read `pick.value`. `===` and `isequal` never honoured the
transparency, so `.value` was already the only reliable spelling. Number, string and character
choices are unchanged.

This removes the methods that made importing the package invalidate already-compiled code: a
one-argument `hash` and an untyped mixed `==` intersect call sites Base and loaded packages have
compiled, which cost seconds on a notebook's first render.

### Added

`slate_save_asset(name, data; mime, dtype)` saves bulk data as a cell asset from a package's
`slate_render` or `show` method and returns a path for `Slate.asset` in the browser. Returns
`nothing` where no asset store is open, so a render can fall back to inlining.

## [0.10.6] - 2026-09-25

*Reconstructed; no notes were published with the release.*

### Added

- A widget kind registered from outside Slate can declare its own replay domain, so an extension's
  control is exportable in a static page.
- An extension's palette command declares its default key binding, which the rebindable-keymap work
  in KaimonSlate 1.8.0 reads as a default rather than a display hint.

## [0.10.5] - 2026-09-12

Adds a control surface for extensions that draw a `@bind` control themselves, a widget inside a
figure or a custom panel, while the `@bind` variable stays the single source of truth.

- `slate_bind_widget(name)` is the declared `Widget`, so a native control can be built from the same
  domain and the two cannot disagree about which values are legal
- `slate_bind_value(name)` is the current value, so a rebuilt control opens where the reader left it
- `slate_bind_names()` is every control the notebook declares
- `slate_on_bind(name, f)` runs `f(value)` on every change and returns a thunk that removes the
  listener
- `slate_bind_observable(name)` is the value as a cell-local `Observable`, for a figure that updates
  in place rather than being rebuilt

All five are no-ops outside a Slate cell, so package code can call them unconditionally.

Purely additive: nothing was removed or changed, so this stays inside 0.10 rather than forcing every
extension pinned at `"0.10"` to re-release. The accessors are populated by KaimonSlate 1.7.0 and
later; an older core returns `nothing` from each of them, so check for the capability before relying
on it.

## [0.10.4] - 2026-09-01

*Reconstructed; no notes were published with the release.*

### Added

- The wire dtype table is generated from one Julia source, `DTYPES`, which previously existed as
  four hand-kept copies across the frame encoder, the asset packer and both browser decoders.
  Numeric arrays gain `Int8`, `UInt16`, `UInt32`, `Int64`, `UInt64`, `Bool` and `Float16` alongside
  the previous five types. `Int64` is the one that mattered, Julia's default integer, previously
  rejected outright; it maps to `BigInt64Array` rather than narrowing.
- `DTYPES` is documented, so its docs cross-reference resolves.

Required by KaimonSlate 1.4.4.

## [0.10.3] - 2026-08-29

### Fixed

- **A slider's domain is built from its range rather than accumulated steps.** A control declared as
  `Slider(-3.0:0.1:3.0)` holds one of that range's floats, but the domain was rebuilt as
  `lo + i*step`, which drifts off them (34 of those 61 positions differed in the last bits). The
  domain is matched by `isequal`, so a slider parked on a drifted position matched nothing and
  `@replay` exported a mark with no data for where the reader actually was.

## [0.10.2] - 2026-08-24

*Reconstructed; no notes were published with the release.*

- Supports `@replay` for every control with a finite domain, and a table following its control in a
  static export.

Required by KaimonSlate 1.3.0.

## [0.10.1] - 2026-08-23

*Reconstructed; no notes were published with the release.*

- Supports extending an open page's ES module import map rather than requiring a reload, so a
  `using YourExtension` in a live notebook makes `import "spec"` resolve.
- Carries the metadata the extension catalog and gallery read.

## [0.10.0] - 2026-08-21

### Breaking

- `SlateBinary` now holds a dense `Array` by **reference** instead of copying it. The frame carries
  whatever the array holds when it is *encoded*, not when it was *constructed*, so identical calling
  code can send different bytes than it did under 0.9.x, silently and with no error.

  **Upgrade:** if you construct a frame and then mutate or reuse that buffer before emitting it,
  pass `snapshot = true` to take a copy at construction and restore the previous behaviour:

  ```julia
  SlateBinary(buf; snapshot = true, meta...)
  ```

  If you emit straight away, or you allocate a fresh array per frame, nothing changes, and reusing
  one buffer across frames is now free, which is the point of the change.

  Any non-contiguous `AbstractArray` (a view, a range, an adjoint) still has to be gathered, so it is
  copied either way and `snapshot` is accepted and ignored there.

### Added

- `UploadedFile`, the value a `FileUpload` control binds.
- Fence renderers: `register_fence_renderer!`, `fence_renderer`, `fence_languages`, `render_fence`,
  letting an extension claim a markdown code-fence language.
- `provide_import!`, a package-declared ES module import map entry.

Required by KaimonSlate 1.2.0.

## [0.9.1] - 2026-08-14

### Fixed

- `slate_render` now runs ONE time for each display. `showable` has to run the render to answer, and
  the display capture asks both Slate MIMEs before showing the winner, so a single display ran an
  extension's render 2 times for a component descriptor and 3 times for an HTML fragment. The new
  `with_render_memo(f)` marks the span of one display; inside it the first render is kept and the
  other calls read it, and outside a span nothing is kept. This matters for a render that is not pure
  or not cheap: a WGLMakie figure's render opens a Bonito session, and it must happen once. The memo
  holds the value itself and compares with `===`, so a mutable value changed between two displays
  still renders again.

  `with_render_memo` is host plumbing and is not exported; an extension defines `slate_render` and
  never calls it.

  Thanks to @disberd for the diagnosis and the fix (#19).

## [0.9.0] - 2026-08-03

*Reconstructed; the published notes for this release list KaimonSlate's pull requests rather than
this package's changes.*

First release in General: a lean SDK for extending Slate without depending on the KaimonSlate
server.

### Added

- **Widget authoring by dispatch.** Preact and signals components, kinds derived from the type, and
  lazily loaded assets, so a package adds a `@bind` control without a boot cell.
- **Rich output.** `slate_render` and the Slate display MIMEs, so a package decides how its values
  appear in a cell.
- **A package-global front-end hook.** Editor extensions and JavaScript-to-Julia handlers with no
  boot cell required.
- **`SlateBinary`**, the numeric frame for the binary WebSocket transport.
- **`provide_assets!`**, serving a package-vendored asset directory, with the key derived from the
  module.
- **Cell actions**, `register_cell_action!` paired with `slateRegisterCellAction` on the front end.
- **Served byte assets, the live-render trait, and a reset hook.**
- Front-end registries are guarded against concurrent binds.

[Unreleased]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.11.0...HEAD
[0.11.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.10.6...SlateExtensionsBase-v0.11.0
[0.10.6]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.10.5...SlateExtensionsBase-v0.10.6
[0.10.5]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.10.4...SlateExtensionsBase-v0.10.5
[0.10.4]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.10.3...SlateExtensionsBase-v0.10.4
[0.10.3]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.10.2...SlateExtensionsBase-v0.10.3
[0.10.2]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.10.1...SlateExtensionsBase-v0.10.2
[0.10.1]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.10.0...SlateExtensionsBase-v0.10.1
[0.10.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.9.1...SlateExtensionsBase-v0.10.0
[0.9.1]: https://github.com/kahliburke/KaimonSlate.jl/compare/SlateExtensionsBase-v0.9.0...SlateExtensionsBase-v0.9.1
[0.9.0]: https://github.com/kahliburke/KaimonSlate.jl/releases/tag/SlateExtensionsBase-v0.9.0
