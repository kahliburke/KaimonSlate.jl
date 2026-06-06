#%% md id=intro
# 🎛 `@bind` — real Julia widgets

This notebook exercises the **rewritten `@bind`**: widgets are real constructors,
`@bind` runs as ordinary Julia (so widget args can be *computed*), and controls are
reported back through eval. Drag the sliders and watch the charts react.

#%% code id=controls
@bind n Slider(20:5:200)
@bind freq Slider(1:0.5:10)

#%% code id=wave
xs = range(0, 2π; length = Int(n))
ys = round.(sin.(freq .* xs); digits = 3)
echart(Dict(
    "title"  => Dict("text" => "sin(freq·x),  n=$(Int(n)) pts,  freq=$freq"),
    "xAxis"  => Dict("type" => "category", "data" => round.(collect(xs); digits = 2), "show" => false),
    "yAxis"  => Dict("type" => "value", "min" => -1, "max" => 1),
    "series" => [Dict("type" => "line", "data" => ys, "smooth" => true, "showSymbol" => false)],
))

#%% md id=dynamic_md
## Dynamic range — a widget argument that's *computed*

The static parser could never do this: the second slider's **range depends on the
first**. Drag **`hi`** and watch **`k`**'s maximum grow. `k` keeps its value when it
still fits the new range, and clamps when it doesn't.

#%% code id=hi
@bind hi Slider(5:5:100)

#%% code id=k
@bind k Slider(1:hi)

#%% code id=kshow
"k = $k   (it now runs 1 … $(hi))"

#%% md id=mixed_md
## Mixed cell — `@bind` *and* code together

One cell can both declare a control and use it. `amp` becomes a live slider; the rest
of the cell runs as normal Julia.

#%% code id=mixed
@bind nums Slider(1:10)
@bind range Slider(1:1:5)
@bind exponentiate Toggle(;label="On")
scaled = begin
  if exponentiate
    nums .^ collect(1:range)
  else
    nums .* collect(1:range)
  end
end
scaled

#%% code id=new_chart
echart(Dict(
    "title"  => Dict("text" => "Numbers Scaled"),
    "xAxis"  => Dict("type" => "category", "data" => nums), "show" => false),
    "yAxis"  => Dict("type" => "value", "min" => -1, "max" => 100),
    "series" => [Dict("type" => "line", "data" => scaled, "smooth" => true, "showSymbol" => false)],
))

#%% md id=gallery_md
## Every widget

One of each control type in a single group cell. The markdown below reads them all
via `{{ … }}` interpolation, so the live values update as you change the controls.

#%% code id=gallery
@bind sld Slider(0:100)
@bind num NumberField(0, 10, 3)
@bind chk Checkbox(true)
@bind tog Toggle(false; label = "enabled")
@bind txt TextField("hello")
@bind area TextArea("multi\nline")
@bind sel Select(["red", "green", "blue"])
@bind rad Radio(["S", "M", "L"], "M")
@bind multi MultiSelect(["x", "y", "z"], ["x"])
@bind col ColorPicker("#3aa0ff")
@bind day DateField("2026-06-05")
@bind tm TimeField("09:30")
@bind go Button("Run")

#%% md id=gallery_show
**Live values** — change anything above and watch these update:

| widget | value |
|---|---|
| Slider `sld` | {{ sld }} |
| NumberField `num` | {{ num }} |
| Checkbox `chk` | {{ chk }} |
| Toggle `tog` | {{ tog }} |
| TextField `txt` | {{ txt }} |
| TextArea `area` | {{ repr(area) }} |
| Select `sel` | {{ sel }} |
| Radio `rad` | {{ rad }} |
| MultiSelect `multi` | {{ join(multi, ", ") }} |
| ColorPicker `col` | {{ col }} |
| DateField `day` | {{ day }} |
| TimeField `tm` | {{ tm }} |
| Button `go` (clicks) | {{ go }} |

#%% md id=dynopts_md
## Dynamic options

A widget whose **option list is computed**: `pick`'s choices depend on `group`. Switch
`group` and the dropdown rebuilds (the value resets if it's no longer an option).

#%% code id=dynopts
using OrderedCollections
fruits = ["apple", "banana", "cherry"]
cols = ["red", "green", "blue"]
name_list = ["Joe", "Jill", "Sam"]
choice_dict = OrderedDict("fruit" => fruits, "color" => cols, "name" => name_list)
@bind group Radio(keys(choice_dict), first(keys(choice_dict)))
@bind pick Select(choice_dict[group])

#%% md id=dynopts_show
You picked **{{ pick }}** from the *{{ group }}* list.
