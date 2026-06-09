"""
    ReportEngine

Session-side engine for the notebook-like report builder (see
`PLAN-report-builder.md`). This is the **engine** half of the engine/renderer
split (§15.1): it owns the cell/document model, parsing the Literate-style `.jl`
source, and (later) isolated-module evaluation + dependency inference. It runs
*inside the warm gate session* and depends only on light, session-safe packages.

This first slice implements just the model + parse/serialize round-trip — no
evaluation yet — so it is testable with `Base` alone.
"""
module ReportEngine

export Cell, CellOutput, MimeChunk, BindSpec, Report, CellKind, CellState
export SlateTable, slate_table, SlatePagedTable, slate_query
export MARKDOWN, CODE, FRESH, STALE, RUNNING, ERRORED
export parse_report, serialize_report, source_text

# ── Model ────────────────────────────────────────────────────────────────────

@enum CellKind MARKDOWN CODE
@enum CellState FRESH STALE RUNNING ERRORED   # never-run ≡ STALE

"One representation of a cell's output (MIME-generic display bundle, §7)."
struct MimeChunk
    mime::String                  # "text/html" | "image/png" | "image/svg+xml" | "text/plain"
    data::Vector{UInt8}           # text encoded UTF-8
end

"A reactive input widget bound to a variable (`@bind name Slider(0:100)`, §Layer 3)."
mutable struct BindSpec
    name::Symbol                  # the bound variable
    widget::String                # "slider" | "number" | "checkbox" | "text" | "select"
    params::Dict{String,Any}      # min/max/step/options …
    value::Any                    # current value (assigned into the module)
end

"Captured result of evaluating a code cell."
struct CellOutput
    stdout::String
    display::Vector{MimeChunk}    # richest first
    echarts::Vector{Any}          # raw ECharts option dicts (JSON-encoded server-side)
    tables::Vector{Any}           # raw interactive-table specs (JSON-encoded server-side)
    binds::Vector{BindSpec}       # `@bind` controls this cell declared on its last run
    value_repr::String            # text/plain fallback of the return value
    exception::Union{String,Nothing}
    backtrace::Union{String,Nothing}
    duration_ms::Float64          # wall-clock eval time
end

"""
A single report cell. `id` is the persistent identity (survives edits/moves);
`src_hash` answers "did the source change". Inference/eval fields are populated
later by the dependency + eval passes.
"""
mutable struct Cell
    id::String
    kind::CellKind
    source::String
    src_hash::UInt64
    reads::Set{Symbol}
    writes::Set{Symbol}
    deps::Set{String}             # upstream cell ids (most-recent-writer, §6)
    inputs::Vector{String}        # external-input fingerprints (files)
    state::CellState
    output::Union{CellOutput,Nothing}
    flags::Set{Symbol}            # :volatile :pinned :track :opaque …
    binds::Vector{BindSpec}       # the `@bind` widgets this cell defines (a *control group* if >1)
    controls::Vector{Vector{String}}  # control strip as columns of stacked var names (§Layer 3 UX)
    interp::Vector{CellOutput}    # captured outputs of a markdown cell's `{{ }}` interpolations
end

"Construct a fresh cell, hashing its source and marking it stale (never-run)."
function Cell(id::AbstractString, kind::CellKind, source::AbstractString)
    src = String(source)
    return Cell(String(id), kind, src, hash(src),
                Set{Symbol}(), Set{Symbol}(), Set{String}(), String[],
                STALE, nothing, Set{Symbol}(), BindSpec[], Vector{String}[], CellOutput[])
end

# Markdown variable interpolation: `{{ expr }}` blocks are captured (rich) and
# spliced into the rendered prose; the md cell reads their free variables so it
# re-renders reactively. The scan is brace-balanced and string-aware, so the
# closing `}}` is never confused with braces inside the expression — e.g.
# `Dict(:a=>1)`, `NamedTuple{(:a,)}(…)`, or a LaTeXString `L"\frac{a}{b}"`.
# `_md_template` (template-with-tokens + exprs) is shared by deps (reads) and the
# renderer (substitution), so captures line up positionally.
_interp_token(i::Int) = "xslateinterpx" * string(i; pad = 5) * "x"

