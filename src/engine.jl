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

import JSON   # durable `using`-export cache file (deps.jl)
import Pkg    # in-process package add/remove (eval.jl)
import Serialization   # decode base64'd slate_emit values off the gate stream (gate_kernel.jl)
import Base64

export Cell, CellOutput, MimeChunk, BindSpec, Report, CellKind, CellState
export SlateTable, slate_table, SlatePagedTable, slate_query
export MARKDOWN, CODE, FRESH, STALE, RUNNING, ERRORED
export parse_report, serialize_report, serialize_cells, source_text, cell_definitions
export standalone!

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
    trace::Vector{Any}            # `@trace` rows ({line,name,value}); empty unless cell is traced
    stderr::String                # captured stderr / `@warn` output (shown as a warnings block)
    overflow::Vector{Any}         # full results saved to disk when an output was truncated (kind,path,bytes,clipped)
    animations::Vector{Any}       # animate(…) payloads (manifest + frame/LUT bytes); blob'd server-side
    memo::String                  # durable-cache outcome of this run: "" | "restored" | "stored" | "handle" | "uncacheable"
    memo_why::String              # human reason for a non-caching outcome (handle/uncacheable); "" otherwise
    effects::Vector{Any}          # cell-DECLARED effects harvested this run — (; kind, names, stmt_src, data) per
                                  # `slate_effect(...)` call; drives everywhere classification + the durable effect store
end
# Back-compat constructors (callers that omit trailing fields — trace/stderr through effects — get empty defaults).
CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms) =
    CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, Any[], "", Any[], Any[], "", "", Any[])
CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr) =
    CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, Any[], Any[], "", "", Any[])
CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, overflow) =
    CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, overflow, Any[], "", "", Any[])
CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, overflow, animations) =
    CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, overflow, animations, "", "", Any[])
CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, overflow, animations, memo) =
    CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, overflow, animations, memo, "", Any[])
CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, overflow, animations, memo, memo_why) =
    CellOutput(stdout, display, echarts, tables, binds, value_repr, exception, backtrace, duration_ms, trace, stderr, overflow, animations, memo, memo_why, Any[])

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
    reads_now::Set{Symbol}        # the subset of `reads` made at TOP LEVEL (not deferred into a
                                  # function/macro body) — feeds the `backref` ordering diagnostic;
                                  # never used for edges, so under-approximation is harmless
    writes::Set{Symbol}           # rebindings/definitions ∪ in-place mutations — the full write-set used for
                                  # ordering (most-recent-writer), parallel write-conflicts, and reactive self-trigger
    mutates::Set{Symbol}          # the subset of `writes` reached ONLY via in-place mutation here (x[]=…, x.f=…,
                                  # x .= …, f!(x)) and NOT defined in this cell — excluded from the multi-def
                                  # collision check and the "defines" label (a mutator is not a definer)
    deps::Set{String}             # upstream cell ids (most-recent-writer, §6)
    inputs::Vector{String}        # external-input fingerprints (files)
    state::CellState
    output::Union{CellOutput,Nothing}
    flags::Set{Symbol}            # :volatile :pinned :track :opaque …
    binds::Vector{BindSpec}       # the `@bind` widgets this cell defines (a *control group* if >1)
    controls::Vector{Vector{String}}  # control strip as columns of stacked var names (§Layer 3 UX)
    interp::Vector{CellOutput}    # captured outputs of a markdown cell's `{{ }}` interpolations
    provides::Set{Symbol}         # names brought in by `using`/`import` (⊆ writes) — availability for the
                                  # dep graph, NOT a definition: excluded from the multi-def collision check
end

"Construct a fresh cell, hashing its source and marking it stale (never-run)."
function Cell(id::AbstractString, kind::CellKind, source::AbstractString)
    src = String(source)
    return Cell(String(id), kind, src, hash(src),
                Set{Symbol}(), Set{Symbol}(), Set{Symbol}(), Set{Symbol}(), Set{String}(), String[],
                STALE, nothing, Set{Symbol}(), BindSpec[], Vector{String}[], CellOutput[], Set{Symbol}())
end

