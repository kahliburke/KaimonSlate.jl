# ── Per-cell toolbar actions ──────────────────────────────────────────────────
# A `CellAction` is the wire spec for a button an extension adds to EVERY cell's header toolbar —
# the toolbar counterpart of a `@bind` `Widget`. The Slate front-end only ever consumes
# `(id, icon, title, show, onclick)`; the struct never crosses a process boundary. An extension
# authors one the same way it authors a widget — define a type and overload `to_cell_action`
# (with `auto_cell_action` for the reflect-the-struct common case) — then hand it to
# `register_cell_action!` from its `__slate_frontend` hook. The host seam is the JS global
# `window.slateRegisterCellAction`, the toolbar counterpart of `window.slateRegisterEditorExtension`.

"""
    CellAction(id; icon, title="", show="", onclick)

The wire spec for a per-cell toolbar button. `id` is a stable, namespaced identifier (both the
dedup key and the DOM class — let [`auto_cell_action`](@ref) derive it from your type via
[`kind_for`](@ref)); `icon` is the glyph shown (an emoji or HTML entity, like the built-in ▶/🗑
buttons); `title` is the hover tooltip. `show` and `onclick` are **raw JavaScript** the extension
owns (the same trust boundary as shipping a front-end asset):

- `show` — a boolean expression over `cell` (the cell's JSON: `cell.kind`, `cell.tags`, …); `""` ⇒
  always shown. e.g. `"cell.kind === 'code'"`.
- `onclick` — statement(s) run on click, with `cellId`, `cell` and `event` in scope. e.g.
  `"window.myExtInsert(cellId)"` (a front-end helper your extension shipped).

Build one directly, or return one from [`to_cell_action`](@ref) / [`auto_cell_action`](@ref).
"""
struct CellAction
    id::String
    icon::String
    title::String
    show::String
    onclick::String
end

# A stable, namespaced identifier: it's emitted UNESCAPED-for-quotes into an inline `onclick="…('id',…)"`
# and used as a DOM class (`cellact-<id>`), so restrict it to a leading letter + word/./- chars — no
# quotes, spaces, or angle brackets that could break out of the attribute or the class token. `kind_for`
# (the usual source, `Module.Type`) already satisfies this.
const _CELL_ACTION_ID = r"^[A-Za-z][\w.\-]*$"
CellAction(id::AbstractString; icon::AbstractString, title::AbstractString = "",
           show::AbstractString = "", onclick::AbstractString) =
    occursin(_CELL_ACTION_ID, id) ?
        CellAction(String(id), String(icon), String(title), String(show), String(onclick)) :
        throw(ArgumentError("CellAction id $(repr(id)) must be a namespaced identifier matching " *
                            "$(_CELL_ACTION_ID) (e.g. \"MyPackage.MyButton\", as `kind_for` yields)."))

"""
    to_cell_action(x) -> CellAction

Turn `x` into a [`CellAction`](@ref). [`register_cell_action!`](@ref) calls this, so — exactly like
[`to_widget`](@ref) for a `@bind` control — an extension defines its own type and overloads
`to_cell_action` for a typed, documented button (with [`auto_cell_action`](@ref) for the common
reflect-the-struct case):

```julia
Base.@kwdef struct InsertSnippetButton
    icon::String    = "➕"
    title::String   = "insert a snippet"
    show::String    = "cell.kind === 'code'"
    onclick::String = "window.myExtInsert(cellId)"   # a helper this extension shipped
end
SlateExtensionsBase.to_cell_action(a::InsertSnippetButton) = auto_cell_action(a)
```

The identity method means an existing `CellAction` passes through unchanged.
"""
to_cell_action(a::CellAction) = a
to_cell_action(x) = throw(ArgumentError(
    "register_cell_action! expected a CellAction (or a value with a `SlateExtensionsBase.to_cell_action` " *
    "method); got $(typeof(x))"))

"""
    auto_cell_action(x; exclude = ()) -> CellAction

Build a [`CellAction`](@ref) by REFLECTING a struct's fields — the ergonomic `to_cell_action` body,
mirroring [`auto_widget`](@ref). Fields named `icon`, `title`, `show` and `onclick` map to the
matching wire fields (`icon` and `onclick` are required; `title` and `show` default to `""` when the
struct has no such field); the `id` is [`kind_for`](@ref)`(typeof(x))`, so it's namespaced by your
package and can't collide with another extension's button. `exclude` drops named fields.

```julia
SlateExtensionsBase.to_cell_action(a::InsertSnippetButton) = auto_cell_action(a)   # id = "MyPackage.InsertSnippetButton"
```
"""
function auto_cell_action(x; exclude = ())
    T = typeof(x)
    fns = fieldnames(T)
    pick = (name, required) ->
        if name in fns && name ∉ exclude
            String(getfield(x, name))
        elseif required
            throw(ArgumentError("auto_cell_action($T): no `$name` field to reflect — add it, pass it in " *
                                "`exclude` only if intentional, or build the CellAction explicitly."))
        else
            ""
        end
    return CellAction(kind_for(T); icon = pick(:icon, true), title = pick(:title, false),
                      show = pick(:show, false), onclick = pick(:onclick, true))
end

# A JS double-quoted string literal for `s` — Base-only (no JSON dependency), and safe to embed in an
# injected <script> (escapes `<` so a `</script>` in the text can't close the tag early).
function _js_string(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if     c == '"';       print(io, "\\\"")
        elseif c == '\\';      print(io, "\\\\")
        elseif c == '\n';      print(io, "\\n")
        elseif c == '\r';      print(io, "\\r")
        elseif c == '\t';      print(io, "\\t")
        elseif c == '<';       print(io, "\\u003c")
        elseif c < ' ';        print(io, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else                   print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

# The registration <script> for one action: build the spec (id/icon/title are DATA, JS-escaped;
# `show`/`onclick` are the extension's own RAW JS) and call the host seam. If the seam isn't on the
# page yet (extension script raced ahead of the bundle), poll briefly until it is.
function _cell_action_js(a::CellAction)
    showexpr = isempty(strip(a.show)) ? "true" : a.show
    return """
    (function () {
      var spec = {
        id: $(_js_string(a.id)),
        icon: $(_js_string(a.icon)),
        title: $(_js_string(a.title)),
        show: function (cell) { try { return !!($(showexpr)); } catch (e) { return false; } },
        onClick: function (cellId, cell, event) { $(a.onclick); }
      };
      var reg = function () { if (window.slateRegisterCellAction) { window.slateRegisterCellAction(spec); return true; } return false; };
      if (!reg()) { var n = 0, t = setInterval(function () { if (reg() || ++n > 50) clearInterval(t); }, 100); }
    })();
    """
end

"""
    register_cell_action!(x)

Register a per-cell toolbar button contributed by this package — call it from your module's
`__slate_frontend(slate_on)` hook (where you also register editor extensions and RPC handlers). `x`
is any [`to_cell_action`](@ref)-convertible value: a [`CellAction`](@ref), or your own typed button.
Slate injects a small script that calls the front-end seam `window.slateRegisterCellAction`, so the
button appears in every cell's action strip (gated by the action's `show`), clicking it runs the
action's `onclick`. Idempotent — deduped by the action's `id` (a re-run replaces rather than stacks
duplicates), no boot cell. A cell action is an EDITING affordance: it shows in the live editor; a
read-only static export renders no cell toolbar, so the button simply doesn't appear there.
"""
function register_cell_action!(x)
    a = to_cell_action(x)
    provide_frontend!(_cell_action_js(a); id = "cellaction:" * a.id, esm = false)
    return nothing
end