function _md_template(src::AbstractString)
    s = String(src); out = IOBuffer(); exprs = String[]
    i = firstindex(s); n = lastindex(s)
    while i <= n
        c = s[i]
        if c == '{' && (i2 = nextind(s, i)) <= n && s[i2] == '{'
            k = nextind(s, i2); depth = 0; instr = false; closeat = 0
            while k <= n
                ck = s[k]
                if instr
                    if ck == '\\'
                        k = nextind(s, k); k <= n && (k = nextind(s, k)); continue
                    end
                    ck == '"' && (instr = false)
                    k = nextind(s, k)
                elseif ck == '"'
                    instr = true; k = nextind(s, k)
                elseif ck == '{'
                    depth += 1; k = nextind(s, k)
                elseif ck == '}'
                    if depth > 0
                        depth -= 1; k = nextind(s, k)
                    else
                        nk = nextind(s, k)
                        (nk <= n && s[nk] == '}') ? (closeat = k; break) : (k = nextind(s, k))
                    end
                else
                    k = nextind(s, k)
                end
            end
            if closeat > 0
                push!(exprs, String(strip(s[nextind(s, i2):prevind(s, closeat)])))
                print(out, _interp_token(length(exprs)))
                i = nextind(s, nextind(s, closeat))
                continue
            end
        end
        print(out, c); i = nextind(s, i)
    end
    return String(take!(out)), exprs
end

_md_interp_exprs(src::AbstractString) = _md_template(src)[2]

mutable struct Report
    id::String
    title::String
    cells::Vector{Cell}
    meta::Dict{String,Any}
    mod::Union{Module,Nothing}    # per-report execution namespace (created on eval)
end

Report(id::AbstractString, title::AbstractString) =
    Report(String(id), String(title), Cell[], Dict{String,Any}(), nothing)

# ── Source format ────────────────────────────────────────────────────────────
#
# Literate-inspired "percent cells". Each cell is introduced by a header line:
#
#     #%% code id=load        ← a code cell with persistent id `load`
#     using Statistics
#     data = [1, 2, 3]
#
#     #%% md id=intro         ← a markdown cell
#     # My Report
#     Narrative **markdown** here.
#
# Header grammar:  `#%%` [ `code` | `md` | `markdown` ] [ `id=<id>` ] [ `controls=<layout>` ]
# - kind defaults to `code` when omitted
# - id is optional; auto-assigned (deterministically, from content) when absent
# - controls is optional and lays out a code cell's control strip as COLUMNS of
#   stacked bound-variable widgets (presentation only). Grammar: top-level commas
#   separate columns (left→right); a `[a,b,…]` group stacks those controls in one
#   column (top→bottom); a bare name is a single-control column. So
#   `controls=[freq,amp],phase` ⇒ col1 stacks freq/amp, col2 is phase. A plain
#   `controls=a,b,c` (no brackets) is three single-control columns — i.e. a row.
# - the cell body is every line until the next header (or EOF)
# - any non-blank content before the first header becomes a leading markdown cell

const _HEADER = r"^#%%(.*)$"

# Parse a `controls=` value into columns of names, respecting `[ ]` groups.
function _parse_controls(s::AbstractString)
    cols = Vector{String}[]
    depth = 0
    buf = IOBuffer()
    toks = String[]
    for ch in s                            # split top-level commas, keeping bracket groups intact
        if ch == '['
            depth += 1
        elseif ch == ']'
            depth -= 1
        elseif ch == ',' && depth == 0
            push!(toks, String(take!(buf))); continue
        end
        print(buf, ch)
    end
    push!(toks, String(take!(buf)))
    for t in toks
        t = strip(t)
        isempty(t) && continue
        if startswith(t, "[") && endswith(t, "]")
            names = String[String(strip(n)) for n in split(t[2:end-1], ',') if !isempty(strip(n))]
            isempty(names) || push!(cols, names)
        else
            push!(cols, String[t])
        end
    end
    return cols
end

"Parse a header line's trailing tokens into (kind, id-or-nothing, controls-columns)."
function _parse_header(rest::AbstractString)
    kind = CODE
    id = nothing
    controls = Vector{String}[]
    for tok in split(strip(rest))
        if startswith(tok, "id=")
            id = tok[4:end]
        elseif startswith(tok, "controls=")
            controls = _parse_controls(tok[10:end])
        elseif tok == "md" || tok == "markdown"
            kind = MARKDOWN
        elseif tok == "code"
            kind = CODE
        end
    end
    return kind, id, controls
