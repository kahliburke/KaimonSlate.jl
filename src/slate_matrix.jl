# ── Matrix display ──────────────────────────────────────────────────────────────────────────
# A bare `AbstractMatrix` returned from a cell auto-renders instead of dumping its terminal
# repr (see capture.jl's `run_capture`): as an exact KaTeX `bmatrix` when it's small enough to
# read, symbolic dotted notation when it's large but a recognized banded LinearAlgebra type
# (the type itself tells us the structure — safe to describe without enumerating every
# entry), or a downsampled ECharts heatmap otherwise (including sparse). `slate_matrix(M; …)`
# is the same choice made explicit, with kwargs to override any of it.

import LinearAlgebra
# SparseArrays is a SOFT dependency (like Tables.jl in tables.jl) — never `import`ed, so a
# notebook that never touches a sparse matrix never pulls it in. `_matrix_grid` detects a CSC
# layout by DUCK-TYPING its `rowval`/`nzval`/`colptr` fields instead of a type check, which
# also covers any CSC-compatible struct, not just `SparseArrays.SparseMatrixCSC`.
_is_csc_like(z) = hasproperty(z, :rowval) && hasproperty(z, :nzval) && hasproperty(z, :colptr)

const _MATRIX_BANDED_TYPES = Union{LinearAlgebra.Diagonal, LinearAlgebra.Bidiagonal,
    LinearAlgebra.Tridiagonal, LinearAlgebra.SymTridiagonal,
    LinearAlgebra.UpperTriangular, LinearAlgebra.LowerTriangular,
    LinearAlgebra.UnitUpperTriangular, LinearAlgebra.UnitLowerTriangular}

# Which of the three forms suits M, by size and (for the named LinearAlgebra structured
# types only — we can't safely infer "regular structure" from an arbitrary matrix) type.
function _matrix_pick_kind(M::AbstractMatrix; katex_cells::Int = 144, banded_dotted_side::Int = 20)
    nr, nc = size(M)
    if M isa _MATRIX_BANDED_TYPES
        return max(nr, nc) <= banded_dotted_side ? :katex : :dotted
    end
    return nr * nc <= katex_cells ? :katex : :heatmap
end

# ── Downsample dispatch: each method walks only the matrix's OWN storage, never the full
# O(nr×nc) grid for a structured/sparse type — see graphics_detect.jl-style single-classifier
# reasoning: a naive generic loop over a SparseMatrixCSC/banded type would touch millions of
# structural zeros for nothing. Block-MAX (not average) for anything with meaningful sparsity/
# thin structure — preserves isolated points and thin lines instead of blurring them into gray
# (the technique SparseArrays.jl's own terminal `spy` display already uses at huge scale).
function _matrix_grid(z::AbstractMatrix; max_cells::Int = 200 * 200)
    nr, nc = size(z)
    nr * nc <= max_cells && return Matrix{Float64}(real.(z)), nr, nc
    _is_csc_like(z) && return _matrix_grid_csc(z; max_cells)
    factor = ceil(Int, sqrt(nr * nc / max_cells))
    gnr, gnc = cld(nr, factor), cld(nc, factor)
    grid = zeros(Float64, gnr, gnc)
    cnt = zeros(Int, gnr, gnc)
    for j in 1:nc, i in 1:nr
        bi, bj = (i - 1) ÷ factor + 1, (j - 1) ÷ factor + 1
        grid[bi, bj] += real(z[i, j])
        cnt[bi, bj] += 1
    end
    grid ./= max.(cnt, 1)
    grid, gnr, gnc
end

function _matrix_grid_csc(z; max_cells::Int = 200 * 200)
    nr, nc = size(z)
    factor = ceil(Int, sqrt(nr * nc / max_cells))
    gnr, gnc = cld(nr, factor), cld(nc, factor)
    grid = zeros(Float64, gnr, gnc)
    rv, nzv, cp = z.rowval, z.nzval, z.colptr   # CSC storage directly — no findnz allocation
    for j in 1:nc
        bj = (j - 1) ÷ factor + 1
        for k in cp[j]:(cp[j+1]-1)
            i = rv[k]
            bi = (i - 1) ÷ factor + 1
            v = abs(real(nzv[k]))
            v > grid[bi, bj] && (grid[bi, bj] = v)
        end
    end
    grid, gnr, gnc
