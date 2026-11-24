# ── Literate.jl dialect ──────────────────────────────────────────────────────────────────────────────
#
# A `.jl` with no Slate structure (no `#%%` header, no `Slate.` footer) is read and written as a
# Literate.jl source, so a package's Literate examples open in Slate and stay valid Literate input.
# The rules are Literate's own:
#
# - a line that is `#` or `# …` (optionally indented) is markdown; everything else is code
# - a chunk ends where the lines switch between markdown and code; a blank line ends a markdown chunk
# - `#-` / `#+` lines start a new chunk
# - `## …` in code is a code comment, read as `# …`
# - a `#=` … `=#` block (each delimiter alone on its line) is markdown
#
# Every chunk becomes a cell. Literate's output filters (`#src`, `#md`, `#nb`, `#jl` and their `#!`
# negations) are kept. A filtered markdown line joins its markdown cell, marked with the filter (see
# `_lit_md_text`). A filtered code line stays in its code cell as written: a leading filter makes it a
# comment, so it is inert, and a line with a trailing `#src` runs, since Slate edits the source.
#
# Saving writes the file back like a patch. Each cell remembers the exact lines it came from, and a
# cell whose source is unchanged is written as those lines; the text between two cells that are still
# neighbours is kept too. Only edited or new cells are rendered, so a save leaves the author's
# spacing, `#+` vs `#-`, and `#=` blocks alone wherever they didn't edit.
#
# Nothing Slate-specific is written: ids, tags, and `controls=` live only in the session, and a cell
# kind Literate has no form for (web, job, …) can't be saved. Converting the file to a Slate notebook
# lifts both limits.

"One cell as it appeared in a Literate file."
struct LiterateSpan
    index::Int              # position among the file's cells
    kind::CellKind
    source::String          # the cell source it parsed to, normalized (`_lit_norm`)
    raw::Vector{String}     # its lines, exactly as in the file
end

"""
The layout of a Literate file: each cell's original lines (by cell id) and the text between cells.
`gaps[i]` precedes cell `i`; `gaps[end]` follows the last one.
"""
struct LiterateDoc
    spans::Dict{String,LiterateSpan}
    gaps::Vector{Vector{String}}
    eol::String             # "\n", or "\r\n" for a file checked out with CRLF line endings
end

"Raised when a notebook holds something a Literate file can't express."
struct LiterateUnsupported <: Exception
    msg::String
end
Base.showerror(io::IO, e::LiterateUnsupported) = print(io, "Literate: ", e.msg)

const _LIT_MD = r"^(\h*)#(?: (.*))?$"
_lit_is_md(l::AbstractString) = occursin(r"^\h*#$", l) || occursin(r"^\h*# ", l)
_lit_is_break(l::AbstractString) = occursin(r"^\h*#[-+]", l)
_lit_md_content(l::AbstractString) = (m = match(_LIT_MD, l); m.captures[2] === nothing ? "" : String(m.captures[2]))
# `## x` → `# x`, `##` → `#`: Literate's code-comment escape.
_lit_unescape(l::AbstractString) = replace(replace(String(l), r"^(\h*)#(# .*)$" => s"\1\2"), r"^(\h*#)#$" => s"\1")
# An output filter on a markdown line: in front, `#md # text` (also `#nb`, `#jl`, `#src`, `#!md`, …),
# or after it, `# text #md`. Such a line is markdown for the outputs it is kept in, so it joins the
# markdown cell. Its filter is carried in the cell source as an HTML comment ending the line, which
# renders as nothing: `text <!-- #md -->`. At the start of a line the comment would open an HTML
# block and the rest of the line would not render as markdown.
const _LIT_FILTER_LEAD = r"^(\h*)#(!?(?:md|nb|jl|src)) (.*)$"
const _LIT_FILTER_TAIL = r"^(.*) #(!?(?:md|nb|jl|src))$"
const _LIT_FILTER_MARK = r"^(.*?) ?<!-- #(!?(?:md|nb|jl|src)) -->$"

