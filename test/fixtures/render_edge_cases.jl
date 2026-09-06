try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro title
@md"""
# Render-path edge cases

A deliberately small notebook that touches every path the render fast-path can get wrong:
per-cell memoisation (`MemoCell`), structural sharing across state pushes (`applyState`),
coalesced control syncing, and the editor-mount rules for app and workbook postures.

Small on purpose — the point is coverage of KINDS of cell, not size. Serve it, drive it from
`slate.eval_js`, and assert that a change to one cell renders one cell.
"""

#%% code id=setup hidecode
# Hidden code, visible output — exercises the `hidecode` flag on the render path.
xs = collect(1:20)
"setup ok"

#%% code id=knobs
# Several controls in ONE cell (the recommended grouping) — the combined strip is rebuilt only
# when `bindKey` changes, so this is what catches a bind-identity regression.
@bind amp Slider(1:10; default = 3, label = "amplitude")
@bind caption TextField("wave"; label = "caption")
@bind smooth Checkbox(true; label = "smooth")

#%% code id=curve
# A chart that must animate IN PLACE on a bind change rather than being torn down: the chart
# identity guard (`_chartsUnchanged`) is what decides that.
ys = amp .* sin.(xs ./ 3)
echart(:line, xs, ys; title = "$caption · amp = $amp", smooth = smooth)

#%% code id=tbl
# A table re-renders only when `c.tables` changes identity — a separate guard from charts.
slate_table((x = xs, y = round.(amp .* sin.(xs ./ 3); digits = 3)))

#%% md id=interp
@md"""
Markdown that READS a control: amplitude is **{{ amp }}**, caption is *{{ caption }}*.

Interpolation puts prose in the reactive graph, so this cell re-renders on a knob change while
its neighbours must not.
"""

#%% code id=surfaced controls=amp
# The amplitude knob is SURFACED here, away from the cell that declared it. This is the case that
# forbids scoping the control sync to a cell's own subtree — the element lives in another cell.
"hosts the amplitude knob"

#%% code id=slow
# A cell slow enough to observe the `running` live-state without a race.
sleep(0.6)
"slow cell done"

#%% code id=boom
# A deliberate failure: the error block, the offending-line tint, and the app-mode plain-language
# banner all hang off this.
error("deliberate failure — exercises the error path")

#%% code id=folded collapsed
"folded cell — the collapsed flag is a render input"

#%% web id=widget
@web(html"""<div id="w">web cell</div>""",
     css"""#w { color: var(--accent); font-weight: 600; }""",
     js"""root.querySelector('#w').textContent = 'web cell ok';""")

#%% code id=ex_double workbook
# A workbook exercise: editable and runnable by a reader when served as a workbook, refused by
# the server otherwise.
function double(x)
    missing
end

#%% code id=try_double workbook
double(21)

#%% code id=chk_double
# NOT tagged: a reader must not be able to rewrite the check that grades them.
# `isequal`, not `==`: an unimplemented exercise returns `missing`, and `missing == 42` is
# `missing` — which throws in a boolean context and would report as a broken check rather than
# an unfinished one.
isequal(double(21), 42) ? "✓ correct" : "not yet — double(21) should be 42"

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = d1e50106-38c7-4fff-84bc-d0a9cf15c2b6
# ╚═╡
