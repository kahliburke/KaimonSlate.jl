# ── Publication-quality PDF export (Typst) ───────────────────────────────────
# Assemble the notebook into a Typst document and compile it to PDF. Markdown cells
# render through the `cmarker` package with math routed to `mitex` (LaTeX math); a small
# `\newcommand` shim preamble covers common commands mitex doesn't know natively. Code is
# shown as syntax-highlighted listings; outputs (value/stdout/error/figures/tables) are
# typeset; controls are omitted (a PDF is a snapshot). Figures use the bytes we already
# have (server CairoMakie PNG or the client ECharts snapshot); a later pass upgrades these
# to vector/high-res via a browser handoff.
#
# Pinned package versions (fetched from the Typst registry on first compile, then cached).
const _CMARKER_VER = "0.1.6"
const _MITEX_VER = "0.2.5"

# LaTeX macro shims for commands mitex lacks. mitex honors parameterized \newcommand, so
# these inject cheaply ahead of every equation. Grow as needed.
const _MITEX_SHIMS = raw"""
\newcommand{\argmax}{\operatorname*{arg\,max}}
\newcommand{\argmin}{\operatorname*{arg\,min}}
\newcommand{\mathscr}[1]{\mathcal{#1}}
\newcommand{\dv}[2]{\frac{d#1}{d#2}}
\newcommand{\pdv}[2]{\frac{\partial #1}{\partial #2}}
\newcommand{\abs}[1]{\left|#1\right|}
\newcommand{\norm}[1]{\left\|#1\right\|}
"""

# Escape a Julia string for a Typst double-quoted string literal (\ and " only; Typst
# strings interpret \\, \", \n, … so backslashes MUST be doubled).
_typ_str(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"")

# Built-in style presets. `article` is the default single-column research-note look;
# `report` is roomier with a larger title. `columns` (1 or 2) lays the body out in one
# or two columns — figures/code span the full width so they never overflow a column.
const _STYLES = Dict(
    "article" => (textsize = "10.5pt", margin = "(x: 2.2cm, y: 2.4cm)", titlesize = "19pt"),
    "report"  => (textsize = "11pt",   margin = "(x: 2.6cm, y: 2.8cm)", titlesize = "23pt"),
)

# Colour palettes per theme. `light` is the publication default; `dark` matches the live
# notebook UI (dark page, light text) — a natural fit for figures drawn with the Makie
# dark theme. Each field is a Typst colour expression (string).
const _PALETTES = Dict(
    "light" => (page = "white",          text = "black",            rule = "luma(180)",
                title = "black",         codebg = "luma(248)",      codetheme = "",
                outbg = "luma(250)",     outfg = "rgb(\"#444444\")",
                valbg = "rgb(\"#f0f7f1\")", valfg = "rgb(\"#177245\")",
                errbg = "rgb(\"#fdeeee\")", errfg = "rgb(\"#b00020\")",
                parbg = "rgb(\"#eef2fb\")", parborder = "rgb(\"#c3d0ec\")", parlabel = "rgb(\"#3a4a72\")",
                tablestroke = "luma(200)", tableheadbg = "luma(244)"),
    "dark"  => (page = "rgb(\"#12141c\")", text = "rgb(\"#d6dae8\")",  rule = "luma(90)",
                title = "white",         codebg = "rgb(\"#1b1f2b\")", codetheme = "code-dark.tmTheme",
                outbg = "rgb(\"#181c26\")", outfg = "rgb(\"#aeb6cc\")",
                valbg = "rgb(\"#142318\")", valfg = "rgb(\"#5fcf6e\")",
                errbg = "rgb(\"#2a1619\")", errfg = "rgb(\"#f08a8a\")",
                parbg = "rgb(\"#1a2233\")", parborder = "rgb(\"#2c3a57\")", parlabel = "rgb(\"#8ab4f8\")",
                tablestroke = "luma(90)",  tableheadbg = "rgb(\"#1b1f2b\")"),
)
_palette(theme) = get(_PALETTES, theme, _PALETTES["light"])