end

function _matrix_grid(z::LinearAlgebra.SymTridiagonal; max_cells::Int = 200 * 200)
    n = size(z, 1)
    n * n <= max_cells && return Matrix{Float64}(real.(z)), n, n
    factor = ceil(Int, sqrt(n * n / max_cells))
    gn = cld(n, factor)
    grid = zeros(Float64, gn, gn)
    for i in 1:n
        bi = (i - 1) ÷ factor + 1
        grid[bi, bi] = max(grid[bi, bi], abs(z.dv[i]))
    end
    for i in 1:n-1
        bi, bj = (i - 1) ÷ factor + 1, i ÷ factor + 1
        v = abs(z.ev[i])
        grid[bi, bj] = max(grid[bi, bj], v)
        grid[bj, bi] = max(grid[bj, bi], v)
    end
    grid, gn, gn
end

# ── Heatmap renderer — no title/axis/legend chrome, box sized to the ORIGINAL matrix's
# aspect ratio (not the downsampled grid's). `colors`' low end defaults to "transparent" so
# zero/empty cells show the page's real background under whatever theme is active, rather
# than a hardcoded hex that could mismatch a non-default theme.
function _matrix_heatmap(z::AbstractMatrix; max_cells::Int = 200 * 200, base_px::Int = 480,
                          colors::Vector{String} = ["transparent", "#569cd6", "#ffd700"])
    grid, gnr, gnc = _matrix_grid(z; max_cells)
    data = [[j - 1, i - 1, grid[i, j]] for i in 1:gnr for j in 1:gnc]
    lo, hi = extrema(grid)
    nr, nc = size(z)
    w, h = nc >= nr ? (base_px, round(Int, base_px * nr / nc)) : (round(Int, base_px * nc / nr), base_px)
    echart(;
        xAxis = (type = "category", data = string.(1:gnc), show = false, splitArea = (show = false,)),
        yAxis = (type = "category", data = string.(1:gnr), show = false, splitArea = (show = false,), inverse = true),
        series = [(type = "heatmap", data = data, itemStyle = (borderWidth = 0,), progressive = 0)],
        visualMap = (min = lo, max = hi, show = false, calculable = false, inRange = (color = colors,)),
        grid = (left = 0, right = 0, top = 0, bottom = 0, containLabel = false),
        width = w, height = h,
    )
end

# ── KaTeX renderers — real values, not a downsample; only for matrices small enough to read. ──
_matrix_texnum(x::Real, digits) = string(round(x; digits = digits))
function _matrix_texnum(x::Complex, digits)
    r, i = round(real(x); digits = digits), round(imag(x); digits = digits)
    i == 0 ? string(r) : string(r, i < 0 ? "-" : "+", abs(i), "i")
end

struct MatrixTeX
    m::AbstractMatrix
    digits::Int
end
function Base.show(io::IO, ::MIME"text/latex", t::MatrixTeX)
    print(io, "\$\$\\begin{bmatrix}")
    nr, nc = size(t.m)
    for i in 1:nr
        print(io, join((_matrix_texnum(t.m[i, j], t.digits) for j in 1:nc), " & "))
        i < nr && print(io, " \\\\ ")
    end
    print(io, "\\end{bmatrix}\$\$")
end

# Block-partitioned form — divider lines at the given row/column block boundaries.
struct BlockMatrixTeX
    m::AbstractMatrix
    blockrows::Vector{Int}
    blockcols::Vector{Int}
    digits::Int
end
function Base.show(io::IO, ::MIME"text/latex", t::BlockMatrixTeX)
    colspec = join([repeat("c", n) for n in t.blockcols], "|")
    print(io, "\$\$\\left[\\begin{array}{", colspec, "}")
    nr, nc = size(t.m)
    rowcuts = Set(cumsum(t.blockrows)[1:end-1])
    for i in 1:nr
        print(io, join((_matrix_texnum(t.m[i, j], t.digits) for j in 1:nc), " & "))
        if i < nr
            print(io, " \\\\ ")
            i in rowcuts && print(io, "\\hline ")
        end
    end
    print(io, "\\end{array}\\right]\$\$")