# The names a cell DEFINES — its full write-set minus the names it only mutates in place. A mutation
# (`prog[] = …`, `push!(v, …)`) is a write for ordering/reactive purposes but not a definition, so it's
# excluded from the "defines" label and the multi-def collision check. A name both defined AND mutated
# here stays a definition (it isn't in `mutates`). Returns a fresh Set.
cell_definitions(c::Cell) = setdiff(c.writes, c.mutates)

# Markdown `{{ expr }}` interpolation helpers (`_interp_token` / `_md_template` / `_md_interp_exprs`)
# live in `widgets.jl` — the file shared by BOTH ReportEngine (this module) and the standalone
# SlateWorker — because the injected `@md` macro needs them there too. widgets.jl is included below,
# so ReportEngine sees them at call time (all uses are inside function bodies).

mutable struct Report
    id::String
    title::String
    cells::Vector{Cell}
    meta::Dict{String,Any}
    mod::Union{Module,Nothing}    # per-report execution namespace (created on eval)
    # Derived indexes, rebuilt ONLY by `build_dependencies!` (runtime-only, never serialized).
    # Empty ⟺ `deps` are empty too (both are populated by the same pass), so readers stay
    # consistent even on a freshly-parsed report.
    byid::Dict{String,Cell}                  # id → cell
    dependents::Dict{String,Vector{String}}  # transpose of `deps`: id → cells that list it upstream
end

Report(id::AbstractString, title::AbstractString) =
    Report(String(id), String(title), Cell[], Dict{String,Any}(), nothing,
           Dict{String,Cell}(), Dict{String,Vector{String}}())

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

# ── Runnable-notebook skin ─────────────────────────────────────────────────────
# A Slate `.jl` opens with this preamble so `julia notebook.jl` / `include` injects the notebook
# namespace contract (`@bind`, widgets, `echart`, `slate_table`, …) and runs as plain Julia,
# Pluto-style — see `standalone!` (widgets.jl). The Slate engine injects the same contract itself,
# so `parse_report` DROPS a leading preamble line (running it as a cell would double-inject) and
# `standalone!` also self-guards, making a stray re-run a harmless no-op.
#
# The `import` is wrapped so a run in an environment WITHOUT the KaimonSlate package fails with an
# actionable message (how to get the runtime) instead of a bare `Package … not found`. It's its own
# top-level `try` statement, so the world age advances before `standalone!` is called in the next
# statement — the freshly-imported module's methods are visible (the reason `import X; X.f()` works
# at top level but not inside one function).
const _PREAMBLE = "try; import KaimonSlate; catch; error(\"This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\\\"KaimonSlate\\\")`, or open it in Kaimon Slate.\"); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)"
_is_preamble_line(l::AbstractString) = occursin("KaimonSlate", l) && occursin(r"\bstandalone!\s*\(", l)

# A markdown cell serializes its body inside `@md\"\"\"…\"\"\"` so a bare `julia notebook.jl` renders it
# (the injected `@md` macro parses the markdown and evaluates `{{ }}`) instead of choking on prose.
# The engine stores the INNER markdown as `cell.source` and drives its own `{{ }}`/CommonMark pipeline;
# the wrapper is purely the on-disk runnable skin. Old bare-prose markdown cells still read (unwrap is
# a no-op on them). Non-greedy, `.`-matches-newline, tolerant of one wrapper newline on each side.
const _MD_WRAP_RE = r"^@md\"\"\"\n?(.*?)\n?\"\"\"$"s

# Unwrap `@md\"\"\"…\"\"\"` back to bare markdown; any other body is returned unchanged.
function _unwrap_md(src::AbstractString)
    m = match(_MD_WRAP_RE, String(src))
    return m === nothing ? String(src) : String(m.captures[1])
end

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

# Flags Slate manages internally (never written to / read from the header). `:opaque` and
# `:macrocall` are re-derived every eval by dependency inference, so they must never be
# serialized as tags.
const _INTERNAL_FLAGS = Set{Symbol}([:opaque, :macrocall, :using_redundant, :import_scaffold])
# Header tags Slate gives behaviour to (rendered as checkboxes in the UI tag editor). Any OTHER
# token is kept verbatim as a free-form tag — inert metadata that still round-trips.
const _KNOWN_TAGS = (:collapsed, :hidecode, :trace, :nocache, :cache, :resource, :slide, :notes,
                     :title, :abstract, :bibliography, :caption, :home, :docindex)

