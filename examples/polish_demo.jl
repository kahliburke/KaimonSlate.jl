#%% md id=intro
# 🧪 1.0 polish — fixes & enhancements

A notebook that exercises recent quality fixes. Each section says what to look for.
(Open with an up-to-date Slate — several of these are server-side.)

#%% md id=h_multidef
## 1 · Multiply-defined global → ⚠ warning

`shared` is defined in **two** code cells below. Both cells' toolbars now show a **⚠ shared**
chip: one warm namespace, last definition wins — so editing one can look like dead reactivity.
(This is exactly the footgun behind the helium `gram_schmidt` confusion.)

#%% code id=dup1
shared = 1
"first definition of `shared`"

#%% code id=dup2
shared = 2
"second definition — both cells flag ⚠ shared"

#%% md id=h_echarts
## 2 · ECharts DSL — clear errors on bad input

Bad inputs now raise a clear `ArgumentError` instead of a deep `DimensionMismatch` /
`BoundsError` / a silently-empty chart. Each line below is caught and its message shown.

#%% code id=echarts_err
cases = ["mismatched x/y"      => () -> echart(:line, [1, 2, 3], [10, 20]),
         "pie length mismatch" => () -> echart(:pie, ["a", "b"], [1]),
         "empty boxplot"       => () -> echart(:boxplot, ["a"], [Float64[]]),
         "heatmap not a matrix" => () -> echart(:heatmap, [1, 2, 3])]
[name => (try; f(); "(no error!)"; catch e; sprint(showerror, e); end) for (name, f) in cases]

#%% code id=echarts_ok
echart(:line, ["Mon", "Tue", "Wed", "Thu"], [3, 7, 4, 9]; title = "valid line still works")

#%% md id=h_slider
## 3 · Float64 slider keeps floats

A `Slider` over a float range no longer truncates its value to `Int`. Drag it and watch the
type below stay `Float64`.

#%% code id=fslider
@bind frac Slider(0.0:0.05:1.0; label = "frac")

#%% code id=fshow controls=frac
(value = frac, type = typeof(frac))      # type should be Float64, value not rounded to 0/1

#%% md id=h_progress
## 4 · Progress — bar + message on the cell

`slate_progress(frac; msg)` (and `@progress`/`@withprogress`) drive a bar **on the running
cell** and the floating run chip (which is clickable → jumps to the cell). Run this and watch.

#%% code id=prog
for i in 1:25
    slate_progress(i / 25; msg = "crunching $i / 25")
    sleep(0.08)
end
"done — progress"

#%% md id=h_play
## 5 · Play button always re-evaluates

Click ▶ on the cell below repeatedly — `rand()` changes every click (no need to edit it).
Shift-Enter on a clean cell, by contrast, won't re-run it.

#%% code id=playme
round(rand(); digits = 4)
