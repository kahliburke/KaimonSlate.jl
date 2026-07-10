#%% md id=intro
# Manual edges — `needs=`

`store` writes a temp file; `reader` reads it back. **No variable connects
them**, so dataflow analysis alone sees two unrelated cells: edits to `store`
would never re-run `reader`, and a parallel drain could run them in any order.

The `needs=store` tag on `reader` asserts the edge. Open the 🕸 DAG pane: it's
the **dashed** one. Hit 🔗 (link mode), then click two cells to draw another —
or click a dashed edge to remove it.

#%% code id=store
open(joinpath(tempdir(), "slate_needs_demo.txt"), "w") do io
    write(io, string(rand(1:10^6)))
end
"stored a fresh token"

#%% code id=reader needs=store
token = read(joinpath(tempdir(), "slate_needs_demo.txt"), String)

#%% md id=check
Re-run `store` (or just edit it — add a space): `reader` goes stale and picks
up the new token. Remove the tag and it stops following.

#%% code id=unlinked needs=reader
# control: same file read but NO tag — this one does NOT follow `store`
stale_view = read(joinpath(tempdir(), "slate_needs_demo.txt"), String)
