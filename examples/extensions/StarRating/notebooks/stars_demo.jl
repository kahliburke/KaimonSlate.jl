try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=8e6c70
@md"""
# StarRating — a third-party Slate widget

This notebook uses the **StarRating** extension package, which depends only on
`SlateExtensionsBase` (not KaimonSlate). It adds a typed `@bind` star-rating control end to end:
```
@bind rating Stars(; max = 5, label = "How good is Slate's extension SDK?")
```
"""

#%% code id=pkg
using StarRating

#%% code id=bind
@bind rating Stars(; max = 5, label = "How good is Slate's extension SDK?", default=0)

#%% md id=readout
@md"""
{{rating > 0 ? "You rated it " : "Oh come on, tell us how you really feel!"}} {{rating > 0 ? join(repeat(['⭐'],rating)) : "" }} — click the stars above and this line updates reactively.
"""

#%% md id=seams
@md"""
## …and two more extension seams — try them here

StarRating is a **testbed for the whole extension SDK**, so beyond the `@bind` widget above it wires up
two *front-end* seams from its `__slate_frontend` hook (no `__init__`, no boot cell). Both act on the
**code cells** in this notebook — hover a code cell's header:

- **Toolbar action** (`register_cell_action!`) — every code cell's header has a **★** button. Click it to
  scaffold a `@bind rating Stars()` control right into that cell.
- **Editor extension** (`slateRegisterEditorExtension`) — click into a code cell and press
  **Ctrl-Alt-8** to insert a ★ at the cursor (a CodeMirror keymap, code cells only).

Give them a spin in the scratch cell below.
"""

#%% code id=scratch
# ▼ Try it here — hover this cell's header and click the ★ button to scaffold a Stars() control,
#   or click into this cell and press Ctrl-Alt-8 to drop a ★ at the cursor.

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = f3c93d7e-ef22-4607-ae79-55ba30b6fe22
# ╚═╡
