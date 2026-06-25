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

"""
Markdown source → HTML (live notebook + md cells). `interps` are the captured
outputs of the cell's `{{ expr }}` blocks, spliced in document order.
"""
markdown_html(src::AbstractString) = _md_html(src, CellOutput[])
markdown_html(src::AbstractString, interps) = _md_html(src, interps)

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
    # Captured stderr / `@warn` output — a distinct warnings block (not an error: the cell may
    # still have succeeded). VS Code source links in any `@ file:line` notices are made clickable.
    isempty(o.stderr) || print(io, "<div class=\"warn\"><pre>", _linkify_trace(o.stderr), "</pre></div>")
    if isempty(o.display) && !isempty(o.value_repr)
        print(io, "<div class=\"val\"><pre>", _esc(o.value_repr), "</pre></div>")
    end
    isempty(o.display) || print(io, "<div class=\"dispwrap\">", _render_chunks(o.display), "</div>")
    if o.exception !== nothing
        el = _cell_error_line(o)
        # `errjumpable` + `data-errline` let the browser tint the offending line in the editor and
        # scroll/flash to it on click (errors.js). `el` is the cell's own source line (a `string:N`).
        print(io, el === nothing ? "<div class=\"err\">" : "<div class=\"err errjumpable\" data-errline=\"$(el)\">")
        print(io, "<pre>", _esc(o.exception))
        (o.backtrace === nothing || isempty(o.backtrace)) || print(io, "\n", _linkify_trace(o.backtrace))
        print(io, "</pre>")
        el === nothing || print(io, "<div class=\"errjump\">↦ jump to line ", el, "</div>")
        print(io, "</div>")
    end
    return String(take!(io))
end

# The cell-relative source line an error occurred on — the first `string:N` (our eval `filename`)
# in the backtrace (top frame) or the exception text. `nothing` when the error has no in-cell
# location (e.g. it surfaced deep inside a package). Used to highlight + jump to the line.
function _cell_error_line(o::CellOutput)
    for s in (o.backtrace, o.exception)
        s === nothing && continue
        m = match(r"string:(\d+)", s)
        m === nothing || return parse(Int, m.captures[1])
    end
    return nothing
end

# Make `path.jl:line` references in a backtrace clickable → open in VS Code. Escapes the text,
# then wraps each source location in a `vscode://file/<abspath>:<line>` link (expanding `~`).
function _linkify_trace(bt::AbstractString)
    home = homedir()
    return replace(_esc(bt), r"((?:~|/)[\w./ \-]*\.jl):(\d+)" => function (m)
        p = match(r"^(.*\.jl):(\d+)$", m)
        p === nothing && return m
        path, line = String(p.captures[1]), String(p.captures[2])
        ap = startswith(path, "~") ? home * path[2:end] : path
        isabspath(ap) && isfile(ap) || return m   # skip Base's relative ./foo.jl etc. — only real files
        "<a class=\"srcref\" href=\"vscode://file" * ap * ":" * line * "\" title=\"open in VS Code\">" * m * "</a>"
    end)
end

# Markdown → HTML with the table extension (GFM tables) and LaTeX math.
#
# Math is handled OUTSIDE CommonMark: `$…$` / `$$…$$` spans are stashed behind
# plain-text placeholders before parsing and restored (HTML-escaped) afterward,
# then typeset client-side by KaTeX. CommonMark's own math rule mangles LaTeX (it
# eats backslash-escapes like `\,`), so we keep the TeX byte-for-byte and let the
# browser render it. Placeholders are bare alphanumerics so markdown leaves them
# untouched; the restored span keeps its `$`/`$$` delimiters for KaTeX.
const _MATH_DISPLAY = r"\$\$(.+?)\$\$"s
const _MATH_INLINE = r"\$([^\$\n]+?)\$"
_math_token(i::Int) = "xslatemathx" * string(i; pad = 5) * "x"

# A string value's text/plain repr is quoted (`"c"`), but inside `{{ }}` interpolation — a
# presentation context, like Julia's `$(…)` — we want the bare content (`c`). Strip one layer of
# surrounding double-quotes and undo the basic `show` escapes; non-string reprs (numbers, symbols,
# arrays) have no enclosing quotes and pass through untouched.
function _interp_scalar(s::AbstractString)
    (ncodeunits(s) >= 2 && startswith(s, '"') && endswith(s, '"')) || return s
    inner = s[nextind(s, firstindex(s)):prevind(s, lastindex(s))]
    return replace(inner, "\\\"" => "\"", "\\\$" => "\$", "\\\\" => "\\", "\\n" => "\n", "\\t" => "\t")
end