end

# Symbolic dotted notation for a large-but-regular banded matrix — reads like a textbook,
# no per-entry enumeration. Only meaningful for a matrix whose type already guarantees this
# shape (see `_matrix_pick_kind`).
struct DottedMatrixTeX
    n::Int
    diag::Float64
    offdiag::Float64
end
function Base.show(io::IO, ::MIME"text/latex", t::DottedMatrixTeX)
    d, o = t.diag, t.offdiag
    print(io, "\$\$\\begin{bmatrix}",
        "$d & $o & \\cdots & $o \\\\ ",
        "$o & $d & \\ddots & \\vdots \\\\ ",
        "\\vdots & \\ddots & \\ddots & $o \\\\ ",
        "$o & \\cdots & $o & $d",
        "\\end{bmatrix}_{", t.n, "\\times", t.n, "}\$\$")
end

"""
    slate_matrix(M::AbstractMatrix; kind=:auto, rows=nothing, cols=nothing, max_cells=200*200,
                 downsample=true, colors=["transparent","#569cd6","#ffd700"],
                 blockrows=nothing, blockcols=nothing, digits=3)

Render `M` as whichever form suits its size and structure: an exact KaTeX `bmatrix` (small),
symbolic dotted notation (large + a recognized banded type — `Diagonal`/`Tridiagonal`/
`SymTridiagonal`/`Bidiagonal`/triangular), or a downsampled ECharts heatmap (large + anything
else, including sparse). Any bare `AbstractMatrix` returned from a cell renders this way
automatically; call `slate_matrix` explicitly to override the choice or its defaults.

- `kind` — force `:katex` / `:dotted` / `:heatmap` instead of auto-picking.
- `rows` / `cols` — crop to a sub-region BEFORE rendering (e.g. one tile of a periodic or
  block-repeating large matrix), as ranges.
- `max_cells` — the heatmap's downsample target (default 200×200 cells). `downsample=false`
  forces full resolution — only safe for a matrix that already fits (pair with `rows`/`cols`
  to crop a large one down first; forcing full resolution on a large matrix directly can be
  extremely slow/memory-heavy).
- `colors` — the heatmap's `visualMap` color ramp, low → high.
- `blockrows` / `blockcols` — block sizes for divider lines in the KaTeX form (e.g. `[2,2]`
  for a 4×4 matrix drawn as four 2×2 blocks).
- `digits` — rounding for the KaTeX forms.
"""
function slate_matrix(M::AbstractMatrix;
        kind::Symbol = :auto,
        rows = nothing, cols = nothing,
        max_cells::Int = 200 * 200,
        downsample::Bool = true,
        colors::Vector{String} = ["transparent", "#569cd6", "#ffd700"],
        blockrows = nothing, blockcols = nothing,
        digits::Int = 3)
    Mv = (rows === nothing && cols === nothing) ? M :
         M[something(rows, 1:size(M, 1)), something(cols, 1:size(M, 2))]
    k = kind === :auto ? _matrix_pick_kind(Mv) : kind
    if k === :katex
        return blockrows === nothing ? MatrixTeX(Mv, digits) : BlockMatrixTeX(Mv, blockrows, blockcols, digits)
    elseif k === :dotted
        d = Mv isa Union{LinearAlgebra.Diagonal,LinearAlgebra.Bidiagonal,LinearAlgebra.Tridiagonal,LinearAlgebra.SymTridiagonal} ?
            first(LinearAlgebra.diag(Mv)) : Mv[1, 1]
        o = Mv isa LinearAlgebra.SymTridiagonal ? (isempty(Mv.ev) ? 0.0 : first(Mv.ev)) :
            Mv isa LinearAlgebra.Tridiagonal ? (isempty(Mv.du) ? 0.0 : first(Mv.du)) : 0.0
        return DottedMatrixTeX(max(size(Mv)...), round(real(d); digits = digits), round(real(o); digits = digits))
    else
        mc = downsample ? max_cells : typemax(Int)
        return _matrix_heatmap(Mv; max_cells = mc, colors = colors)
    end
end