# `(filter, line without it)` for a markdown line with a leading filter, else `nothing`.
function _lit_filtered_md(l::AbstractString)
    m = match(_LIT_FILTER_LEAD, l)
    m === nothing && return nothing
    rest = m.captures[1] * m.captures[3]
    return _lit_is_md(rest) ? (String(m.captures[2]), rest) : nothing
end
_lit_mark(text::AbstractString, f::AbstractString) = isempty(text) ? "<!-- #$f -->" : "$text <!-- #$f -->"

# The markdown a line contributes to its cell's source.
function _lit_md_text(l::AbstractString)
    f = _lit_filtered_md(l)
    f === nothing || return _lit_mark(_lit_md_content(f[2]), f[1])
    c = _lit_md_content(l)
    m = match(_LIT_FILTER_TAIL, c)
    return m === nothing ? c : _lit_mark(m.captures[1], m.captures[2])
end

# One line of a markdown cell's source, written as Literate.
function _lit_md_line(l::AbstractString)
    m = match(_LIT_FILTER_MARK, l)
    m === nothing && return isempty(l) ? "#" : "# " * l
    text = m.captures[1]
    return isempty(text) ? "#$(m.captures[2]) #" : "#$(m.captures[2]) # $text"
end

# The inverse, for a code line that would otherwise read as markdown.
_lit_escape(l::AbstractString) = (_lit_is_md(l) ? replace(String(l), r"^(\h*)#" => s"\1##") : String(l))

# Cell sources compare after Literate's own normalization: trailing whitespace dropped, blank edges trimmed.
_lit_norm(src::AbstractString) = join(_strip_blank_edges([rstrip(l) for l in split(src, '\n')]), "\n")

# A content-derived id that doesn't depend on position, so inserting a cell leaves every other id alone.
function _lit_id(kind::CellKind, source::AbstractString, used::AbstractSet{String})
    salt = 0
    while true
        id = string(hash(("literate", kind, source, salt)) % 0xffffff; base = 16, pad = 6)
        id in used || return id
        salt += 1
    end
end

"""
    is_literate_source(text) -> Bool

True for a `.jl` that Slate reads as Literate: some content, no `#%%` cell header, and no `Slate.`
footer. A file holding only the runnable preamble is a Slate notebook with no cells.
"""
function is_literate_source(text::AbstractString)
    content = false
    preamble_only = true
    for l in eachline(IOBuffer(text))
        isempty(strip(l)) && continue
        content = true
        (match(_HEADER, l) !== nothing || startswith(l, "# ╔═╡ Slate.")) && return false
        _is_preamble_line(l) || (preamble_only = false)
    end
    return content && !preamble_only
end

# Split Literate source into chunks: `(kind, first, last)` line ranges, blank and `#`-only edges trimmed.
function _lit_chunks(lines::Vector{String})
    n = length(lines)
    # Classify each line. A `#=` … `=#` block is markdown throughout, delimiters included.
    cls = Vector{Symbol}(undef, n)          # :md, :mdblank (`#`), :code, :blank, :break, :mdblock
    i = 1
    while i <= n
        l = rstrip(lines[i])
        if occursin(r"^#=+$", l)
            j = findnext(t -> occursin(r"^=+#$", rstrip(lines[t])), 1:n, i + 1)
            if j !== nothing
                cls[i:j] .= :mdblock
                i = j + 1
                continue
            end
        end
        cls[i] = isempty(l) ? :blank : _lit_is_break(l) ? :break :
                 _lit_filtered_md(l) !== nothing ? :md :
                 _lit_is_md(l) ? (isempty(_lit_md_content(l)) ? :mdblank : :md) : :code
        i += 1
    end
    ismd(c) = c in (:md, :mdblank, :mdblock)
    chunks = Tuple{CellKind,Int,Int}[]
    i = 1
    while i <= n
        c = cls[i]
        if c === :blank || c === :break || c === :mdblank
            i += 1
            continue
        end
        j = i
        if ismd(c)
            while j < n && ismd(cls[j + 1]); j += 1; end
            while cls[j] === :mdblank; j -= 1; end          # trailing `#` lines belong to the gap
            push!(chunks, (MARKDOWN, i, j))
        else
            # Code runs through blank lines (they stay inside the chunk) until markdown or a break.
            while j < n && (cls[j + 1] === :code || cls[j + 1] === :blank); j += 1; end
            while cls[j] === :blank; j -= 1; end
            push!(chunks, (CODE, i, j))
        end
        i = j + 1
    end
    return chunks