# Render markdown, splicing each `{{ expr }}` capture in. Self-contained outputs
# (image / HTML / LaTeX / scalar) embed directly; echarts & interactive tables
# emit a host placeholder (`.ichart`/`.itable` keyed by index) that the SPA
# hydrates from the cell's collected `echarts`/`tables` — same order as here.
function _md_html(src::AbstractString, interps = CellOutput[])
    tmpl, exprs = ReportEngine._md_template(src)
    frags = String[]; ec = 0; tc = 0
    for i in 1:length(exprs)
        o = i <= length(interps) ? interps[i] : nothing
        if o === nothing
            push!(frags, "")
        elseif o.exception !== nothing
            push!(frags, "<span class=\"interr\">⟨" * _esc(o.exception) * "⟩</span>")
        elseif !isempty(o.display)
            push!(frags, _render_chunks(o.display))
        elseif !isempty(o.echarts)
            push!(frags, "<div class=\"ichart\" data-i=\"$ec\"></div>"); ec += 1
        elseif !isempty(o.tables)
            push!(frags, "<div class=\"itable\" data-i=\"$tc\"></div>"); tc += 1
        elseif !isempty(o.value_repr)
            push!(frags, "<span class=\"ival\">" * _esc(_interp_scalar(o.value_repr)) * "</span>")
        else
            push!(frags, "")
        end
    end
    # math → placeholders (kept byte-for-byte for KaTeX).
    math = String[]
    stash(m) = (push!(math, String(m)); _math_token(length(math)))
    s = replace(tmpl, _MATH_DISPLAY => stash)   # $$…$$ first, so $…$ can't split it
    s = replace(s, _MATH_INLINE => stash)
    p = CommonMark.Parser()
    enable!(p, CommonMark.TableRule())
    html = CommonMark.html(p(s))
    for (i, m) in enumerate(math)
        tex = m
        for j in 1:length(exprs)                                    # interpolations inside math → raw TeX
            tok = ReportEngine._interp_token(j)
            occursin(tok, tex) && (tex = replace(tex, tok => _math_value(j <= length(interps) ? interps[j] : nothing)))
        end
        html = replace(html, _math_token(i) => _esc(tex))           # raw TeX, escaped; KaTeX reads the text node
    end
    for (i, f) in enumerate(frags)
        html = replace(html, ReportEngine._interp_token(i) => f)    # remaining (text) interps → HTML fragment
    end
    return html
end

# Raw text of an interpolation for *math* context (inside `$…$`/`$$…$$`): a scalar's
# value, or a text/latex chunk's TeX (delimiters stripped). KaTeX is already in math
# mode there, so we want bare TeX, not an HTML span.
function _math_value(o::Union{CellOutput,Nothing})
    o === nothing && return ""
    o.exception === nothing || return "?"
    isempty(o.value_repr) || return _interp_scalar(o.value_repr)
    for ch in o.display
        if ch.mime == "text/latex"
            t = strip(String(copy(ch.data)))
            startswith(t, "\$\$") && endswith(t, "\$\$") && length(t) >= 4 && return t[3:end-2]
            startswith(t, "\$") && endswith(t, "\$") && length(t) >= 2 && return t[2:end-1]
            return t
        end
    end
    return ""
end

# Render captured MIME chunks to trusted HTML: images → base64 data-URI <img>,
# text/html injected as-is. (Returned via the template's `|> safe` filter.)
#
# NOTE: read text bytes with `String(copy(ch.data))`, never `String(ch.data)` —
# the latter *steals* the byte vector (empties it), so a cell rendered twice (every
# `/state` poll) would come back blank on the second render. Images/base64encode
# read non-destructively, which is why only text/html + text/latex were affected.
function _render_chunks(chunks)
    io = IOBuffer()
    for ch in chunks
        if ch.mime == "text/html"
            print(io, "<div class=\"disp html\">", String(copy(ch.data)), "</div>")
        elseif ch.mime == "text/latex"
            # Emit the raw TeX (with its delimiters) inside a marked div; the SPA
            # typesets it in DISPLAY mode via KaTeX so block output matches markdown
            # `$$…$$` sizing. Bare TeX (no delimiters) is wrapped so it still renders.
            # HTML-escape so the browser hands KaTeX the raw text node verbatim.
            tex = String(copy(ch.data))
            wrapped = (occursin('$', tex) || occursin("\\(", tex) || occursin("\\[", tex)) ?
                      tex : "\\[" * tex * "\\]"
            print(io, "<div class=\"disp latex\">", _esc(wrapped), "</div>")
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
                error = "", display = "", html = _md_html(cell.source, cell.interp))
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