"Parse a header line's trailing tokens into (kind, id, controls, tags::Vector{Symbol}). Every token
that isn't `id=`/`controls=`/`code`/`md` becomes a tag flag (known ones drive behaviour; the rest are
free-form metadata that round-trips)."
function _parse_header(rest::AbstractString)
    kind = CODE
    id = nothing
    controls = Vector{String}[]
    tags = Symbol[]
    for tok in split(strip(rest))
        if startswith(tok, "id=")
            id = tok[4:end]
        elseif startswith(tok, "controls=")
            controls = _parse_controls(tok[10:end])
        elseif tok == "md" || tok == "markdown"
            kind = MARKDOWN
        elseif tok == "code"
            kind = CODE
        else
            push!(tags, Symbol(tok))        # collapsed | hidecode | trace | nocache | <free-form>
        end
    end
    return kind, id, controls, tags
end

"Deterministic short id from a cell's content + position (used when none given)."
_auto_id(kind::CellKind, source::AbstractString, idx::Integer) =
    string(hash((kind, source, idx)) % 0xffffff; base = 16, pad = 6)

# `_auto_id` truncates to 24 bits — a birthday-bound collision becomes plausible around ~5000
# unnamed cells in one notebook. A silent duplicate id would corrupt every id-keyed lookup
# (dependency graph, history matching, the browser's cell map), so re-salt against `used` (every
# id already assigned in THIS parse, explicit or auto) until unique. The common case (no
# collision) costs one extra Set lookup; only an actual collision pays for a re-hash.
function _unique_auto_id(kind::CellKind, source::AbstractString, idx::Integer, used::AbstractSet{String})
    id = _auto_id(kind, source, idx)
    salt = idx
    while id in used
        salt += 1
        id = string(hash((kind, source, idx, salt)) % 0xffffff; base = 16, pad = 6)
    end
    return id
end

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
        for (k, v) in _parse_config_footer(@view lines[fi:end])   # Slate.config: per-notebook settings
            report.meta[k] = v
        end
        lines = lines[1:(fi - 1)]
    end

    # Drop the standalone preamble (a leading `KaimonSlate.standalone!(…)` line): the engine injects
    # the namespace contract itself, so parsing it as a cell would double-inject. Tolerate leading blanks.
    pi = findfirst(l -> !isempty(strip(l)), lines)
    if pi !== nothing && _is_preamble_line(lines[pi])
        lines = lines[(pi + 1):end]
    end

    explicit = false                      # inside an explicit #%% cell?
    kind::CellKind = CODE                 # implicit default is code (Literate)
    cid::Union{String,Nothing} = nothing
    ctrls = Vector{String}[]              # `controls=` columns of the current explicit cell
    had_header = false                    # current cell came from an explicit header
    body = String[]

    tags = Symbol[]                       # header tag flags of the current explicit cell
    used_ids = Set{String}()              # every id assigned so far this parse (explicit or auto)
    function flush!()
        trimmed = _strip_blank_edges(body)
        if !isempty(trimmed) || had_header   # keep explicit cells even when empty
            idx = length(report.cells) + 1
            src = join(trimmed, "\n")
            kind === MARKDOWN && (src = _unwrap_md(src))   # strip the `@md\"\"\"…\"\"\"` runnable skin, if present
            id_ = cid === nothing ? _unique_auto_id(kind, src, idx, used_ids) : cid
            push!(used_ids, id_)
            cell = Cell(id_, kind, src)
            cell.controls = ctrls
            for t in tags; push!(cell.flags, t); end
            push!(report.cells, cell)
        end
        empty!(body)
        had_header = false
        ctrls = Vector{String}[]
        tags = Symbol[]
    end

    for line in lines
        m = match(_HEADER, line)
        if m !== nothing                  # explicit header → start a new explicit cell
            flush!()
            kind, cid, ctrls, tags = _parse_header(m.captures[1])
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
    inenv = false                                       # only read entries inside the Slate.env block
    for l in lines
        startswith(l, _ENV_MARK_OPEN) && (inenv = true; continue)
        inenv || continue                               # a different Slate.* block (e.g. config) → skip
        startswith(l, _ENV_MARK_CLOSE) && break
        m = match(r"^#\s+(\S+)(?:\s+(\S+))?(?:\s+(\S+))?\s*$", l)
        m === nothing && continue
        push!(out, Dict{String,Any}("name" => m.captures[1],
                                    "version" => something(m.captures[2], ""),
                                    "uuid" => something(m.captures[3], "")))
    end
    return sort(out; by = p -> p["name"])