end

function _lit_source(kind::CellKind, raw::AbstractVector{<:AbstractString})
    if kind === MARKDOWN
        out = String[]
        inblock = false                             # inside `#=` … `=#` every line is prose as written
        for l in raw
            s = rstrip(l)
            if !inblock && occursin(r"^#=+$", s)
                inblock = true
            elseif inblock && occursin(r"^=+#$", s)
                inblock = false
            else
                push!(out, inblock ? String(s) : _lit_md_text(s))
            end
        end
        return join(out, "\n")
    end
    return join((_lit_unescape(l) for l in raw), "\n")
end

# Read Literate text into its cells and layout. Cell ids come from `idfor(kind, source, k)`.
function _lit_read(text::AbstractString, idfor)
    eol = occursin("\r\n", text) ? "\r\n" : "\n"
    lines = String.(split(replace(text, "\r\n" => "\n"), '\n'))
    chunks = _lit_chunks(lines)
    cells = Cell[]
    spans = Dict{String,LiterateSpan}()
    gaps = Vector{String}[]
    prev = 0
    for (k, (kind, a, b)) in enumerate(chunks)
        push!(gaps, lines[(prev + 1):(a - 1)])
        raw = lines[a:b]
        src = _lit_source(kind, raw)
        id = idfor(kind, src, k)
        push!(cells, Cell(id, kind, src))
        spans[id] = LiterateSpan(k, kind, _lit_norm(src), raw)
        prev = b
    end
    push!(gaps, lines[(prev + 1):end])
    return cells, LiterateDoc(spans, gaps, eol)
end

"""
    parse_literate(text; id="r", title="") -> Report

Read a Literate.jl source into a `Report`, one cell per chunk. `report.meta["dialect"]` is
`"literate"` and `report.meta["literate"]` holds the file's layout, which `render_literate` uses to
write unchanged cells back byte for byte.
"""
function parse_literate(text::AbstractString; id::AbstractString = "r", title::AbstractString = "")
    report = Report(id, title)
    used = Set{String}()
    cells, doc = _lit_read(text, (kind, src, _) -> (i = _lit_id(kind, src, used); push!(used, i); i))
    append!(report.cells, cells)
    report.meta["dialect"] = "literate"
    report.meta["literate"] = doc
    return report
end

is_literate(report::Report) = get(report.meta, "dialect", "") == "literate"

"""
    adopt_literate_ids!(new, old) -> new

Give each cell of `new` (a fresh `parse_literate` of the file) the id of a cell in `old` with the
same kind and source, so an external edit to one cell leaves the others' ids, and everything keyed
by them, alone. Cells with no match keep a content id that no adopted cell already holds.
"""
function adopt_literate_ids!(new::Report, old::Report)
    pool = Dict{Tuple{CellKind,String},Vector{String}}()
    for c in old.cells
        push!(get!(() -> String[], pool, (c.kind, _lit_norm(c.source))), c.id)
    end
    rename = Dict{String,String}()
    taken = Set{String}()
    for c in new.cells
        ids = get(pool, (c.kind, _lit_norm(c.source)), nothing)
        (ids === nothing || isempty(ids)) && continue
        rename[c.id] = popfirst!(ids)
        push!(taken, rename[c.id])
    end
    for c in new.cells
        haskey(rename, c.id) && continue
        if c.id in taken
            rename[c.id] = _lit_id(c.kind, c.source, union(taken, Set(x.id for x in new.cells)))
            push!(taken, rename[c.id])
        else
            push!(taken, c.id)
        end
    end
    for c in new.cells
        c.id = get(rename, c.id, c.id)
    end
    doc = new.meta["literate"]::LiterateDoc
    new.meta["literate"] = LiterateDoc(Dict(get(rename, k, k) => v for (k, v) in doc.spans), doc.gaps, doc.eol)
    return new