# A compact Tokyo-Night-style dark syntax theme for Typst `raw` (written to the export
# dir when `theme=dark`; its background matches `codebg` so the block reads uniformly).
const _CODE_DARK_TMTHEME = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>name</key><string>SlateDark</string>
<key>settings</key><array>
<dict><key>settings</key><dict><key>background</key><string>#1b1f2b</string><key>foreground</key><string>#d6dae8</string></dict></dict>
<dict><key>scope</key><string>comment</string><key>settings</key><dict><key>foreground</key><string>#6a7080</string></dict></dict>
<dict><key>scope</key><string>string</string><key>settings</key><dict><key>foreground</key><string>#9ece6a</string></dict></dict>
<dict><key>scope</key><string>constant.numeric, constant.language</string><key>settings</key><dict><key>foreground</key><string>#ff9e64</string></dict></dict>
<dict><key>scope</key><string>keyword, storage, keyword.operator</string><key>settings</key><dict><key>foreground</key><string>#bb9af7</string></dict></dict>
<dict><key>scope</key><string>entity.name.function, support.function</string><key>settings</key><dict><key>foreground</key><string>#7aa2f7</string></dict></dict>
<dict><key>scope</key><string>entity.name.type, support.type</string><key>settings</key><dict><key>foreground</key><string>#2ac3de</string></dict></dict>
</array></dict></plist>
"""

# Code-listing font sizes (the `code` option, minus "hidden" which suppresses source).
const _CODE_SIZES = Dict("normal" => "9.5pt", "small" => "8.5pt", "smaller" => "7.5pt", "tiny" => "6.5pt")
_code_size(code) = get(_CODE_SIZES, code, _CODE_SIZES["normal"])

function _typst_preamble(title::AbstractString; style::AbstractString = "article",
                         columns::Int = 1, theme::AbstractString = "light",
                         code::AbstractString = "normal")
    pre = _typ_str(strip(replace(_MITEX_SHIMS, r"\s+" => " ")))
    st = get(_STYLES, style, _STYLES["article"])
    p = _palette(theme)
    csize = _code_size(code)
    cols = clamp(columns, 1, 2)
    pageopts = "paper: \"a4\", margin: $(st.margin), numbering: \"1\", fill: $(p.page)" * (cols == 2 ? ", columns: 2" : "")
    rawtheme = isempty(p.codetheme) ? "" : "\n    #set raw(theme: \"$(p.codetheme)\")"
    return """
    #import "@preview/cmarker:$(_CMARKER_VER)"
    #import "@preview/mitex:$(_MITEX_VER)": mitex, mi
    #set document(title: "$(_typ_str(title))")
    #set page($pageopts)
    #set text(font: "New Computer Modern", size: $(st.textsize), fill: $(p.text))$(rawtheme)
    #set par(justify: true)
    #show heading: set block(above: 1.1em, below: 0.6em)
    #show heading: set text(fill: $(p.title))
    #let PRE = "$pre "
    #let mathfn = (s, block: false) => if block { mitex(PRE + s) } else { mi(PRE + s) }
    #let titleblock(t) = { align(center, text(size: $(st.titlesize), weight: "bold", fill: $(p.title), t)); v(2pt); line(length: 100%, stroke: 0.5pt + $(p.rule)); v(10pt) }
    #let codeblock(s) = block(width: 100%, fill: $(p.codebg), inset: 8pt, radius: 4pt, text(size: $(csize), raw(block: true, lang: "julia", s)))
    #let outblock(s) = block(width: 100%, inset: 7pt, fill: $(p.outbg), radius: 3pt, text(size: 8.5pt, fill: $(p.outfg), raw(s)))
    #let valblock(s) = block(width: 100%, inset: 7pt, fill: $(p.valbg), radius: 3pt, text(size: 8.5pt, fill: $(p.valfg), raw(s)))
    #let errblock(s) = block(width: 100%, inset: 7pt, fill: $(p.errbg), radius: 3pt, text(size: 8.5pt, fill: $(p.errfg), raw(s)))
    #let figureimg(p) = align(center, image(p, width: 85%))
    #let paramblock(items) = block(width: 100%, inset: (x: 8pt, y: 5pt), fill: $(p.parbg), radius: 3pt, stroke: 0.5pt + $(p.parborder),
      text(size: 8.5pt)[#text(fill: $(p.parlabel), weight: "bold")[parameters] #h(6pt) #items.map(it => [#raw(it.at(0)) = #text(weight: "bold", it.at(1))]).join([#h(10pt)])])

    """
end

# Markdown source with `{{ expr }}` interpolations resolved to their scalar values (the
# only interp kind embeddable as text in v1; charts/tables-in-markdown are dropped).
function _md_for_typst(c::Cell)
    tmpl, exprs = ReportEngine._md_template(c.source)
    s = tmpl
    for i in 1:length(exprs)
        o = i <= length(c.interp) ? c.interp[i] : nothing
        val = (o === nothing || o.exception !== nothing || isempty(o.value_repr)) ? "" : o.value_repr
        s = replace(s, ReportEngine._interp_token(i) => val)
    end
    return s
end

# A static Typst table from a wire table spec (Dict with "columns"/"rows"). Capped.
# Cell/header text inherits the document text colour, so it follows the theme; only the
# rule colour and header fill are themed explicitly via the palette.
function _typst_table(spec; theme::AbstractString = "light")::String
    cols = get(spec, "columns", Any[])
    rows = get(spec, "rows", Any[])
    isempty(cols) && return ""
    p = _palette(theme)
    name(c) = c isa AbstractDict ? string(get(c, "name", "")) : string(c)
    cell(v, sz) = "[#text(size: $(sz)pt, \"" * _typ_str(v === nothing ? "" : string(v)) * "\")]"
    io = IOBuffer()
    print(io, "#table(columns: ", length(cols), ", inset: 5pt, align: left, stroke: 0.4pt + $(p.tablestroke),\n")
    print(io, "  fill: (_, row) => if row == 0 { $(p.tableheadbg) },\n")
    print(io, "  table.header(", join(["[#text(size: 8.5pt, weight: \"bold\", \"" * _typ_str(name(c)) * "\")]" for c in cols], ", "), "),\n")
    maxr = 60
    for (ri, r) in enumerate(rows)
        ri > maxr && break
        print(io, "  ", join([cell(v, 8) for v in r], ", "), ",\n")
    end
    print(io, ")\n")
    length(rows) > maxr && print(io, "#text(size: 8pt, fill: gray)[… ", length(rows) - maxr, " more rows]\n")
    return String(take!(io))
end

# Resolve the best figure representation for publication export: prefer VECTOR (the
# `application/pdf` chunk a CairoMakie figure carries — fonts embedded, crisp at any
# scale — then a captured SVG), and only fall back to raster PNG. Client-rendered
# charts (ECharts) come through the snapshot store: the browser's SVG snapshot if it
# supplied one, else its PNG. Returns `(bytes, ext)` with `ext ∈ ("pdf","svg","png")`,
# or `nothing` when the cell has no figure.
function _figure_for_export(nb::LiveNotebook, c::Cell; dark::Bool = false)
    o = c.output
    if o !== nothing
        for (mime, ext) in (("application/pdf", "pdf"), ("image/svg+xml", "svg"), ("image/png", "png"))
            for ch in o.display
                ch.mime == mime && return (copy(ch.data), ext)
            end
        end
    end
    svg = _snapshot_svg(nb.id, c.id; dark = dark)    # theme-matched vector chart, if the browser supplied one
    svg !== nothing && return (Vector{UInt8}(codeunits(svg)), "svg")
    png = _snapshot(nb.id, c.id)
    png !== nothing && return (copy(png), "png")
    return nothing
end

# Emit a code cell's outputs (value / stdout / error / figure / tables) into the doc.
function _emit_output!(io::IO, dir::AbstractString, base::AbstractString, nb::LiveNotebook, c::Cell;
                       theme::AbstractString = "light")
    o = c.output
    o === nothing && return
    if o.exception !== nothing
        write(joinpath(dir, base * ".err"), rstrip(o.exception))
        print(io, "#errblock(read(\"", base, ".err\"))\n")
        return
    end
    if !isempty(strip(o.stdout))
        write(joinpath(dir, base * ".out"), rstrip(o.stdout))
        print(io, "#outblock(read(\"", base, ".out\"))\n")
    end
    if isempty(o.display) && !isempty(o.value_repr)
        write(joinpath(dir, base * ".val"), o.value_repr)
        print(io, "#valblock(read(\"", base, ".val\"))\n")
    end
    fig = _figure_for_export(nb, c; dark = theme == "dark")   # vector (pdf/svg) preferred, else raster png
    if fig !== nothing
        data, ext = fig
        write(joinpath(dir, base * "." * ext), data)
        print(io, "#figureimg(\"", base, ".", ext, "\")\n")
    end
    for spec in _table_specs(c)
        print(io, _typst_table(spec; theme = theme))
    end
    return
end

# A frozen snapshot of a cell's `@bind` controls: a PDF is static, so interactive
# widgets are typeset as a compact "parameter" strip showing each control at its
# current value (what the reader is looking at). Empty string when the cell has none.
function _emit_controls(c::Cell)::String
    isempty(c.binds) && return ""
    item(b) = "(" * "\"" * _typ_str(string(b.name)) * "\", \"" *
              _typ_str(_bind_value_repr(b.value)) * "\")"
    return "#paramblock((" * join((item(b) for b in c.binds), ", ") *
           (length(c.binds) == 1 ? ",))\n" : "))\n")
end

# Render a control's current value for the parameter strip (concise, no type noise).
function _bind_value_repr(v)::String
    v isa AbstractFloat && return string(round(v; sigdigits = 6))
    v isa AbstractString && return String(v)
    return string(v)
end

# Compile a .typ to PDF, preferring a system `typst`, else the bundled Typst_jll. `--root`
# is the temp dir so read()/image() of the per-cell aux files resolve (Typst sandboxes IO).
function _typst_compile(typ::String, pdf::String)
    root = dirname(typ)
    sys = Sys.which("typst")
    if sys !== nothing
        run(`$sys compile --root $root $typ $pdf`)
        return
    end
    Typst_jll.typst() do exe
        run(`$exe compile --root $root $typ $pdf`)
    end
    return
end

"""
    export_pdf(nb; include_source=true, style="article", columns=1, theme="light", code="normal")
        -> Vector{UInt8}

Render the notebook to a publication-quality PDF via Typst and return the bytes.
`style ∈ ("article", "report")` picks a layout preset; `columns ∈ (1, 2)` lays the body
out single- or two-column; `theme ∈ ("light", "dark")` sets the colour scheme (dark
matches the live UI and Makie-dark figures). `code ∈ ("normal","small","smaller","tiny")`
sets the code-listing font size, or `"hidden"` to omit source entirely (also honoured via
`include_source`). Figures use vector data when available (CairoMakie PDF, ECharts SVG);
`@bind` controls are frozen to their current values as a parameter strip.
"""
function export_pdf(nb::LiveNotebook; include_source::Bool = true,
                    style::AbstractString = "article", columns::Integer = 1,
                    theme::AbstractString = "light", code::AbstractString = "normal")
    show_source = include_source && code != "hidden"
    lock(nb.lock) do
        dir = mktempdir()
        # Dark theme highlights code via a bundled tmTheme that Typst reads from the root.
        theme == "dark" && write(joinpath(dir, "code-dark.tmTheme"), _CODE_DARK_TMTHEME)
        io = IOBuffer()
        print(io, _typst_preamble(nb.report.title; style = style, columns = Int(columns),
                                  theme = theme, code = code))
        print(io, "#titleblock(\"", _typ_str(nb.report.title), "\")\n\n")
        for (k, c) in enumerate(nb.report.cells)
            base = "c$(k)"
            if c.kind == MARKDOWN
                write(joinpath(dir, base * ".md"), _md_for_typst(c))
                print(io, "#cmarker.render(read(\"", base, ".md\"), math: mathfn)\n\n")
            else
                if show_source && !isempty(strip(c.source))
                    write(joinpath(dir, base * ".jl"), c.source)
                    print(io, "#codeblock(read(\"", base, ".jl\"))\n")
                end
                print(io, _emit_controls(c))         # frozen @bind controls (static snapshot)
                _emit_output!(io, dir, base, nb, c; theme = theme)
                print(io, "\n")
            end
        end
        typ = joinpath(dir, "doc.typ")
        write(typ, String(take!(io)))
        pdf = joinpath(dir, "out.pdf")
        _typst_compile(typ, pdf)
        return read(pdf)
    end
end