end

# ── Per-notebook config footer (Slate.config) ────────────────────────────────────────────────────
# Durable per-notebook settings (worker threads, parallel execution) travel with the `.jl` in a small
# human-readable footer — so they survive reopen/restart and move with the file, instead of living only
# in-memory. Round-trips through `report.meta`; `_select_kernel`/`_parallel_enabled` already read meta.
const _CFG_MARK_OPEN = "# ╔═╡ Slate.config"
# Whitelist of durable per-notebook settings, each with a value type so parsing coerces
# correctly (`:bool` | `:string` | `:int`). Slide-deck prefs live here too so a notebook
# carries its presentation style with it. `publishrepo`/`publishslug` remember WHERE this notebook
# was last published (owner/name + slug), so the dialog pre-fills and a CI action can read the
# target — authored intent that travels with the file (see the git-noise/sidecar discussion).
const _CONFIG_KEYS = ("parallel", "threads", "hotreload", "macroexpand", "agentmodel", "runon",
                      "regions",
                      "slidelevel", "slidetransition", "slidetheme", "slideratio", "bibstyle",
                      "publishrepo", "publishslug", "series", "docid")
const _CONFIG_TYPES = Dict("parallel" => :bool, "threads" => :string, "hotreload" => :bool,
                           # `macroexpand` = macro-aware dependency analysis (expand unknown macros in
                           # the kernel to recover their true reads/writes). Off = conservative static
                           # analysis only, for the rare macro with expansion-time side effects.
                           "macroexpand" => :bool,
                           "agentmodel" => :string,
                           # `runon` = this notebook's DURABLE run-location override ("host[,transport]"):
                           # a machine-specific ssh alias the author chose to bake in (the *session* and
                           # *global* run-location layers live in runtime meta / slate.json, never here).
                           "runon" => :string,
                           # `regions` = the comma-separated NAMES of global regions this notebook uses;
                           # `region=<name>`-tagged cells run on that region's worker while the main kernel
                           # stays put, boundary values crossing as CAS blobs. Defs live in the global registry.
                           "regions" => :string,
                           "slidelevel" => :int, "slidetransition" => :string,
                           "slidetheme" => :string, "slideratio" => :string, "bibstyle" => :string,
                           "publishrepo" => :string, "publishslug" => :string, "series" => :string,
                           # `docid` = the notebook's STABLE publish-ledger identity, generated once and
                           # carried in the file so it never flips when the path/repo/origin changes.
                           "docid" => :string)

function _render_config_footer(meta)::String
    items = Tuple{String,String}[]
    for k in _CONFIG_KEYS
        haskey(meta, k) || continue
        v = meta[k]
        sv = v isa Bool ? string(v) : String(string(v))
        isempty(sv) && continue
        push!(items, (k, sv))
    end
    isempty(items) && return ""
    io = IOBuffer()
    println(io, _CFG_MARK_OPEN, " · per-notebook settings (Settings panel)")
    for (k, v) in items; println(io, "#   ", k, " = ", v); end
    print(io, _ENV_MARK_CLOSE)
    return String(take!(io))
end

function _parse_config_footer(lines)::Dict{String,Any}
    out = Dict{String,Any}()
    incfg = false
    for l in lines
        startswith(l, _CFG_MARK_OPEN) && (incfg = true; continue)
        incfg || continue
        startswith(l, _ENV_MARK_CLOSE) && break
        m = match(r"^#\s+(\w+)\s*=\s*(.+?)\s*$", l)
        m === nothing && continue
        k = m.captures[1]; (k in _CONFIG_KEYS) || continue
        v = strip(String(m.captures[2]))
        ty = get(_CONFIG_TYPES, k, :string)
        out[k] = ty === :bool ? (v == "true") :
                 ty === :int  ? something(tryparse(Int, v), nothing) :
                 String(v)
        out[k] === nothing && delete!(out, k)   # drop malformed ints rather than store junk
    end
    return out
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
    # Known tags first (stable order), then any free-form ones (sorted); internal flags never emit.
    for t in _KNOWN_TAGS; (t in cell.flags) && (header *= " " * string(t)); end
    extra = sort!([string(f) for f in cell.flags if !(f in _INTERNAL_FLAGS) && !(f in _KNOWN_TAGS)])
    for t in extra; header *= " " * t; end
    isempty(cell.source) && return header
    body = cell.source
    # Markdown gets the runnable `@md\"\"\"…\"\"\"` skin, EXCEPT when the body itself contains `\"\"\"`
    # (which would break the triple-quoted literal) — that rare cell falls back to the bare form,
    # which still parses in the engine (just not standalone-runnable). `_unwrap_md` reads both.
    cell.kind === MARKDOWN && !occursin("\"\"\"", body) && (body = "@md\"\"\"\n" * body * "\n\"\"\"")
    return "$header\n$body"
