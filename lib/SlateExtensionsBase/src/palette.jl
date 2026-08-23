# ── Command-palette commands ──────────────────────────────────────────────────
# A `PaletteCommand` is the wire spec for an entry an extension adds to the ⌘K command palette —
# the palette counterpart of a `CellAction`. The Slate front-end only ever consumes
# `(id, label, tag, key, run)`; the struct never crosses a process boundary. An extension authors
# one exactly like a cell action — define a type and overload `to_palette_command` (with
# `auto_palette_command` for the reflect-the-struct case) — then hand it to
# `register_palette_command!` from its `__slate_frontend` hook. The host global is
# `window.slateRegisterCommand`.
#
# Palette commands are how an extension surfaces the things that have no natural home on a cell:
# "open my panel", "insert a worked example", "reconnect the device". A `CellAction` is per-cell and
# lives in the cell toolbar; a palette command is notebook-global and lives behind ⌘K.

"""
    PaletteCommand(id; label, tag="", key="", run)

The wire spec for one ⌘K command-palette entry. `id` is a stable, namespaced identifier and the
dedup key (let [`auto_palette_command`](@ref) derive it from your type via [`kind_for`](@ref)).
`label` is the searchable text shown in the list. `tag` is an optional short badge on the right
(the built-ins use `panel`, `export`, `recipe`, …); it defaults to the package name, so a user can
type your package's name to see everything it contributes. `key` is a **display-only** shortcut
hint — registering a command does not bind a key.

`run` is **raw JavaScript** the extension owns (the same trust boundary as shipping a front-end
asset): statement(s) executed when the command is chosen, with `selectedId` (the currently selected
cell id, or `''`) in scope. e.g. `"window.myExtPanel()"` — a helper your extension shipped.

Build one directly, or return one from [`to_palette_command`](@ref) /
[`auto_palette_command`](@ref).
"""
struct PaletteCommand
    id::String
    label::String
    tag::String
    key::String
    run::String
end

# Same restriction as `CellAction`: the id is emitted into JS and used as a dedup/DOM key, so keep
# it to a leading letter + word/./- chars. `kind_for` (the usual source, `Module.Type`) satisfies it.
const _PALETTE_ID = r"^[A-Za-z][\w.\-]*$"
PaletteCommand(id::AbstractString; label::AbstractString, tag::AbstractString = "",
               key::AbstractString = "", run::AbstractString) =
    occursin(_PALETTE_ID, id) ?
        PaletteCommand(String(id), String(label), String(tag), String(key), String(run)) :
        throw(ArgumentError("PaletteCommand id $(repr(id)) must be a namespaced identifier matching " *
                            "$(_PALETTE_ID) (e.g. \"MyPackage.OpenPanel\", as `kind_for` yields)."))

"""
    to_palette_command(x) -> PaletteCommand

Turn `x` into a [`PaletteCommand`](@ref). [`register_palette_command!`](@ref) calls this, so —
exactly like [`to_cell_action`](@ref) for a toolbar button — an extension defines its own type and
overloads `to_palette_command` for a typed, documented command (with
[`auto_palette_command`](@ref) for the common reflect-the-struct case):

```julia
Base.@kwdef struct OpenGlobePanel
    label::String = "Globe: open the layer panel"
    run::String   = "window.globeSlateOpenPanel()"
end
SlateExtensionsBase.to_palette_command(c::OpenGlobePanel) = auto_palette_command(c)
```

The identity method means an existing `PaletteCommand` passes through unchanged.
"""
to_palette_command(c::PaletteCommand) = c
to_palette_command(x) = throw(ArgumentError(
    "register_palette_command! expected a PaletteCommand (or a value with a " *
    "`SlateExtensionsBase.to_palette_command` method); got $(typeof(x))"))

"""
    auto_palette_command(x; exclude = ()) -> PaletteCommand

Build a [`PaletteCommand`](@ref) by REFLECTING a struct's fields — the ergonomic
`to_palette_command` body, mirroring [`auto_cell_action`](@ref). Fields named `label`, `tag`, `key`
and `run` map to the matching wire fields (`label` and `run` are required; `tag` and `key` default
to `""` when the struct has no such field); the `id` is [`kind_for`](@ref)`(typeof(x))`, so it's
namespaced by your package and can't collide with another extension's command. `exclude` drops
named fields.
"""
function auto_palette_command(x; exclude = ())
    T = typeof(x)
    fns = fieldnames(T)
    pick = (name, required) ->
        if name in fns && name ∉ exclude
            String(getfield(x, name))
        elseif required
            throw(ArgumentError("auto_palette_command($T): no `$name` field to reflect — add it, pass " *
                                "it in `exclude` only if intentional, or build the PaletteCommand explicitly."))
        else
            ""
        end
    return PaletteCommand(kind_for(T); label = pick(:label, true), tag = pick(:tag, false),
                          key = pick(:key, false), run = pick(:run, true))
end

# The default `tag`: the package that owns the command, taken from the id's leading segment
# ("GlobeSlate.OpenPanel" → "GlobeSlate"). Typing the package name in ⌘K then surfaces everything
# that package contributes, which is the discovery path once the catalog has installed it.
_palette_tag(c::PaletteCommand) = isempty(c.tag) ? first(split(c.id, '.')) : c.tag

# The registration <script> for one command: id/label/tag/key are DATA (JS-escaped); `run` is the
# extension's own RAW JS. If the host global isn't on the page yet (extension script raced ahead of
# the bundle), poll briefly until it is — same shape as `_cell_action_js`.
function _palette_command_js(c::PaletteCommand)
    return """
    (function () {
      var spec = {
        id: $(_js_string(c.id)),
        label: $(_js_string(c.label)),
        tag: $(_js_string(_palette_tag(c))),
        key: $(_js_string(c.key)),
        run: function (selectedId) { $(c.run); }
      };
      var reg = function () { if (window.slateRegisterCommand) { window.slateRegisterCommand(spec); return true; } return false; };
      if (!reg()) { var n = 0, t = setInterval(function () { if (reg() || ++n > 50) clearInterval(t); }, 100); }
    })();
    """
end

"""
    register_palette_command!(x)

Register a ⌘K command-palette entry contributed by this package — call it from your module's
`__slate_frontend(slate_on)` hook (where you also register cell actions, editor extensions and RPC
handlers). `x` is any [`to_palette_command`](@ref)-convertible value: a [`PaletteCommand`](@ref), or
your own typed command. Slate injects a small script that calls the front-end global
`window.slateRegisterCommand`, so the command appears in the palette alongside the built-ins,
badged with your package name. Idempotent — deduped by the command's `id` (a re-run replaces rather
than stacks duplicates), no boot cell.

A palette command is an EDITING affordance: it shows in the live editor. A read-only static export
renders no palette, so the command simply doesn't appear there.

```julia
function __slate_frontend(slate_on)
    provide_frontend!(@pkg_asset("assets/globe_tools.js"); id = "GlobeSlate.tools")
    register_palette_command!(PaletteCommand("GlobeSlate.OpenPanel";
        label = "Globe: open the layer panel", run = "window.globeSlateOpenPanel()"))
end
```
"""
function register_palette_command!(x)
    c = to_palette_command(x)
    provide_frontend!(_palette_command_js(c); id = "palettecmd:" * c.id, esm = false)
    return nothing
end
