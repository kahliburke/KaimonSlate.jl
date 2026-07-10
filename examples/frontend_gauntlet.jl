#%% md id=title title
# Front-end Gauntlet — assets, watchers, WebPage, import maps

*A QA notebook for the tracked-asset pipeline: `@asset` reads, the file-watcher re-run,
`WebPage` composition, and `@use` browser modules. Edit `fg_assets/app.html` on disk and
the card below must re-render on its own.*

#%% code id=css_len
## A tracked read — editing app.css must re-run this cell (and the page below).
css = @asset "fg_assets/app.css"
"css: $(length(css)) bytes"

#%% code id=page
## Self-contained page from tracked pieces; its <script> runs live AND in exports.
@use "canvas-confetti" => "https://esm.sh/canvas-confetti@1"
WebPage(css = @asset("fg_assets/app.css"),
        html = @asset("fg_assets/app.html"),
        js = @asset("fg_assets/app.js"))

#%% code id=computed_read
## The untracked escape hatch — readfile with a computed path (no watcher, no memo fold).
name = "app"
snippet = readfile("fg_assets/$name.html")
"readfile sees generation: $(match(r"fg-badge\">(\w+)<", snippet)[1])"
