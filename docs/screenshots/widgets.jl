#%% md id=intro
# Widgets — `@bind name Widget(…)`

Declare a control in a cell; the bound name holds its live value, and any cell that
*reads* it recomputes when the control changes.

#%% code id=slider
@bind n Slider(0:100; default = 42, label = "samples")

#%% code id=numberfield
@bind count NumberField(0, 100, 12; label = "count")

#%% code id=checkbox
@bind agree Checkbox(true; label = "I agree")

#%% code id=toggle
@bind live Toggle(true; label = "stream", on = "Live", off = "Paused")

#%% code id=textfield
@bind who TextField("Ada"; label = "name")

#%% code id=textarea
@bind notes TextArea("multi\nline\nnotes"; label = "notes")

#%% code id=select
@bind color Select(["red", "green", "blue"]; default = "green", label = "color")

#%% code id=radio
@bind size Radio(["S", "M", "L"], "M"; label = "size")

#%% code id=multiselect
@bind tags MultiSelect(["x", "y", "z"], ["x", "z"]; label = "tags")

#%% code id=multicheckbox
@bind flags MultiCheckBox(["a", "b", "c"], ["b"]; label = "flags")

#%% code id=colorpicker
@bind tint ColorPicker("#56d364"; label = "tint")

#%% code id=datefield
@bind day DateField("2026-06-05"; label = "date")

#%% code id=timefield
@bind at TimeField("09:30"; label = "time")

#%% code id=button
@bind go Button("Run")
