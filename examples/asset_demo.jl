#%% md id=intro
# 📎 `@asset` — external files, tracked

`@asset "path"` reads a file (resolved relative to the notebook's **project directory**, or an
absolute path) and returns its contents. Because the path is a source *literal*, Slate records
it as a dependency of this cell **without running it** — so editing the file invalidates the
cell's durable memo (and, once the live-watcher lands, will re-run the cell automatically).

Use it to keep custom HTML/CSS/JS in real, editable files instead of pasting them inline:

- `@asset "assets/style.css"` → the file as a `String`
- `@asset bytes "assets/logo.png"` → `Vector{UInt8}`
- `readfile(path)` → the runtime form for a *computed* path (not statically tracked)

#%% code id=show
# Reads a sibling file and shows it. Edit examples/assets/hello.js, re-run this cell, and the
# change flows into the output — no manual copy/paste, and the memo won't serve a stale version.
struct HTMLDoc
    s::String
end
Base.show(io::IO, ::MIME"text/html", h::HTMLDoc) = print(io, h.s)

js = @asset "assets/hello.js"
HTMLDoc(string("<p>Inlined from <code>assets/hello.js</code>:</p><pre>", js, "</pre>",
               "<script>", js, "</script>"))
