# ── Front-end output ──────────────────────────────────────────────────────────
# The Julia side of "ship some HTML/CSS/JS to the page". Both render to a single `text/html`
# output via `Base.show`, so they work in the live notebook (the `<script>` is revived on load)
# AND in a static export/publish (self-contained — a static page runs `<script>` natively). An
# extension constructs these in its OWN module, so it needs this in the interface package.

"""
    WebPage(; html = "", css = "", js = "", obscure = false)

A self-contained HTML page composed from CSS/HTML/JS strings. Renders to one `text/html`
output — `<style>` + body + `<script>` — identical in the live notebook and a static export.
Empty sections are omitted. `obscure = true` base64-packs the JS behind a tiny decode-and-run
bootstrap (trivially reversible; the source files on disk stay plain).

Typically the pieces come from tracked files so they stay debuggable and re-run on edit — in a
Slate notebook via `@asset`, or in an extension package via `read(joinpath(pkgdir(@__MODULE__),
"assets", "app.js"), String)`.
"""
struct WebPage
    html::String
    css::String
    js::String
    obscure::Bool
end
WebPage(; html::AbstractString = "", css::AbstractString = "", js::AbstractString = "", obscure::Bool = false) =
    WebPage(String(html), String(css), String(js), obscure)

function Base.show(io::IO, ::MIME"text/html", w::WebPage)
    isempty(w.css) || print(io, "<style>", replace(w.css, "</style>" => "<\\/style>"), "</style>")
    print(io, w.html)
    if !isempty(w.js)
        if w.obscure
            # Decode the base64'd UTF-8 (atob → latin-1 bytes; TextDecoder reassembles multi-byte
            # chars) and run it. A plain `<script>` — revived live by the front end, native in a
            # static export.
            print(io, "<script>Function(new TextDecoder().decode(Uint8Array.from(atob('",
                  Base64.base64encode(w.js), "'),c=>c.charCodeAt(0))))()</script>")
        else
            print(io, "<script>", replace(w.js, "</script>" => "<\\/script>"), "</script>")
        end
    end
    return nothing
end

"""
    register_widget_js(kind, js) -> WebPage

A one-time front-end registration for a custom widget `kind`: wraps `js` (which should call
`window.slateRegisterWidget("<kind>", …)`) in a `WebPage` so returning it from a cell installs
the renderer. Put it in a cell above any `@bind` of that kind. This replaces the hand-rolled
`struct …; Base.show(MIME"text/html") … end` boilerplate an extension would otherwise write.

```julia
register_widget_js("mathfield", read(joinpath(pkgdir(@__MODULE__), "assets", "mathfield.js"), String))
```
"""
register_widget_js(kind::AbstractString, js::AbstractString) = WebPage(js = String(js))
