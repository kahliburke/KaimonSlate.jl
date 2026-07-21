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

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = f3c93d7e-ef22-4607-ae79-55ba30b6fe22
# ╚═╡
