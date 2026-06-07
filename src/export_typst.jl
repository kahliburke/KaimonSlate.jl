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

function _typst_preamble(title::AbstractString)
    pre = _typ_str(strip(replace(_MITEX_SHIMS, r"\s+" => " ")))
    return """
    #import "@preview/cmarker:$(_CMARKER_VER)"
    #import "@preview/mitex:$(_MITEX_VER)": mitex, mi
    #set document(title: "$(_typ_str(title))")
    #set page(paper: "a4", margin: (x: 2.2cm, y: 2.4cm), numbering: "1")
    #set text(font: "New Computer Modern", size: 10.5pt)
    #set par(justify: true)
    #show heading: set block(above: 1.1em, below: 0.6em)
    #let PRE = "$pre "
    #let mathfn = (s, block: false) => if block { mitex(PRE + s) } else { mi(PRE + s) }
    #let titleblock(t) = { align(center, text(size: 19pt, weight: "bold", t)); v(2pt); line(length: 100%, stroke: 0.5pt + luma(180)); v(10pt) }
    #let codeblock(s) = block(width: 100%, fill: luma(248), inset: 8pt, radius: 4pt, raw(block: true, lang: "julia", s))
    #let outblock(s) = block(width: 100%, inset: 7pt, fill: luma(250), radius: 3pt, text(size: 8.5pt, raw(s)))
    #let valblock(s) = block(width: 100%, inset: 7pt, fill: rgb("#f0f7f1"), radius: 3pt, text(size: 8.5pt, fill: rgb("#177245"), raw(s)))
    #let errblock(s) = block(width: 100%, inset: 7pt, fill: rgb("#fdeeee"), radius: 3pt, text(size: 8.5pt, fill: rgb("#b00020"), raw(s)))
    #let figureimg(p) = align(center, image(p, width: 85%))

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
function _typst_table(spec)::String
    cols = get(spec, "columns", Any[])
    rows = get(spec, "rows", Any[])
    isempty(cols) && return ""
    name(c) = c isa AbstractDict ? string(get(c, "name", "")) : string(c)
    cell(v, sz) = "[#text(size: $(sz)pt, \"" * _typ_str(v === nothing ? "" : string(v)) * "\")]"
    io = IOBuffer()
    print(io, "#table(columns: ", length(cols), ", inset: 5pt, align: left, stroke: 0.4pt + luma(200),\n")
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

# Emit a code cell's outputs (value / stdout / error / figure / tables) into the doc.
function _emit_output!(io::IO, dir::AbstractString, base::AbstractString, nb::LiveNotebook, c::Cell)
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
    img = cell_image(nb, c.id)                       # server CairoMakie PNG, else ECharts snapshot
    if img !== nothing
        write(joinpath(dir, base * ".png"), img)
        print(io, "#figureimg(\"", base, ".png\")\n")
    end
    for spec in _table_specs(c)
        print(io, _typst_table(spec))
    end
    return
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
    export_pdf(nb; include_source=true) -> Vector{UInt8}

Render the notebook to a publication-quality PDF via Typst and return the bytes.
"""
function export_pdf(nb::LiveNotebook; include_source::Bool = true)
    lock(nb.lock) do
        dir = mktempdir()
        io = IOBuffer()
        print(io, _typst_preamble(nb.report.title))
        print(io, "#titleblock(\"", _typ_str(nb.report.title), "\")\n\n")
        for (k, c) in enumerate(nb.report.cells)
            base = "c$(k)"
            if c.kind == MARKDOWN
                write(joinpath(dir, base * ".md"), _md_for_typst(c))
                print(io, "#cmarker.render(read(\"", base, ".md\"), math: mathfn)\n\n")
            else
                if include_source && !isempty(strip(c.source))
                    write(joinpath(dir, base * ".jl"), c.source)
                    print(io, "#codeblock(read(\"", base, ".jl\"))\n")
                end
                _emit_output!(io, dir, base, nb, c)
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
