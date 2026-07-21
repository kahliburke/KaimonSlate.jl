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
    # A web cell renders like a code cell — its `@web(...)` evaluates to a `WebPage`, captured as an
    # HTML display chunk — so the same output pipeline (display/stdout/error) applies.
    (cell.kind == CODE || cell.kind == WEB) || return ""
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
        # The message is syntax-coloured (error type, `backticked` names, Suggestion line); the
        # backtrace is dimmed. The message (`errjump`) jumps to the error's ORIGIN — the deepest
        # in-notebook frame (closest to where it actually fired, possibly another cell); the
        # backtrace's `cell:<id>:N` frames (`cellref`) each jump to their own cell (errors.js).
        org = _error_origin(o)
        print(io, "<div class=\"err\"><pre>")
        if org === nothing
            print(io, _render_exc_html(o.exception))
        else
            cid, ln = org
            print(io, "<span class=\"err-msg errjump\"",
                  (isempty(cid) ? "" : " data-cid=\"" * cid * "\""), " data-line=\"", ln,
                  "\" title=\"jump to the error origin (line ", ln, isempty(cid) ? "" : " in cell " * cid, ")\">",
                  _render_exc_html(o.exception), "</span>")
        end
        (o.backtrace === nothing || isempty(o.backtrace)) ||
            print(io, "<span class=\"err-bt\">\n", _linkify_trace(o.backtrace), "</span>")
        print(io, "</pre></div>")
    end
    return String(take!(io))
end

# Colour an already-escaped line's `` `backticked` `` names (identifiers/types Julia quotes in its
# error text) — the backticks drop, the content gets the `err-id` accent.
_color_ticks(s::AbstractString) =
    replace(s, r"`[^`]*`" => m -> "<span class=\"err-id\">" * chop(m; head = 1, tail = 1) * "</span>")

# Render an exception message as coloured HTML: the leading error TYPE (`UndefVarError`, `MethodError`,
# …) is set apart, `Suggestion:` lines are dimmed, and quoted names are accented. Everything is escaped.
function _render_exc_html(exc::AbstractString)
    io = IOBuffer()
    for (i, raw) in enumerate(split(exc, '\n'))
        i > 1 && print(io, '\n')
        m = i == 1 ? match(r"^([A-Za-z_][A-Za-z0-9_]*)([:(].*)$", raw) : nothing
        if startswith(lstrip(raw), "Suggestion:")
            print(io, "<span class=\"err-suggest\">", _color_ticks(_esc(raw)), "</span>")
        elseif m !== nothing
            print(io, "<span class=\"err-type\">", _esc(m.captures[1]), "</span>", _color_ticks(_esc(m.captures[2])))
        else
            print(io, _color_ticks(_esc(raw)))
        end
    end
    return String(take!(io))
end

# The source line in THIS cell where an error occurred — used to tint + jump to the offending line.
# Frames now read `cell:<id>:N` (the eval `filename`), so we take the first frame belonging to THIS
# cell (`cellid`); if the error is purely inside another cell's code the call site here still names
# this cell. Falls back to any `cell:…:N` / legacy `string:N` when `cellid` is unknown. `nothing`
# when the error has no in-cell location (surfaced deep inside a package).
function _cell_error_line(o::CellOutput, cellid::AbstractString = "")
    for s in (o.backtrace, o.exception)
        s === nothing && continue
        for m in eachmatch(r"\bcell:([\w\-]+):(\d+)", s)
            (isempty(cellid) || m.captures[1] == cellid) && return parse(Int, m.captures[2])
        end
        m = match(r"\bstring:(\d+)", s)        # legacy / interpolation eval filename
        m === nothing || return parse(Int, m.captures[1])
    end
    return nothing
end

# Where the error actually fired, as close to the source as the notebook can show: the TOPMOST
# (innermost) `cell:<id>:N` frame — the deepest in-notebook location. For an error inside another
# cell's function that's the defining cell; for one that surfaced in package code it's the cell that
# called in (the nearest editable edge). Returns `(cellid, line)`, `("", line)` for a legacy
# `string:N` frame (no cell), or `nothing`. Used for the error-message jump target.
function _error_origin(o::CellOutput)
    for s in (o.backtrace, o.exception)
        s === nothing && continue
        m = match(r"\bcell:([\w\-]+):(\d+)", s)
        m === nothing || return (String(m.captures[1]), parse(Int, m.captures[2]))
        m = match(r"\bstring:(\d+)", s)
        m === nothing || return ("", parse(Int, m.captures[1]))
    end
    return nothing
end

# Make source locations in a backtrace clickable: `path.jl:line` → open in VS Code; `string:N`
# (our cell eval `filename`) → jump to that line IN THIS CELL (errors.js wires `.cellref`).
function _linkify_trace(bt::AbstractString)
    home = homedir()
    s = replace(_esc(bt), r"((?:~|/)[\w./ \-]*\.jl):(\d+)" => function (m)
        p = match(r"^(.*\.jl):(\d+)$", m)
        p === nothing && return m
        path, line = String(p.captures[1]), String(p.captures[2])
        ap = startswith(path, "~") ? home * path[2:end] : path
        isabspath(ap) && isfile(ap) || return m   # skip Base's relative ./foo.jl etc. — only real files
        "<a class=\"srcref\" href=\"vscode://file" * ap * ":" * line * "\" title=\"open in VS Code\">" * m * "</a>"
    end)
    # `cell:<id>:N` → jump to line N IN CELL <id> (cross-cell: the frame names its own source cell).
    s = replace(s, r"\bcell:([\w\-]+):(\d+)\b" => function (m)
        p = match(r"\bcell:([\w\-]+):(\d+)\b", m)
        cid, ln = String(p.captures[1]), String(p.captures[2])
        "<a class=\"cellref\" data-cid=\"" * cid * "\" data-line=\"" * ln *
            "\" title=\"jump to line " * ln * " in cell " * cid * "\">" * m * "</a>"
    end)
    # Legacy / interpolation `string:N` → jump to that line in THIS cell (no cell id in the frame).
    return replace(s, r"\bstring:(\d+)\b" => function (m)
        ln = String(match(r"\d+", m).match)
        "<a class=\"cellref\" data-line=\"" * ln * "\" title=\"jump to line " * ln * " in this cell\">" * m * "</a>"
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
# Pandoc-style heuristic: the content must not start/end with whitespace, so prose dollar
# amounts ("it cost $5 and $10") don't get swallowed as a math span (the candidate "5 and "
# would have to end right before the second $, but it ends in a space — rejected).
const _MATH_INLINE = r"\$(?!\s)([^\$\n]+?)(?<!\s)\$"
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
        elseif ch.mime == "application/vnd.kaimonslate.component+json"
            # A Slate component descriptor {v, component, props} (SlateExtensionsBase `slate_render`):
            # emit a mount placeholder carrying the raw descriptor in a sibling JSON script; the SPA looks
            # up the registered component and mounts it (props + a display ctx exposing call/stream, no
            # bind value). `<\/` keeps the JSON from closing the <script> early.
            desc = replace(String(copy(ch.data)), "</" => "<\\/")
            print(io, "<div class=\"disp slatecomp\"><span class=\"slatecomponent\"></span>",
                  "<script type=\"application/json\" class=\"slatecomponent-desc\">", desc, "</script></div>")
        elseif ch.mime == "application/vnd.kaimonslate.html+html"
            # A self-contained HTML fragment (the `slate_render` escape hatch) — trusted, injected as-is.
            print(io, "<div class=\"disp html\">", String(copy(ch.data)), "</div>")
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