end

"Deterministic short id from a cell's content + position (used when none given)."
_auto_id(kind::CellKind, source::AbstractString, idx::Integer) =
    string(hash((kind, source, idx)) % 0xffffff; base = 16, pad = 6)

"Trim a leading and trailing run of blank lines, preserving interior blanks."
function _strip_blank_edges(lines::Vector{<:AbstractString})
    lo = firstindex(lines)
    hi = lastindex(lines)
    while lo <= hi && isempty(strip(lines[lo])); lo += 1; end
    while hi >= lo && isempty(strip(lines[hi])); hi -= 1; end
    return lines[lo:hi]
end

"True for a Literate-style markdown line: `#` alone or `# …` (hash + space)."
_is_md_line(l::AbstractString) = l == "#" || startswith(l, "# ")

"Strip the `# ` / `#` prefix from a Literate markdown line."
_strip_md(l::AbstractString) = l == "#" ? "" : String(l[3:end])

"""
    parse_report(text; id="r", title="") -> Report

Parse hybrid source into a `Report`. Two interchangeable conventions are
accepted — liberal in, canonical out (`serialize_report` always emits the
explicit `#%%` form):

- **Explicit percent cells:** a `#%% [code|md] [id=…]` header introduces a cell
  whose body runs verbatim until the next header.
- **Literate-style (implicit):** before any header, `#`-prefixed lines form a
  markdown cell and bare lines form a code cell; a boundary falls wherever the
  line kind changes.

Pure-Literate files, pure-percent files, and Literate-then-percent mixes all
parse. (Once a `#%%` header appears, subsequent cells should also use headers —
implicit content after a header is taken as that explicit cell's verbatim body.)
"""
function parse_report(text::AbstractString; id::AbstractString = "r", title::AbstractString = "")
    report = Report(id, title)
    lines = split(text, '\n')
    # Split off any Slate footer block (always terminal: the `env` delta and/or a standalone
    # `bundle`) before cell parsing, so their comment lines aren't taken for a markdown cell.
    fi = findfirst(l -> startswith(l, "# ╔═╡ Slate."), lines)
    if fi !== nothing
        env = _parse_env_footer(@view lines[fi:end])   # picks up the Slate.env block if present
        isempty(env) || (report.meta["env"] = env)
        lines = lines[1:(fi - 1)]
    end

    explicit = false                      # inside an explicit #%% cell?
    kind::CellKind = CODE                 # implicit default is code (Literate)
    cid::Union{String,Nothing} = nothing
    ctrls = Vector{String}[]              # `controls=` columns of the current explicit cell
    had_header = false                    # current cell came from an explicit header
    body = String[]

    function flush!()
        trimmed = _strip_blank_edges(body)
        if !isempty(trimmed) || had_header   # keep explicit cells even when empty
            idx = length(report.cells) + 1
            src = join(trimmed, "\n")
            id_ = cid === nothing ? _auto_id(kind, src, idx) : cid
            cell = Cell(id_, kind, src)
            cell.controls = ctrls
            push!(report.cells, cell)
        end
        empty!(body)
        had_header = false
        ctrls = Vector{String}[]
    end

    for line in lines
        m = match(_HEADER, line)
        if m !== nothing                  # explicit header → start a new explicit cell
            flush!()
            kind, cid, ctrls = _parse_header(m.captures[1])
            explicit = true
            had_header = true
        elseif explicit                   # verbatim body of an explicit cell
            push!(body, line)
        elseif isempty(strip(line))       # implicit: blanks ride along (edge-trimmed)
            push!(body, line)
        else                              # implicit: classify; boundary on kind change
            linekind = _is_md_line(line) ? MARKDOWN : CODE
            if !isempty(body) && linekind != kind
                flush!()
                cid = nothing
            end
            kind = linekind
            push!(body, linekind == MARKDOWN ? _strip_md(line) : line)
        end
    end
    flush!()                              # close the final cell
    return report
end