end

function _lit_render(c::Cell)
    lines = split(_lit_norm(c.source), '\n')
    c.kind === MARKDOWN && return [_lit_md_line(l) for l in lines]
    return [_lit_escape(l) for l in lines]
end

# What goes between two cells written next to each other for the first time. A blank line separates
# everything but two code chunks, which Literate would otherwise merge into one.
_lit_sep(a::CellKind, b::CellKind) = a === CODE && b === CODE ? ["", "#-", ""] : [""]

"""
    render_literate(report) -> (text, doc)

Write a Literate-dialect report back to Literate source, and the layout of what was written (for the
next save). Unchanged cells keep their original lines and the gaps between unchanged neighbours are
kept; edited and new cells are rendered. Empty cells are left out. Tags and `controls=` are not
written. Throws `LiterateUnsupported` for a cell kind Literate can't express, or for an edit that
would not read back as the same cells (a code line that is itself `#-`, say).
"""
function render_literate(report::Report)
    doc = get(report.meta, "literate", nothing)
    doc isa LiterateDoc || (doc = LiterateDoc(Dict{String,LiterateSpan}(), [String[], [""]], "\n"))
    cells = Cell[]
    for c in report.cells
        c.kind in (CODE, MARKDOWN) ||
            throw(LiterateUnsupported("a $(kind_name(c.kind)) cell can't be saved in a Literate file. Convert it to a Slate notebook to use one."))
        isempty(_lit_norm(c.source)) || push!(cells, c)
    end
    out = String[]
    prev = nothing                                  # (cell, span or nothing) just written
    for (k, c) in enumerate(cells)
        sp = get(doc.spans, c.id, nothing)
        sp !== nothing && sp.kind !== c.kind && (sp = nothing)
        if k == 1
            append!(out, doc.gaps[1])
        elseif prev[2] !== nothing && sp !== nothing && sp.index == prev[2].index + 1
            append!(out, doc.gaps[sp.index])       # still neighbours: keep what was between them
        else
            append!(out, _lit_sep(prev[1].kind, c.kind))
        end
        append!(out, sp !== nothing && sp.source == _lit_norm(c.source) ? sp.raw : _lit_render(c))
        prev = (c, sp)
    end
    append!(out, doc.gaps[end])
    text = join(out, "\n")
    # Read it back: it has to be the same cells, in order, or the file would say something else.
    nread = 0
    _, newdoc = _lit_read(text, (kind, src, j) -> begin
        c = j <= length(cells) ? cells[j] : nothing
        if c === nothing || c.kind !== kind || _lit_norm(c.source) != _lit_norm(src)
            what = c === nothing ? "an extra cell" : "cell $(c.id)"
            throw(LiterateUnsupported("$(what) doesn't read back the same from Literate source. A code line that starts with `#-` or `#+`, or with a filter and a markdown line (`#md # …`), can't be written in a Literate file."))
        end
        nread = j
        c.id
    end)
    nread == length(cells) || throw(LiterateUnsupported("cells merged when written as Literate source"))
    doc.eol == "\n" || (text = replace(text, "\n" => doc.eol))
    return text, LiterateDoc(newdoc.spans, newdoc.gaps, doc.eol)
end

"""
    read_notebook_source(text; id="r", title="") -> Report

Read a notebook file's text in the dialect it is written in: Literate when it carries no Slate
structure (`is_literate_source`), else Slate's own format.
"""
read_notebook_source(text::AbstractString; id::AbstractString = "r", title::AbstractString = "") =
    is_literate_source(text) ? parse_literate(text; id, title) : parse_report(text; id, title)