end

"""
    serialize_report(report) -> String

Render a `Report` back to percent-cell source. Round-trips with `parse_report`:
`parse_report(serialize_report(r))` preserves each cell's id, kind, and source.
Cell *outputs* are deliberately not serialized (regenerated by eval) — clean diffs.
"""
# Just the cells (no footer) — the runnable notebook body, shared by `serialize_report`
# and the standalone-bundle export (which appends its own footer instead of the delta one).
serialize_cells(report::Report) =
    _PREAMBLE * "\n\n" * join((_cell_source(c) for c in report.cells), "\n\n") * "\n"

function serialize_report(report::Report)
    body = serialize_cells(report)
    # env footer FIRST (parse_env_footer breaks at the first close), then the config footer.
    parts = filter(!isempty, [_render_env_footer(get(report.meta, "env", Dict{String,Any}[])),
                              _render_config_footer(report.meta)])
    isempty(parts) && return body
    return body * "\n" * join(parts, "\n") * "\n"
end

"Alias kept for callers that think in terms of a cell's raw text."
source_text(cell::Cell) = cell.source

include(joinpath(@__DIR__, "echarts.jl"))   # EChart (used by capture.jl)
include(joinpath(@__DIR__, "echarts_dsl.jl")) # echart(:line,…)/series DSL (shared with the worker)
include(joinpath(@__DIR__, "slate_look.jl")) # slate_theme()/use_slate_theme! — shared ECharts/Makie palette
include(joinpath(@__DIR__, "animation.jl")) # animate(frames;…) → Animation (used by capture.jl; shared)
include(joinpath(@__DIR__, "reactive.jl"))  # reactive/@onclick/pause async primitives (shared)
include(joinpath(@__DIR__, "tables.jl"))    # SlateTable / slate_table (used by capture.jl)
include(joinpath(@__DIR__, "slate_matrix.jl")) # slate_matrix — auto-render for AbstractMatrix (used by capture.jl)
include(joinpath(@__DIR__, "trace.jl"))     # @trace / SlateTrace inline value tracing (engine + worker)
include(joinpath(@__DIR__, "paged.jl"))     # PagedProvider / SlatePagedTable / slate_query
include(joinpath(@__DIR__, "widgets.jl"))   # shared @bind widgets + namespace contract (engine + worker)
include(joinpath(@__DIR__, "docharvest.jl")) # shared docstring harvest for semantic docs search
include(joinpath(@__DIR__, "capture.jl"))   # shared run_capture (engine + worker)
include(joinpath(@__DIR__, "format.jl"))    # _format_cell — server-side table cell renderer (JS mirror: fmtCell)
include(joinpath(@__DIR__, "completion.jl")) # shared REPLCompletions (engine + worker)
include(joinpath(@__DIR__, "macroexpand.jl")) # shared cell macro-expansion (engine + worker)
include(joinpath(@__DIR__, "graphics_detect.jl")) # Makie graphics/theme cell detection (deps + scheduler)
include(joinpath(@__DIR__, "eval.jl"))
include(joinpath(@__DIR__, "deps.jl"))
include(joinpath(@__DIR__, "bind.jl"))
include(joinpath(@__DIR__, "gate_kernel.jl"))   # GateKernel (used when Main.Kaimon present)
include(joinpath(@__DIR__, "remote.jl"))        # RunTarget + remote worker (provision/sync/CURVE); uses gate_kernel helpers
include(joinpath(@__DIR__, "peer_mesh.jl"))     # friend-group SSH mesh (introduce/teardown/peer_plan) for the :ssh blob bridge

end # module ReportEngine