# ── Reproducibility footer ───────────────────────────────────────────────────
#
# The notebook's *delta* — the packages it added beyond its parent project (or all of
# them when detached) — is embedded as an auto-maintained, human-readable footer at the
# end of the `.jl`, so the working file records exactly what extra environment it needs.
# It round-trips through `report.meta["env"]` (a sorted Vector of `{name, version, uuid}`);
# `serialize_report` re-emits it verbatim, so the canonical compare in `sync_from_file!`
# stays stable. The full Project+Manifest+source bundle is a separate on-demand export.
const _ENV_MARK_OPEN = "# ╔═╡ Slate.env"
const _ENV_MARK_CLOSE = "# ╚═╡"

function _render_env_footer(env)::String
    isempty(env) && return ""
    io = IOBuffer()
    println(io, _ENV_MARK_OPEN, " · notebook packages (auto-maintained — manage via the package panel)")
    for p in env
        nm = get(p, "name", ""); isempty(nm) && continue
        println(io, "#   ", nm, " ", get(p, "version", ""), " ", get(p, "uuid", ""))
    end
    print(io, _ENV_MARK_CLOSE)
    return String(take!(io))
end

# Parse the footer's body lines (`#   <name> <version> <uuid>`) back into the sorted
# Vector of dicts. Tolerant of missing version/uuid (older/edited footers).
function _parse_env_footer(lines)::Vector{Dict{String,Any}}
    out = Dict{String,Any}[]
    for l in lines
        startswith(l, _ENV_MARK_OPEN) && continue
        startswith(l, _ENV_MARK_CLOSE) && break
        m = match(r"^#\s+(\S+)(?:\s+(\S+))?(?:\s+(\S+))?\s*$", l)
        m === nothing && continue
        push!(out, Dict{String,Any}("name" => m.captures[1],
                                    "version" => something(m.captures[2], ""),
                                    "uuid" => something(m.captures[3], "")))
    end
    return sort(out; by = p -> p["name"])
end

# ── Serialization ────────────────────────────────────────────────────────────

_kind_token(k::CellKind) = k === MARKDOWN ? "md" : "code"

# Serialize control-strip columns back to the header grammar: single-control
# columns as bare names, multi-control columns as `[a,b,…]`, columns joined by `,`.
_controls_str(cols) = join((length(col) == 1 ? col[1] : "[" * join(col, ",") * "]" for col in cols), ",")

"Emit one cell as a header line plus its body."
function _cell_source(cell::Cell)
    header = "#%% $(_kind_token(cell.kind)) id=$(cell.id)"
    isempty(cell.controls) || (header *= " controls=" * _controls_str(cell.controls))
    return isempty(cell.source) ? header : "$header\n$(cell.source)"
end

"""
    serialize_report(report) -> String

Render a `Report` back to percent-cell source. Round-trips with `parse_report`:
`parse_report(serialize_report(r))` preserves each cell's id, kind, and source.
Cell *outputs* are deliberately not serialized (regenerated by eval) — clean diffs.
"""
# Just the cells (no footer) — the runnable notebook body, shared by `serialize_report`
# and the standalone-bundle export (which appends its own footer instead of the delta one).
serialize_cells(report::Report) = join((_cell_source(c) for c in report.cells), "\n\n") * "\n"

function serialize_report(report::Report)
    body = serialize_cells(report)
    footer = _render_env_footer(get(report.meta, "env", Dict{String,Any}[]))
    return isempty(footer) ? body : body * "\n" * footer * "\n"
end

"Alias kept for callers that think in terms of a cell's raw text."
source_text(cell::Cell) = cell.source

include(joinpath(@__DIR__, "echarts.jl"))   # EChart (used by capture.jl)
include(joinpath(@__DIR__, "tables.jl"))    # SlateTable / slate_table (used by capture.jl)
include(joinpath(@__DIR__, "paged.jl"))     # PagedProvider / SlatePagedTable / slate_query
include(joinpath(@__DIR__, "widgets.jl"))   # shared @bind widgets + namespace contract (engine + worker)
include(joinpath(@__DIR__, "docharvest.jl")) # shared docstring harvest for semantic docs search
include(joinpath(@__DIR__, "capture.jl"))   # shared run_capture (engine + worker)
include(joinpath(@__DIR__, "eval.jl"))
include(joinpath(@__DIR__, "deps.jl"))
include(joinpath(@__DIR__, "bind.jl"))
include(joinpath(@__DIR__, "gate_kernel.jl"))   # GateKernel (used when Main.Kaimon present)

end # module ReportEngine
