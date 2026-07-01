# ── Publication-quality PDF export (Typst) ───────────────────────────────────
# Assemble the notebook into a Typst document and compile it to PDF. Markdown cells
# render through the `cmarker` package with math routed to `mitex` (LaTeX math); a small
# `\newcommand` shim preamble covers common commands mitex doesn't know natively. Code is
# shown as syntax-highlighted listings; outputs (value/stdout/error/figures/tables) are
# typeset; `@bind` controls are omitted by default — a PDF is a snapshot — but can be shown
# as a frozen parameter strip via `include_params`. Figures use the bytes we already
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
# Escape for a Typst "…" string literal. Must also escape newlines/tabs — a literal can't span a
# raw newline, so a multiline table cell / bind value (a wrapped string, a vector repr) would
# otherwise produce invalid `.typ` and fail the WHOLE PDF export.
_typ_str(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t")

# Built-in style presets. `article` is the default single-column research-note look;
# `report` is roomier with a larger title. `columns` (1 or 2) lays the body out in one
# or two columns — figures/code span the full width so they never overflow a column.
const _STYLES = Dict(
    # `article` — compact, unnumbered research-note look. `report` — roomier and with NUMBERED
    # sections + a larger title block, the academic-report distinction (not just a font bump).
    "article" => (textsize = "10.5pt", margin = "(x: 2.2cm, y: 2.4cm)", titlesize = "19pt",
                  headabove = "2.1em", headbelow = "1.2em",  parspace = "1.35em", number = false),
    "report"  => (textsize = "11pt",   margin = "(x: 2.7cm, y: 3.0cm)", titlesize = "26pt",
                  headabove = "2.7em", headbelow = "1.45em", parspace = "1.6em",  number = true),
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

# Body (prose) font sizes (the `body` option). Two-column layouts usually want a smaller
# body, so the export defaults `body` to "compact" when columns == 2.
const _BODY_SIZES = Dict("large" => "11.5pt", "normal" => "10.5pt", "compact" => "9.5pt", "small" => "8.5pt")
_body_size(body) = get(_BODY_SIZES, body, _BODY_SIZES["normal"])

# True if the document's section headings (the level-2+ ones Typst would auto-number) are MOSTLY
# numbered by hand already — "3.1 · …", "1.2)", "Section 3" — so we should leave Typst's numbering off
# and let the author's numbers stand (avoids the doubled "1 3.1 · …").
function _manual_heading_numbers(cells)
    head = r"^\s*#{2,6}\s+(.*\S)\s*$"
    num  = r"^(\d+([.)]\s*\d+)*[.):·\-]|\d+\s|(section|part|chapter|appendix)\b)"i
    total = 0; numbered = 0
    for c in cells
        c.kind == MARKDOWN || continue
        infence = false
        for ln in split(String(c.source), '\n')
            occursin(r"^\s*(```|~~~)", ln) && (infence = !infence; continue)
            infence && continue
            m = match(head, ln); m === nothing && continue
            total += 1
            occursin(num, m.captures[1]) && (numbered += 1)
        end
    end
    return total > 0 && numbered * 2 >= total      # majority manually numbered
end

function _typst_preamble(title::AbstractString; style::AbstractString = "article",
                         columns::Int = 1, theme::AbstractString = "light",
                         code::AbstractString = "normal", body::AbstractString = "normal",
                         number::Union{Bool,Nothing} = nothing)
    pre = _typ_str(strip(replace(_MITEX_SHIMS, r"\s+" => " ")))
    st = get(_STYLES, style, _STYLES["article"])
    donumber = number === nothing ? st.number : number   # caller can force off (e.g. headings are manually numbered)
    p = _palette(theme)
    csize = _code_size(code)
    bsize = _body_size(body)
    # Two-column flows via a `#columns()` wrapper on the body (see export_pdf), NOT a
    # page setting — that keeps the title block and abstract spanning the full width.
    pageopts = "paper: \"a4\", margin: $(st.margin), numbering: \"1\", fill: $(p.page)"
    rawtheme = isempty(p.codetheme) ? "" : "\n    #set raw(theme: \"$(p.codetheme)\")"
    return """
    #import "@preview/cmarker:$(_CMARKER_VER)"
    #import "@preview/mitex:$(_MITEX_VER)": mitex, mi
    #set document(title: "$(_typ_str(title))")
    #set page($pageopts)
    #set text(font: "New Computer Modern", size: $(bsize), fill: $(p.text))$(rawtheme)
    #set par(justify: true, spacing: $(st.parspace))
    #show heading: set block(above: $(st.headabove), below: $(st.headbelow))
    #show heading: set text(fill: $(p.title))
    $(donumber ? "#set heading(numbering: (..n) => { let m = n.pos(); if m.len() <= 1 { none } else { numbering(\"1.1\", ..m.slice(1)) } })" : "")
    #let PRE = "$pre "
    #let mathfn = (s, block: false) => if block { mitex(PRE + s) } else { mi(PRE + s) }
    $(_CITE_SHOW)
    #let titleblock(t) = { align(center, text(size: $(st.titlesize), weight: "bold", fill: $(p.title), t)); v(2pt); line(length: 100%, stroke: 0.5pt + $(p.rule)); v(10pt) }
    #let metablock(title, subtitle, byline, abstract) = {
      align(center)[
        #text(size: $(st.titlesize), weight: "bold", fill: $(p.title))[#title]
        #if subtitle != none { v(4pt); text(size: 1.25em, fill: $(p.title))[#subtitle] }
        #if byline != none { v(6pt); text(size: 0.86em, fill: $(p.parlabel))[#byline] }
      ]
      v(6pt); line(length: 100%, stroke: 0.5pt + $(p.rule)); v(10pt)
      if abstract != none {
        block(width: 100%, inset: 0pt)[
          #text(size: 0.82em, weight: "bold", tracking: 0.08em, fill: $(p.parlabel))[ABSTRACT]
          #v(3pt)
          #text(size: 0.94em, style: "italic")[#abstract]
        ]
        v(12pt)
      }
    }
    #let codeblock(s) = block(width: 100%, fill: $(p.codebg), inset: 8pt, radius: 4pt, text(size: $(csize), raw(block: true, lang: "julia", s)))
    #let outblock(s) = block(width: 100%, inset: 7pt, fill: $(p.outbg), radius: 3pt, text(size: 8.5pt, fill: $(p.outfg), raw(s)))
    #let valblock(s) = block(width: 100%, inset: 7pt, fill: $(p.valbg), radius: 3pt, text(size: 8.5pt, fill: $(p.valfg), raw(s)))
    #let errblock(s) = block(width: 100%, inset: 7pt, fill: $(p.errbg), radius: 3pt, text(size: 8.5pt, fill: $(p.errfg), raw(s)))
    #let figureimg(p) = align(center, image(p, width: 85%))
    #let notefig(s) = block(width: 100%, inset: 7pt, text(size: 8.5pt, style: "italic", fill: $(p.parlabel), s))
    #let figcaption(lbl, body) = block(width: 100%, inset: (x: 24pt, y: 4pt), text(size: 8.6pt, fill: $(p.parlabel))[#text(weight: "bold")[#lbl.] #body])
    #let paramblock(items) = block(width: 100%, inset: (x: 8pt, y: 5pt), fill: $(p.parbg), radius: 3pt, stroke: 0.5pt + $(p.parborder),
      text(size: 8.5pt)[#text(fill: $(p.parlabel), weight: "bold")[parameters] #h(6pt) #items.map(it => [#raw(it.at(0)) = #text(weight: "bold", it.at(1))]).join([#h(10pt)])])

    """
end

# ── Slide-deck preamble (16:9 / 4:3 landscape, one slide per page) ────────────────────────────────
# Slide page geometry (width, height) for a 254mm-wide canvas. 16:9 is the default deck size.
_slide_geom(ratio) = ratio == "4:3" ? ("254mm", "190.5mm") : ("254mm", "142.875mm")

# Preamble for the slides layout. Reuses the same block helpers as the article preamble but on a
# landscape slide page with bigger type, and adds `#let slide(body)` — one page per slide that
# vertically centers its content and auto-shrinks (down to a 0.5× floor) so a tall slide still fits.
function _typst_preamble_slides(title::AbstractString; theme::AbstractString = "dark",
                                ratio::AbstractString = "16:9", code::AbstractString = "small")
    pre = _typ_str(strip(replace(_MITEX_SHIMS, r"\s+" => " ")))
    p = _palette(theme)
    csize = _code_size(code == "normal" ? "small" : code)   # listings are tighter on slides
    w, h = _slide_geom(ratio)
    rawtheme = isempty(p.codetheme) ? "" : "\n    #set raw(theme: \"$(p.codetheme)\")"
    return """
    #import "@preview/cmarker:$(_CMARKER_VER)"
    #import "@preview/mitex:$(_MITEX_VER)": mitex, mi
    #set document(title: "$(_typ_str(title))")
    #set page(width: $w, height: $h, margin: (x: 16mm, y: 12mm), fill: $(p.page))
    #set text(font: "New Computer Modern", size: 19pt, fill: $(p.text))$(rawtheme)
    #set par(justify: false, leading: 0.7em, spacing: 1.1em)
    #show heading: set text(fill: $(p.title))
    #show heading.where(level: 1): set text(size: 1.7em)
    #show heading.where(level: 2): set text(size: 1.35em)
    #set heading(numbering: none)
    #let PRE = "$pre "
    #let mathfn = (s, block: false) => if block { mitex(PRE + s) } else { mi(PRE + s) }
    $(_CITE_SHOW)
    #let metablock(title, subtitle, byline, abstract) = align(center + horizon)[
      #text(size: 2.4em, weight: "bold", fill: $(p.title))[#title]
      #if subtitle != none { v(8pt); text(size: 1.4em, fill: $(p.title))[#subtitle] }
      #if byline != none { v(14pt); text(size: 0.9em, fill: $(p.parlabel))[#byline] }
      #if abstract != none { v(16pt); block(width: 80%, text(size: 0.8em, style: "italic")[#abstract]) }
    ]
    #let codeblock(s) = block(width: 100%, fill: $(p.codebg), inset: 8pt, radius: 4pt, text(size: $(csize), raw(block: true, lang: "julia", s)))
    #let outblock(s) = block(width: 100%, inset: 7pt, fill: $(p.outbg), radius: 3pt, text(size: 0.7em, fill: $(p.outfg), raw(s)))
    #let valblock(s) = block(width: 100%, inset: 7pt, fill: $(p.valbg), radius: 3pt, text(size: 0.7em, fill: $(p.valfg), raw(s)))
    #let errblock(s) = block(width: 100%, inset: 7pt, fill: $(p.errbg), radius: 3pt, text(size: 0.7em, fill: $(p.errfg), raw(s)))
    #let figureimg(p) = align(center, image(p, height: 62%))
    #let paramblock(items) = block(width: 100%, inset: (x: 8pt, y: 5pt), fill: $(p.parbg), radius: 3pt, stroke: 0.5pt + $(p.parborder),
      text(size: 0.7em)[#text(fill: $(p.parlabel), weight: "bold")[parameters] #h(6pt) #items.map(it => [#raw(it.at(0)) = #text(weight: "bold", it.at(1))]).join([#h(10pt)])])
    // One slide = one page. Measure the body at full content width; if it's taller than the page,
    // scale it down (floor 0.5×) so it still fits, then vertically center.
    #let slide(body) = page[
      #align(horizon)[
        #layout(sz => {
          let m = measure(box(width: sz.width, body))
          let s = if m.height > sz.height and m.height > 0pt { calc.max(0.5, sz.height / m.height) } else { 1.0 }
          scale(origin: top + center, x: s * 100%, y: s * 100%, box(width: sz.width, body))
        })
      ]
    ]

    """
end

# Citation rewriting. `cmarker` only honors a bare `[@key]` (it makes the whole bracket the
# citation label), so Pandoc locators/forms break it. We rewrite citation syntax into a plain-text
# sentinel `§c§<form>§<key>§<supplement>§` (survives cmarker verbatim) and a preamble `#show regex`
# turns each sentinel into a real Typst `cite(label(key), supplement: …, form: …)`. Supported:
#   [@key]              normal           [@key, p. 7] / [@key, pp. 3–9]   page locator (supplement)
#   [@a; @b]            multiple (adjacent cites — the CSL style groups them)
#   @key (bare)         prose form ("Knuth (1984)") — only when `key` is a defined bibliography key
# (Suppress-author isn't offered: Typst's year form drops the parentheses, which reads wrong; use the
#  prose form `@key` for an author-year mention.)
const _CITE_OPEN = "§c§"
# Preamble rule that turns each citation sentinel back into a real Typst cite (resolved against
# whatever `#bibliography(...)` the document emits). Harmless when there are no citations.
const _CITE_SHOW = raw"""#show regex("§c§[^§]*§[^§]+§[^§]*§"): it => {
  let p = it.text.split("§")
  let f = if p.at(2) == "y" { "year" } else if p.at(2) == "p" { "prose" } else { "normal" }
  if p.at(4) == "" { cite(label(p.at(3)), form: f) } else { cite(label(p.at(3)), supplement: [#p.at(4)], form: f) }
}"""
function _cite_token(key, sup, form)
    return string(_CITE_OPEN, form, "§", key, "§", replace(strip(sup), "§" => ""), "§")
end
# Default `emit` for the export path: a sentinel the preamble's `#show` rule turns into a Typst cite.
_cite_sentinel(key, sup, form) = _cite_token(key, sup, form)

# A `[@fig:label]` cross-reference → its rendered text. `figrefs` maps label → (num, anchor); the
# export default emits plain "Figure N" (the number is authoritative even without a hyperlink), the
# live view overrides `figemit` with an HTML link that jumps to the figure.
_fig_text(num, anchor) = string("Figure ", num)

# Rewrite one `[...]` citation group (its inner text, which contains an `@`); `emit(key,sup,form)`
# builds each replacement (a Typst sentinel for export, an HTML link for the live view). A `fig:`
# label resolved in `figrefs` becomes a figure cross-reference via `figemit` instead of a bib cite.
function _rewrite_bracket_cite(inner, emit; figrefs = Dict{String,Tuple{Int,String}}(), figemit = _fig_text)
    io = IOBuffer()
    for spec in split(inner, ';')
        # Accept an optional leading `-` (Pandoc suppress-author) but render normally — Typst's year
        # form drops the parentheses, which reads wrong, so we don't honor suppression.
        m = match(r"^\s*-?@([\w:.\-]+)\s*(?:,\s*(.*\S))?\s*$", spec)
        m === nothing && return nothing            # not a clean citation group → leave the bracket as-is
        key = m.captures[1]
        if haskey(figrefs, key)                    # figure cross-reference
            num, anchor = figrefs[key]
            print(io, figemit(num, anchor))
        else
            sup = m.captures[2] === nothing ? "" : m.captures[2]
            print(io, emit(key, sup, "n"))
        end
    end
    return String(take!(io))
end
# Rewrite the citation syntax in one stretch of TEXT (no code spans). Bracketed groups first, then
# bare `@key` (prose) — the latter only for defined keys, so emails/handles are left literal.
function _rewrite_text_citations(text, citekeys, emit; figrefs = Dict{String,Tuple{Int,String}}(), figemit = _fig_text)
    t = replace(text, r"\[([^\]\n]*@[^\]\n]*)\]" => m -> begin
        r = _rewrite_bracket_cite(m[2:end-1], emit; figrefs = figrefs, figemit = figemit); r === nothing ? m : r
    end)
    (isempty(citekeys) && isempty(figrefs)) && return t
    return replace(t, r"(?<![\w@/])@([\w:.\-]+)" => m -> begin
        raw = m[2:end]
        key = rstrip(raw, ['.', ',', ';', ':', ')', ']', '!', '?'])
        suffix = raw[(ncodeunits(key) + 1):end]
        if haskey(figrefs, key)
            num, anchor = figrefs[key]; figemit(num, anchor) * suffix
        elseif key in citekeys
            emit(key, "", "p") * suffix
        else
            m
        end
    end)
end
# Rewrite citations across a markdown source, skipping fenced code blocks AND inline `code` spans
# (so a literal `[@key]` shown in backticks is left untouched). `emit` selects sentinel vs HTML link;
# `figrefs`/`figemit` handle `[@fig:label]` figure cross-references.
function _rewrite_citations(md::AbstractString, citekeys = Set{String}(); emit = _cite_sentinel,
                            figrefs = Dict{String,Tuple{Int,String}}(), figemit = _fig_text)
    out = IOBuffer(); infence = false
    for (li, ln) in enumerate(split(md, '\n'))
        li == 1 || print(out, '\n')
        if occursin(r"^\s*(```|~~~)", ln); infence = !infence; print(out, ln); continue; end
        if infence; print(out, ln); continue; end
        # Protect inline `code` spans, rewrite the text between them, then restore the spans.
        spans = SubString{String}[]
        masked = replace(ln, r"`[^`]*`" => s -> (push!(spans, s); "\x00$(length(spans))\x00"))
        done = _rewrite_text_citations(masked, citekeys, emit; figrefs = figrefs, figemit = figemit)
        for (i, s) in enumerate(spans); done = replace(done, "\x00$(i)\x00" => s); end
        print(out, done)
    end
    return String(take!(out))
end

# Markdown source with `{{ expr }}` interpolations resolved to their scalar values (the only interp
# kind embeddable as text in v1) and citations rewritten to sentinels for the preamble's cite rule.
function _md_for_typst(c::Cell, src::AbstractString = c.source; citekeys = Set{String}(),
                       figrefs = Dict{String,Tuple{Int,String}}())
    tmpl, exprs = ReportEngine._md_template(src)
    s = tmpl
    for i in 1:length(exprs)
        o = i <= length(c.interp) ? c.interp[i] : nothing
        val = (o === nothing || o.exception !== nothing || isempty(o.value_repr)) ? "" : o.value_repr
        s = replace(s, ReportEngine._interp_token(i) => val)
    end
    return _rewrite_citations(s, citekeys; figrefs = figrefs)
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

# True if the cell's output includes a `text/html` chunk (a custom HTML card Typst can't render).
_has_html_output(c::Cell) = c.output !== nothing && any(ch -> ch.mime == "text/html", c.output.display)

# Emit a code cell's outputs (value / stdout / error / figure / tables) into the doc.
# Export output-verbosity: `"all"` (everything), `"figures"` (only figures / charts / tables / rendered
# math — drop scalar text reprs, stdout, and errors, the "working output" noise), `"none"` (nothing).
_outputs_text_ok(outputs) = String(outputs) == "all"
_outputs_any(outputs) = String(outputs) != "none"

function _emit_output!(io::IO, dir::AbstractString, base::AbstractString, nb::LiveNotebook, c::Cell;
                       theme::AbstractString = "light", outputs::AbstractString = "all")
    o = c.output
    (o === nothing || !_outputs_any(outputs)) && return
    texts = _outputs_text_ok(outputs)
    if o.exception !== nothing
        texts || return                                # figures-only: skip error text
        write(joinpath(dir, base * ".err"), rstrip(o.exception))
        print(io, "#errblock(read(\"", base, ".err\"))\n")
        return
    end
    if texts && !isempty(strip(o.stdout))
        write(joinpath(dir, base * ".out"), rstrip(o.stdout))
        print(io, "#outblock(read(\"", base, ".out\"))\n")
    end
    if texts && isempty(o.display) && !isempty(o.value_repr)
        write(joinpath(dir, base * ".val"), o.value_repr)
        print(io, "#valblock(read(\"", base, ".val\"))\n")
    end
    fig = _figure_for_export(nb, c; dark = theme == "dark")   # vector (pdf/svg) preferred, else raster png
    # An HTML output (a custom `text/html` card, e.g. the grading `check(...)` cells) can't be
    # rendered by Typst and isn't an embeddable figure — so rasterize the rendered card via the open
    # tab (html2canvas, same round-trip slate.inspect uses) and embed that image. Needs a live tab;
    # falls back to nothing (just the code) if none is open or the capture times out.
    if fig === nothing && _has_html_output(c)
        png = try; cell_image_fresh(nb, c.id); catch; nothing; end
        png === nothing || (fig = (copy(png), "png"))
    end
    if fig !== nothing
        data, ext = fig
        write(joinpath(dir, base * "." * ext), data)
        print(io, "#figureimg(\"", base, ".", ext, "\")\n")
    elseif !isempty(_echarts_specs(c))
        # A client-rendered chart that no browser tab was open to snapshot (headless export) —
        # don't silently drop it, note the gap (mirrors the HTML export path).
        print(io, "#notefig(\"[chart not captured — open this notebook in a browser, then re-export]\")\n")
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
    export_pdf(nb; include_source=true, style="article", columns=1,
               theme="light", code="normal", body="normal") -> Vector{UInt8}

Render the notebook to a publication-quality PDF via Typst and return the bytes.
`style ∈ ("article", "report")` picks a layout preset; `columns ∈ (1, 2)` lays the body
out single- or two-column; `theme ∈ ("light", "dark")` sets the colour scheme (dark
matches the live UI and Makie-dark figures). `code ∈ ("normal","small","smaller","tiny")`
sets the code-listing font size, or `"hidden"` to omit source entirely (also honoured via
`include_source`). `body ∈ ("large","normal","compact","small")` sets the prose font size
(defaults to "compact" for two-column). Figures use vector data when available (CairoMakie
PDF, ECharts SVG). `@bind` controls are omitted by default (a PDF is a static snapshot);
set `include_params=true` to show them frozen to their current values as a parameter strip.

Document metadata is authored as role-tagged cells (`#%% md id=… title` / `abstract` /
`bibliography`): the title/abstract are hoisted into an academic title block. With no `title`
cell the document title falls back to the first markdown H1 (then the notebook filename).
"""
function export_pdf(nb::LiveNotebook; kwargs...)
    dir = _build_typst_project(nb; kwargs...)
    try
        typ = joinpath(dir, "doc.typ"); pdf = joinpath(dir, "out.pdf")
        _typst_compile(typ, pdf)
        return read(pdf)
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ── Slide segmentation (shared boundary rules; mirrored in assets/js/slides.js) ───────────────────
# A notebook becomes a deck by grouping its cells into slides. Boundaries:
#   1. a markdown cell whose first heading is at depth ≤ `level` (default H2),
#   2. any cell flagged `:slide` (explicit start),
#   3. a thematic-break line (`---`) inside a markdown cell (splits it mid-cell),
#   4. a cell flagged `:notes` attaches to the current slide's speaker notes (not its body),
#   5. cells before the first boundary form the leading (title) slide.
# `:collapsed` cells are omitted, matching the article/report export.

# Depth of a markdown source's first ATX heading (skipping fenced code), or `nothing`.
function _first_heading_depth(src::AbstractString)
    infence = false
    for ln in split(src, '\n')
        if occursin(r"^\s*(```|~~~)", ln); infence = !infence; continue; end
        infence && continue
        m = match(r"^(#{1,6})\s+\S", ln)
        m === nothing || return length(m.captures[1])
    end
    return nothing
end

# Split a markdown source on thematic-break lines (`---`/`***`/`___`, 3+), skipping fenced code
# and a leading YAML front-matter block (its `---` fences are NOT slide breaks). Returns the
# inter-break chunks (≥1); a source with no rule returns `[src]`.
function _split_md_rules(src::AbstractString)
    parts = String[]
    buf = IOBuffer(); infence = false
    lines = split(src, '\n')
    for ln in lines
        if occursin(r"^\s*(```|~~~)", ln); infence = !infence; print(buf, ln, '\n'); continue; end
        if !infence && occursin(r"^\s*([-*_])(\s*\1){2,}\s*$", ln)
            push!(parts, String(take!(buf))); continue
        end
        print(buf, ln, '\n')
    end
    push!(parts, String(take!(buf)))
    return parts
end

# A slide: ordered body fragments `(cell, src_override)` (override is a `---`-split markdown
# chunk, else `nothing` = use the whole cell) plus the `:notes` cells attached to it.
const SlideFrag = Tuple{Cell,Union{String,Nothing}}

function _slide_segments(cells; level::Integer = 2)
    slides = NamedTuple{(:frags, :notes),Tuple{Vector{SlideFrag},Vector{Cell}}}[]
    frags = SlideFrag[]; notes = Cell[]
    function flush!()
        (isempty(frags) && isempty(notes)) && return
        push!(slides, (frags = frags, notes = notes))
        frags = SlideFrag[]; notes = Cell[]
    end
    for c in cells
        (:collapsed in c.flags) && continue
        if :notes in c.flags
            push!(notes, c); continue
        end
        d = c.kind == MARKDOWN ? _first_heading_depth(c.source) : nothing
        starts = (:slide in c.flags) || (d !== nothing && d <= level)
        if c.kind == MARKDOWN && length(_split_md_rules(c.source)) > 1
            for (j, part) in enumerate(_split_md_rules(c.source))
                ((j == 1 && starts) || j > 1) && flush!()
                isempty(strip(part)) || push!(frags, (c, String(part)))
            end
        else
            starts && flush!()
            push!(frags, (c, nothing))
        end
    end
    flush!()
    return slides
end

# ── Document metadata from role-tagged cells (title / abstract / bibliography) ────────────────────
# Metadata is authored as ordinary cells carrying a role tag, in natural document order, and each
# export target interprets the role for placement. `title`/`subtitle`/`byline` come from a `:title`
# cell's markdown (H1 / H2-H3 / first plain line); `:abstract` cell(s) supply the abstract; both are
# hoisted into the title block and dropped from the body (their ids land in `skip`). With no `:title`
# cell, the document title falls back to the first markdown H1 (then the notebook filename). One
# resolver for PDF, slides, and HTML.
function _parse_title_cell(src)
    title = ""; subtitle = ""; byline = ""
    for ln in split(String(src), '\n')
        s = strip(ln); isempty(s) && continue
        if isempty(title) && (m = match(r"^#\s+(.+?)\s*#*$", ln)) !== nothing
            title = strip(m.captures[1])
        elseif isempty(subtitle) && (m = match(r"^#{2,3}\s+(.+?)\s*#*$", ln)) !== nothing
            subtitle = strip(m.captures[1])
        elseif isempty(byline) && !startswith(s, "#")
            byline = String(s)
        end
    end
    return (title, subtitle, byline)
end

function report_frontmatter(report)
    cells = report.cells
    title = report.title; subtitle = ""; byline = ""; abstract = ""
    skip = Set{String}(); titlecell = ""
    titlei = findfirst(c -> :title in c.flags, cells)
    if titlei !== nothing
        t, s, b = _parse_title_cell(cells[titlei].source)
        isempty(t) || (title = t); subtitle = s; byline = b
        push!(skip, cells[titlei].id)
    else
        # No explicit `title` role tag → derive the document title from the FIRST markdown H1, so
        # exports read the real title instead of the notebook filename. The cell KEEPS its other
        # content in the body, but its leading H1 is stripped (via `titlecell`) so the title doesn't
        # render twice — once hoisted, once as a body heading.
        for c in cells
            c.kind == MARKDOWN || continue
            m = match(r"(?m)^#[ \t]+(.+?)[ \t]*#*$", c.source)
            m === nothing && continue
            title = strip(m.captures[1]); titlecell = c.id; break
        end
    end
    abscells = Cell[c for c in cells if :abstract in c.flags]
    if !isempty(abscells)
        abstract = join((strip(c.source) for c in abscells), "\n\n")
        for c in abscells; push!(skip, c.id); end
    end
    bibcells = Cell[c for c in cells if :bibliography in c.flags]
    has = titlei !== nothing || !isempty(strip(abstract))
    return (; title, subtitle, byline, abstract, skip, bibcells, titlecell, has)
end

# ── Figure captions + numbering ───────────────────────────────────────────────────────────────
# A caption is an ORDINARY markdown cell tagged `caption` (so it carries full markdown / $math$ /
# {{ }} / [@cite]). It attaches to a figure cell either by FLOW (the nearest preceding figure-bearing
# cell) or EXPLICITLY (`for=<id>`), and cross-refs resolve `[@fig:<label>]` → "Figure N" (label =
# `label=<name>`, else the caption cell's id). The `for=`/`label=` bindings ride the header as free-
# form tokens (they round-trip through `_parse_header`/`_cell_source`), so no schema change is needed.

# Value of a `key=…` header token stored as a free-form flag on the cell (e.g. `for=scaling`), or "".
function _flag_attr(cell::Cell, key::AbstractString)
    pre = key * "="
    for f in cell.flags
        s = String(f)
        startswith(s, pre) && return s[(length(pre) + 1):end]
    end
    return ""
end

# A code cell counts as a "figure" once it has run and produced an image / chart / table.
function _cell_has_figure(c::Cell)
    c.kind == CODE || return false
    o = c.output
    o === nothing && return false
    return any(ch -> startswith(ch.mime, "image/"), o.display) ||
           !isempty(_echarts_specs(c)) || !isempty(_table_specs(c))
end

"""
    figure_index(report) -> (; numbers, labels, capfor)

Resolve figure numbering from `caption`-tagged cells (document order):
- `numbers`  :: caption-cell-id → Figure number (Int)
- `labels`   :: cross-ref label → (num, anchor)  (label = `label=` attr, else the caption cell id;
               anchor = the bound figure cell's id when known, else the caption cell id)
- `capfor`   :: caption-cell-id → bound figure cell id ("" if none resolved)
"""
function figure_index(report)
    numbers = Dict{String,Int}(); labels = Dict{String,Tuple{Int,String}}(); capfor = Dict{String,String}()
    lastfig = ""; n = 0
    for c in report.cells
        _cell_has_figure(c) && (lastfig = c.id)
        (c.kind == MARKDOWN && :caption in c.flags) || continue
        n += 1; numbers[c.id] = n
        forid = _flag_attr(c, "for"); forid = isempty(forid) ? lastfig : forid
        capfor[c.id] = forid
        label = _flag_attr(c, "label"); label = isempty(label) ? c.id : label
        labels[label] = (n, isempty(forid) ? c.id : forid)
    end
    return (; numbers, labels, capfor)
end

# Drop the FIRST H1 line (and any blank lines it leaves at the top) from a markdown source — used to
# suppress the body copy of a heading that `report_frontmatter` hoisted into the title block.
function _strip_leading_h1(src::AbstractString)
    lines = collect(split(String(src), '\n'))
    i = findfirst(l -> occursin(r"^#[ \t]+\S", l), lines)
    i === nothing && return String(src)
    deleteat!(lines, i)
    while i <= length(lines) && isempty(strip(lines[i])); deleteat!(lines, i); end
    return join(lines, '\n')
end

# Resolve `:bibliography` cells into Typst bib files written into the project dir, returning the
# project-relative filenames for `#bibliography(...)`. A cell body of BibTeX entries (`@type{…}`)
# is embedded (written to refs.bib); a body of `.bib` path(s) — one per line — references external
# files copied in (resolved relative to the notebook's directory). `cmarker` already emits a
# markdown `@key` as a native Typst reference, so citations resolve against these with no bridge.
function _bibliography_files!(dir::AbstractString, bibcells, nbdir::AbstractString)
    files = String[]
    embedded = IOBuffer()
    for c in bibcells
        body = c.source
        if occursin(r"@\w+\s*\{", body)                 # embedded BibTeX entries
            println(embedded, strip(body))
        else
            for ln in split(body, '\n')                 # external `.bib` path(s)
                p = strip(ln); isempty(p) && continue
                src = isabspath(p) ? String(p) : joinpath(nbdir, p)
                isfile(src) || error("bibliography file not found: $p")
                fn = "ext_" * basename(src)
                cp(src, joinpath(dir, fn); force = true)
                fn in files || push!(files, fn)
            end
        end
    end
    emb = String(take!(embedded))
    if !isempty(strip(emb))
        write(joinpath(dir, "refs.bib"), emb)
        pushfirst!(files, "refs.bib")
    end
    return files
end

const _BibEntry = NamedTuple{(:key, :title, :author, :year),NTuple{4,String}}

# LaTeX accent command → the Unicode COMBINING mark it puts on the next letter; NFC then composes
# (`c`+◌̧ → ç, `e`+◌́ → é). Covers the accents BibTeX author/title fields actually use.
const _TEX_ACCENT = Dict{Char,Char}(
    '\'' => '́', '`' => '̀', '^' => '̂', '"' => '̈', '~' => '̃',   # acute grave circumflex diaeresis tilde
    '='  => '̄', '.' => '̇', 'c' => '̧', 'v' => '̌', 'u' => '̆',   # macron dot-above cedilla caron breve
    'H'  => '̋', 'k' => '̨', 'r' => '̊', 'b' => '̱', 'd' => '̣')    # double-acute ogonek ring macron-below dot-below
# Standalone LaTeX letter commands (no accent argument) → their Unicode letter. Multi-letter first so
# `\ss` isn't split as `\s`+`s`.
const _TEX_LETTER = ["ss" => "ß", "aa" => "å", "AA" => "Å", "ae" => "æ", "AE" => "Æ", "oe" => "œ",
    "OE" => "Œ", "o" => "ø", "O" => "Ø", "l" => "ł", "L" => "Ł", "i" => "ı", "j" => "ȷ"]

_tex_accent_sub(m::AbstractString) =
    (mm = match(r"\\([`'^\"~=.cvuHkrbd])\s*\{?\s*([A-Za-z])\}?", m);
     mm === nothing ? m : Base.Unicode.normalize(string(mm.captures[2], _TEX_ACCENT[mm.captures[1][1]]), :NFC))

# Common LaTeX math commands → their Unicode glyph (decoded only INSIDE `$…$`, so an operator like
# `\cdot` isn't confused with the `\c` cedilla accent, and Greek/ops in titles render). Word commands,
# matched with a trailing non-letter boundary; longer names win by that boundary (`\cdots` vs `\cdot`).
const _TEX_CMD = ["cdots" => "⋯", "cdot" => "·", "times" => "×", "div" => "÷", "pm" => "±", "mp" => "∓",
    "leq" => "≤", "geq" => "≥", "neq" => "≠", "approx" => "≈", "equiv" => "≡", "sim" => "∼", "propto" => "∝",
    "infty" => "∞", "ldots" => "…", "dots" => "…", "rightarrow" => "→", "leftarrow" => "←", "to" => "→",
    "partial" => "∂", "nabla" => "∇", "sum" => "∑", "prod" => "∏", "int" => "∫", "sqrt" => "√", "in" => "∈",
    "subset" => "⊂", "cup" => "∪", "cap" => "∩", "varepsilon" => "ε", "epsilon" => "ε", "varphi" => "φ",
    "alpha" => "α", "beta" => "β", "gamma" => "γ", "delta" => "δ", "zeta" => "ζ", "eta" => "η", "theta" => "θ",
    "iota" => "ι", "kappa" => "κ", "lambda" => "λ", "mu" => "μ", "nu" => "ν", "xi" => "ξ", "rho" => "ρ",
    "sigma" => "σ", "tau" => "τ", "phi" => "φ", "chi" => "χ", "psi" => "ψ", "omega" => "ω", "pi" => "π",
    "Gamma" => "Γ", "Delta" => "Δ", "Theta" => "Θ", "Lambda" => "Λ", "Xi" => "Ξ", "Pi" => "Π", "Sigma" => "Σ",
    "Phi" => "Φ", "Psi" => "Ψ", "Omega" => "Ω"]
const _TEX_SUP = Dict('0'=>'⁰','1'=>'¹','2'=>'²','3'=>'³','4'=>'⁴','5'=>'⁵','6'=>'⁶','7'=>'⁷','8'=>'⁸','9'=>'⁹','+'=>'⁺','-'=>'⁻','='=>'⁼','('=>'⁽',')'=>'⁾','n'=>'ⁿ','i'=>'ⁱ')
const _TEX_SUB = Dict('0'=>'₀','1'=>'₁','2'=>'₂','3'=>'₃','4'=>'₄','5'=>'₅','6'=>'₆','7'=>'₇','8'=>'₈','9'=>'₉','+'=>'₊','-'=>'₋','='=>'₌','('=>'₍',')'=>'₎')
# Map every char of `s` through `tbl` (super/subscript), or `nothing` if any char has no mapping.
function _tex_mapscript(s, tbl)
    io = IOBuffer()
    for c in s; haskey(tbl, c) ? print(io, tbl[c]) : return nothing; end
    return String(take!(io))
end
_tex_script_sub(m::AbstractString, tbl) =
    (mm = match(r"[\^_]\{?([^{}]+)\}?", m); mm === nothing ? m : something(_tex_mapscript(mm.captures[1], tbl), m))

# Decode a `$…$` math span (the `$` are dropped): operators/Greek, then super/subscripts.
function _tex_math_sub(m::AbstractString)
    inner = String(SubString(m, nextind(m, firstindex(m)), prevind(m, lastindex(m))))
    for (cmd, ch) in _TEX_CMD
        inner = replace(inner, Regex("\\\\" * cmd * "(?![A-Za-z])") => ch)
    end
    inner = replace(inner, r"\^\{[^{}]+\}" => x -> _tex_script_sub(x, _TEX_SUP))
    inner = replace(inner, r"\^[A-Za-z0-9+\-]" => x -> _tex_script_sub(x, _TEX_SUP))
    inner = replace(inner, r"_\{[^{}]+\}" => x -> _tex_script_sub(x, _TEX_SUB))
    inner = replace(inner, r"_[A-Za-z0-9+\-]" => x -> _tex_script_sub(x, _TEX_SUB))
    return inner
end

# Decode the common LaTeX macros a BibTeX field carries so the LIVE view reads cleanly:
#  • accents — SYMBOL accents (`\'e`/`\'{e}` → é) bare or braced; LETTER accents (`\c{c}` → ç, `\H{o}`
#    → ő) ONLY braced, so a word command like `\cdot`/`\vec` isn't mis-read as `\c`+`d` / `\v`+`e`;
#  • standalone letters (`{\ss}` → ß, `{\o}` → ø);
#  • `$…$` math — operators/Greek (`\cdot` → ·) + super/subscripts (`10^9` → 10⁹), dropping the `$`;
#  • case-protecting braces (`{M}ontgomery` → `Montgomery`).
# Best-effort, LIVE-view only — the exported `.bib` keeps the raw source for the CSL engine.
function _delatex(s::AbstractString)
    str = String(s)
    (occursin('\\', str) || occursin('{', str) || occursin('$', str)) || return str   # fast path
    str = replace(str, r"\$[^$]*\$" => _tex_math_sub)                  # math spans first (scopes ^/_ )
    str = replace(str, r"\\['`^\"~=.]\s*\{?\s*[A-Za-z]\}?" => _tex_accent_sub)   # symbol accents (bare/braced)
    str = replace(str, r"\\[cvuHkrbd]\{[A-Za-z]\}" => _tex_accent_sub)           # letter accents (braced only)
    for (cmd, ch) in _TEX_LETTER
        str = replace(str, Regex("\\\\" * cmd * "(?![A-Za-z])") => ch)  # \o \ss … (no trailing letter)
    end
    str = replace(str, r"\\([&%_#\$])" => s"\1")                        # \& \% \_ \# \$ → literal
    return replace(str, r"[{}]" => "")                                  # drop remaining protective braces
end

# Parse BibTeX entries from a string — best-effort (not a full parser; keys are exact, fields
# snipped) — for citation autocomplete, the card, and the live author-date label.
function _parse_bibtex_entries(text::AbstractString)
    out = _BibEntry[]
    for part in split(String(text), r"(?=@\w+\s*\{)")
        m = match(r"^@\w+\s*\{\s*([^,\s]+)", part)
        m === nothing && continue
        # A braced value with ARBITRARILY nested braces (a recursive subpattern — `{\c{C}}` nests two
        # deep, so a fixed one-level match would truncate it), else a quoted value or a bare token
        # (`year = 1984`). LaTeX-decoded for display.
        function fld(n)
            mb = match(Regex(n * raw"\s*=\s*(\{(?:[^{}]|(?1))*\})", "i"), part)
            mb === nothing || return _delatex(strip(chop(mb.captures[1]; head = 1, tail = 1)))   # drop outer { }
            mq = match(Regex(n * raw"\s*=\s*\"([^\"\n]*)\"", "i"), part)
            mq === nothing || return _delatex(strip(mq.captures[1]))
            mn = match(Regex(n * raw"\s*=\s*(\d[\w\-]*)", "i"), part)
            mn === nothing ? "" : _delatex(strip(mn.captures[1]))
        end
        push!(out, (key = String(m.captures[1]), title = fld("title"), author = fld("author"), year = fld("year")))
    end
    return out
end

# Numeric CSL styles cite as [1]; the rest are author-date. Drives the LIVE citation format (the PDF
# uses the real CSL engine either way).
_is_numeric_style(style::AbstractString) =
    lowercase(String(style)) in ("ieee", "vancouver", "nature", "chicago-notes",
                                 "iso-690-numeric", "american-physics-society")

# A compact author-date label for the live view, e.g. "Knuth, 1984" / "Cormen et al., 2009".
function _author_year_label(author::AbstractString, year::AbstractString)
    a = strip(String(author))
    surname = ""
    if !isempty(a)
        first = strip(split(a, r"\s+and\s+")[1])                 # first listed author
        surname = occursin(",", first) ? strip(split(first, ",")[1]) :  # "Knuth, Donald"
                  String(strip(split(first)[end]))                       # "Donald E. Knuth" → "Knuth"
        occursin(r"\band\b", a) && (surname *= " et al.")
    end
    yr = strip(String(year))
    isempty(surname) && return yr
    return isempty(yr) ? surname : string(surname, ", ", yr)
end

# All citation entries defined by a report's `:bibliography` cells (embedded + external .bib),
# resolved relative to `nbdir`. Powers `[@`-autocomplete and the per-cell card.
function bibliography_index(report, nbdir::AbstractString)
    entries = _BibEntry[]
    for c in report.cells
        :bibliography in c.flags || continue
        if occursin(r"@\w+\s*\{", c.source)
            append!(entries, _parse_bibtex_entries(c.source))
        else
            for ln in split(c.source, '\n')
                p = strip(ln); isempty(p) && continue
                src = isabspath(p) ? String(p) : joinpath(nbdir, p)
                isfile(src) && append!(entries, _parse_bibtex_entries(read(src, String)))
            end
        end
    end
    return entries
end

# Citation keys actually referenced in the notebook's prose — every `@key` in a markdown cell
# (skipping fenced code and the bibliography cells themselves, whose `@book{…}` aren't citations).
# Mirrors what cmarker turns into Typst references; drives the adaptive references card.
function cited_citation_keys(report)
    keys = Set{String}()
    for c in report.cells
        c.kind == MARKDOWN || continue
        :bibliography in c.flags && continue
        infence = false
        for ln in split(c.source, '\n')
            if occursin(r"^\s*(```|~~~)", ln); infence = !infence; continue; end
            infence && continue
            for m in eachmatch(r"(?<![\w@])@([A-Za-z][\w:.\-]*)", ln)
                push!(keys, String(m.captures[1]))
            end
        end
    end
    return keys
end

# Citation NUMBERS by first appearance (key → 1,2,3…) across the notebook's prose — matches the
# numeric CSL ordering, so the live view can show [1]/[2] like the PDF. Reuses the rewriter's exact
# detection (code-skipping + defined-key check) via a recording emit, so it never drifts.
function citation_numbers(report, citekeys)
    order = String[]; seen = Set{String}()
    rec = (key, _sup, _form) -> (k = String(key); (k in seen || (push!(order, k); push!(seen, k))); "")
    for c in report.cells
        (c.kind == MARKDOWN && !(:bibliography in c.flags)) || continue
        _rewrite_citations(c.source, citekeys; emit = rec)
    end
    return Dict{String,Int}(k => i for (i, k) in enumerate(order))
end

# Per-cell bibliography summary for the live card: (external-file-or-"", entry count, entries).
function bib_cell_info(cell, nbdir::AbstractString)
    body = cell.source
    if occursin(r"@\w+\s*\{", body)
        es = _parse_bibtex_entries(body)
        return ("", length(es), es)
    end
    file = ""; es = _BibEntry[]
    for ln in split(body, '\n')
        p = strip(ln); isempty(p) && continue
        file = String(p)
        src = isabspath(p) ? String(p) : joinpath(nbdir, p)
        isfile(src) && append!(es, _parse_bibtex_entries(read(src, String)))
    end
    return (file, length(es), es)
end

# Typst `#bibliography(...)` call for the resolved files, or "" when there are none.
function _bibliography_typst(files, style::AbstractString)::String
    isempty(files) && return ""
    farg = length(files) == 1 ? "\"$(files[1])\"" : "(" * join(("\"$f\"" for f in files), ", ") * ")"
    return "#bibliography($farg, style: \"$(style)\", title: [References])\n"
end

# Assemble the Typst PROJECT — `doc.typ` plus every per-cell aux file it reads (.md / .jl /
# figures / output blocks) — into a fresh temp dir and return its path. Shared by `export_pdf`
# (compile it) and `export_typst_bundle` (archive it). Holds `nb.lock` while reading the report;
# the caller owns the returned dir and must `rm` it.
function _build_typst_project(nb::LiveNotebook; include_source::Bool = true,
                              style::AbstractString = "article", columns::Integer = 1,
                              theme::AbstractString = "light", code::AbstractString = "normal",
                              body::AbstractString = "", include_params::Bool = false,
                              layout::AbstractString = "article", notes::Bool = false,
                              level::Integer = 2, outputs::AbstractString = "all")
    # Slide-deck layout takes a wholly different page geometry/flow — dispatch early.
    layout == "slides" && return _build_slides_project(nb; theme = theme, code = code,
        include_source = include_source, include_params = include_params, notes = notes,
        level = level, ratio = get(nb.report.meta, "slideratio", "16:9"), outputs = outputs)
    show_source = include_source && code != "hidden"
    cols = clamp(Int(columns), 1, 2)
    body = isempty(body) ? (cols == 2 ? "compact" : "normal") : body   # narrow columns → smaller default
    lock(nb.lock) do
        dir = mktempdir()
        # Dark theme highlights code via a bundled tmTheme that Typst reads from the root.
        theme == "dark" && write(joinpath(dir, "code-dark.tmTheme"), _CODE_DARK_TMTHEME)
        io = IOBuffer()
        # If the author manually numbers their headings ("3.1 · …", "Section 3"), suppress Typst's
        # auto-numbering so it doesn't prepend a second number ("1 3.1 · …").
        numoverride = _manual_heading_numbers(nb.report.cells) ? false : nothing
        print(io, _typst_preamble(nb.report.title; style = style, columns = cols,
                                  theme = theme, code = code, body = body, number = numoverride))
        # Role-tagged metadata (title / abstract) → academic title block spanning full width;
        # the hoisted cells are then dropped from the body.
        cells = nb.report.cells
        fm = report_frontmatter(nb.report)
        figidx = figure_index(nb.report)
        citekeys = Set(e.key for e in bibliography_index(nb.report, dirname(abspath(nb.path))))
        arg(s) = isempty(strip(s)) ? "none" : "\"" * _typ_str(s) * "\""
        if !fm.has
            print(io, "#titleblock(\"", _typ_str(fm.title), "\")\n\n")
        else
            absarg = "none"
            if !isempty(strip(fm.abstract))
                write(joinpath(dir, "abstract.md"), _rewrite_citations(fm.abstract, citekeys))
                absarg = "cmarker.render(read(\"abstract.md\"), math: mathfn)"
            end
            print(io, "#metablock(", arg(fm.title), ", ", arg(fm.subtitle), ", ", arg(fm.byline), ", ", absarg, ")\n\n")
        end
        cols == 2 && print(io, "#columns(2)[\n")
        for (k, c) in enumerate(cells)
            base = "c$(k)"
            (:collapsed in c.flags) && continue       # folded cell → omit from the export entirely
            c.id in fm.skip && continue               # hoisted into the title block above
            (:bibliography in c.flags) && continue    # rendered as #bibliography at the end, not raw
            if c.kind == MARKDOWN
                src = c.id == fm.titlecell ? _strip_leading_h1(c.source) : c.source   # hoisted H1 → not in body
                md = _md_for_typst(c, src; citekeys = citekeys, figrefs = figidx.labels)
                isempty(strip(md)) && continue       # empty markdown cell leaves nothing to render
                write(joinpath(dir, base * ".md"), md)
                if haskey(figidx.numbers, c.id)      # a caption cell → numbered "Figure N." block
                    print(io, "#figcaption(\"Figure ", figidx.numbers[c.id],
                          "\", cmarker.render(read(\"", base, ".md\"), math: mathfn))\n\n")
                else
                    print(io, "#cmarker.render(read(\"", base, ".md\"), math: mathfn)\n\n")
                end
            else
                # Match the browser: `show_source` is the global toggle; also hide source for the
                # per-cell 🙈 `hidecode` flag and for `@bind` cells (which show their widget, not code).
                if show_source && !(:hidecode in c.flags) && isempty(c.binds) && !isempty(strip(c.source))
                    write(joinpath(dir, base * ".jl"), c.source)
                    print(io, "#codeblock(read(\"", base, ".jl\"))\n")
                end
                include_params && print(io, _emit_controls(c))   # frozen @bind controls — off by default
                _emit_output!(io, dir, base, nb, c; theme = theme, outputs = outputs)
                print(io, "\n")
            end
        end
        # References — `:bibliography` cells (embedded + external .bib), rendered via Typst's CSL.
        biblio = _bibliography_files!(dir, fm.bibcells, dirname(abspath(nb.path)))
        print(io, _bibliography_typst(biblio, get(nb.report.meta, "bibstyle", "ieee")))
        cols == 2 && print(io, "]\n")
        write(joinpath(dir, "doc.typ"), String(take!(io)))
        return dir
    end
end

# Emit one slide fragment (a whole cell, or a `---`-split markdown chunk) into the doc.
function _emit_slide_frag!(io::IO, dir, base, nb, frag::SlideFrag; theme, show_source, include_params, citekeys = Set{String}(), outputs::AbstractString = "all")
    c, override = frag
    if c.kind == MARKDOWN
        md = _md_for_typst(c, override === nothing ? c.source : override; citekeys = citekeys)
        isempty(strip(md)) && return
        write(joinpath(dir, base * ".md"), md)
        print(io, "#cmarker.render(read(\"", base, ".md\"), math: mathfn)\n\n")
    else
        if show_source && !(:hidecode in c.flags) && isempty(c.binds) && !isempty(strip(c.source))
            write(joinpath(dir, base * ".jl"), c.source)
            print(io, "#codeblock(read(\"", base, ".jl\"))\n")
        end
        include_params && print(io, _emit_controls(c))
        _emit_output!(io, dir, base, nb, c; theme = theme, outputs = outputs)
        print(io, "\n")
    end
    return
end

# Assemble a slide-DECK Typst project: one page per slide (segmented by `_slide_segments`),
# 16:9/4:3 landscape, auto-fit. Code listings are hidden by default on slides (set `code`/
# `include_source`). With `notes=true`, a speaker-notes appendix follows the deck.
function _build_slides_project(nb::LiveNotebook; theme::AbstractString = "dark",
                               ratio::AbstractString = "16:9", code::AbstractString = "hidden",
                               include_source::Bool = false, include_params::Bool = false,
                               notes::Bool = false, level::Integer = 2, outputs::AbstractString = "all")
    show_source = include_source && code != "hidden"
    lock(nb.lock) do
        dir = mktempdir()
        theme == "dark" && write(joinpath(dir, "code-dark.tmTheme"), _CODE_DARK_TMTHEME)
        io = IOBuffer()
        print(io, _typst_preamble_slides(nb.report.title; theme = theme, ratio = ratio, code = code))
        cells = nb.report.cells
        # Role-tagged metadata → a dedicated title slide (metablock); hoisted title/abstract cells
        # are dropped from the body slides.
        fm = report_frontmatter(nb.report)
        citekeys = Set(e.key for e in bibliography_index(nb.report, dirname(abspath(nb.path))))
        arg(s) = isempty(strip(s)) ? "none" : "\"" * _typ_str(s) * "\""
        if fm.has
            print(io, "#slide(metablock(", arg(fm.title), ", ", arg(fm.subtitle), ", ",
                  arg(fm.byline), ", ", arg(fm.abstract), "))\n\n")
        end
        segs = _slide_segments(cells; level = level)
        for (si, seg) in enumerate(segs)
            # drop hoisted title/abstract cells and the bibliography (rendered as a closing slide)
            frags = [f for f in seg.frags if !(f[1].id in fm.skip) && !(:bibliography in f[1].flags)]
            isempty(frags) && continue
            print(io, "#slide[\n")
            for (fi, frag) in enumerate(frags)
                # Strip the hoisted H1 from the implicit-title cell so it isn't repeated on a body slide.
                f = (frag[1].id == fm.titlecell && frag[2] === nothing) ? (frag[1], _strip_leading_h1(frag[1].source)) : frag
                _emit_slide_frag!(io, dir, "s$(si)f$(fi)", nb, f; theme = theme,
                                  show_source = show_source, include_params = include_params, citekeys = citekeys, outputs = outputs)
            end
            print(io, "]\n\n")
        end
        # References slide — `:bibliography` cells rendered via Typst's CSL engine.
        biblio = _bibliography_files!(dir, fm.bibcells, dirname(abspath(nb.path)))
        isempty(biblio) || print(io, "#slide[\n",
            _bibliography_typst(biblio, get(nb.report.meta, "bibstyle", "ieee")), "]\n\n")
        if notes
            for (si, seg) in enumerate(segs)
                isempty(seg.notes) && continue
                ntext = join((_md_for_typst(n; citekeys = citekeys) for n in seg.notes), "\n\n")
                isempty(strip(ntext)) && continue
                write(joinpath(dir, "notes$(si).md"), ntext)
                print(io, "#slide[\n#text(fill: luma(130))[Notes · slide $(si)]\n#v(6pt)\n",
                      "#cmarker.render(read(\"notes$(si).md\"), math: mathfn)\n]\n\n")
            end
        end
        write(joinpath(dir, "doc.typ"), String(take!(io)))
        return dir
    end
end

"""
    export_typst_bundle(nb; <same options as export_pdf>) -> Vector{UInt8}

The complete Typst PROJECT — `doc.typ` plus every figure / markdown / code-listing asset it
references — as a gzip-compressed tarball (`.tar.gz`). Unpack it and `typst compile doc.typ`
reproduces the PDF, so the layout and preamble can be tweaked by hand.
"""
function export_typst_bundle(nb::LiveNotebook; kwargs...)
    dir = _build_typst_project(nb; kwargs...)
    try
        tarball = Tar.create(dir)
        try
            return transcode(GzipCompressor, read(tarball))
        finally
            rm(tarball; force = true)
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end
