"""
    ReportRender

The **renderer** half of the engine/renderer split (§15.1): turns an evaluated
`Report` into a self-contained HTML artifact. Runs CLI-side, where the heavier
template deps already live (`OteraEngine`, `CommonMark`). It only consumes the
engine's `Report`/`Cell` data — no live module needed.

Escaping is correct by construction: one OteraEngine template with
`autoescape=true` HTML-escapes all code/stdout/value text automatically;
CommonMark-rendered markdown (already safe HTML) is injected via the `|> safe`
filter. No hand-escaping (§8).
"""
module ReportRender

using OteraEngine, CommonMark
using ..ReportEngine
import Base64

export render_html, render_report_file, output_html, markdown_html

const _TEMPLATE = joinpath(@__DIR__, "templates", "report.html.tmpl")

_esc(s) = replace(String(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

"Markdown source → HTML (for the live notebook + md cells)."
markdown_html(src::AbstractString) = _md_html(src)

"""
    output_html(cell) -> String

The output fragment for a code cell (stdout / value / rich display / error),
escaped and embedded. Used by the live notebook server to update a cell in place.
"""
function output_html(cell::Cell)
    cell.kind == CODE || return ""
    o = cell.output
    o === nothing && return ""
    io = IOBuffer()
    isempty(o.stdout) || print(io, "<div class=\"out\"><pre>", _esc(o.stdout), "</pre></div>")
    if isempty(o.display) && !isempty(o.value_repr)
        print(io, "<div class=\"val\"><pre>", _esc(o.value_repr), "</pre></div>")
    end
    isempty(o.display) || print(io, "<div class=\"dispwrap\">", _render_chunks(o.display), "</div>")
    o.exception === nothing || print(io, "<div class=\"err\"><pre>", _esc(o.exception), "</pre></div>")
    return String(take!(io))
end

# CommonMark parser with the table extension (GFM-style tables in narrative).
function _md_html(src::AbstractString)
    p = CommonMark.Parser()
    enable!(p, CommonMark.TableRule())
    return CommonMark.html(p(String(src)))
end

# Render captured MIME chunks to trusted HTML: images → base64 data-URI <img>,
# text/html injected as-is. (Returned via the template's `|> safe` filter.)
function _render_chunks(chunks)
    io = IOBuffer()
    for ch in chunks
        if ch.mime == "text/html"
            print(io, "<div class=\"disp html\">", String(ch.data), "</div>")
        elseif startswith(ch.mime, "image/")
            b64 = Base64.base64encode(ch.data)
            print(io, "<div class=\"disp img\"><img alt=\"output\" src=\"data:",
                  ch.mime, ";base64,", b64, "\"/></div>")
        end
    end
    return String(take!(io))
end

# A flat, uniform view of a cell for the template (every field always present so
# field access never errors). Markdown → pre-rendered HTML; code → raw text the
# template autoescapes; rich output → trusted HTML via `display`.
function _cell_view(cell::Cell)
    if cell.kind == MARKDOWN
        return (kind = "md", state = "", source = "", stdout = "", value = "",
                error = "", display = "", html = _md_html(cell.source))
    end
    o = cell.output
    chunks = o === nothing ? MimeChunk[] : o.display
    return (kind    = "code",
            state   = lowercase(string(cell.state)),
            source  = cell.source,
            stdout  = o === nothing ? "" : o.stdout,
            # suppress the text/plain value repr when richer output is present
            value   = (o === nothing || !isempty(chunks)) ? "" : o.value_repr,
            error   = (o === nothing || o.exception === nothing) ? "" : o.exception,
            display = _render_chunks(chunks),
            html    = "")
end

"""
    render_html(report) -> String

Render an (already-evaluated) `Report` to a self-contained HTML string.
"""
function render_html(report::Report)
    tmpl = Template(_TEMPLATE; config = Dict("autoescape" => true))
    cells = [_cell_view(c) for c in report.cells]
    title = isempty(report.title) ? report.id : report.title
    return tmpl(init = Dict(:title => title, :cells => cells))
end

"""
    render_report_file(path; out=..., title="", reset=false) -> out_path

End-to-end convenience: read a hybrid `.jl`, parse → evaluate → render → write
HTML. Returns the output path.
"""
function render_report_file(path::AbstractString;
                            out::AbstractString = replace(path, r"\.jl$" => "") * ".html",
                            title::AbstractString = "",
                            reset::Bool = false)
    src = read(path, String)
    id = replace(splitext(basename(path))[1], r"[^A-Za-z0-9]" => "_")
    report = parse_report(src; id = id, title = title)
    eval_report!(report; reset = reset)
    write(out, render_html(report))
    return out
end

end # module ReportRender
