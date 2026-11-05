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

# `keep(i, j)` picks the stored entries a wrapper reads (one triangle for `Symmetric`/triangular).
function _matrix_grid_csc(z; max_cells::Int = 200 * 200, keep = (i, j) -> true)
    nr, nc = size(z)
    factor = ceil(Int, sqrt(nr * nc / max_cells))
    gnr, gnc = cld(nr, factor), cld(nc, factor)
    grid = zeros(Float64, gnr, gnc)
    rv, nzv, cp = z.rowval, z.nzval, z.colptr   # CSC storage directly — no findnz allocation
    for j in 1:nc
        bj = (j - 1) ÷ factor + 1
        for k in cp[j]:(cp[j+1]-1)
            i = rv[k]
            keep(i, j) || continue
            bi = (i - 1) ÷ factor + 1
            v = abs(real(nzv[k]))
            v > grid[bi, bj] && (grid[bi, bj] = v)
        end
    end
    grid, gnr, gnc
end

# A transposed, symmetric or triangular view of a sparse matrix has no storage of its own, and
# indexing it entry by entry walks every structural zero. Grid the parent's storage and lay it out
# the way the view reads it; any other parent takes the generic path.
function _matrix_grid(z::Union{LinearAlgebra.Adjoint,LinearAlgebra.Transpose}; max_cells::Int = 200 * 200)
    p = parent(z)
    (_is_csc_like(p) && length(z) > max_cells) || return invoke(_matrix_grid, Tuple{AbstractMatrix}, z; max_cells)
    g, gnr, gnc = _matrix_grid_csc(p; max_cells)
    return permutedims(g), gnc, gnr
end
function _matrix_grid(z::Union{LinearAlgebra.Symmetric,LinearAlgebra.Hermitian}; max_cells::Int = 200 * 200)
    p = parent(z)
    (_is_csc_like(p) && length(z) > max_cells) || return invoke(_matrix_grid, Tuple{AbstractMatrix}, z; max_cells)
    g, gn, _ = _matrix_grid_csc(p; max_cells, keep = z.uplo == 'U' ? (i, j) -> i <= j : (i, j) -> i >= j)
    return max.(g, permutedims(g)), gn, gn
end
function _matrix_grid(z::Union{LinearAlgebra.UpperTriangular,LinearAlgebra.UnitUpperTriangular,
                               LinearAlgebra.LowerTriangular,LinearAlgebra.UnitLowerTriangular};
                      max_cells::Int = 200 * 200)
    p = parent(z)
    (_is_csc_like(p) && length(z) > max_cells) || return invoke(_matrix_grid, Tuple{AbstractMatrix}, z; max_cells)
    upper = z isa Union{LinearAlgebra.UpperTriangular,LinearAlgebra.UnitUpperTriangular}
    unit = z isa Union{LinearAlgebra.UnitUpperTriangular,LinearAlgebra.UnitLowerTriangular}
    keep = unit ? (upper ? (i, j) -> i < j : (i, j) -> i > j) : (upper ? (i, j) -> i <= j : (i, j) -> i >= j)
    g, gnr, gnc = _matrix_grid_csc(p; max_cells, keep)
    if unit                                   # the unit diagonal is implied, not stored
        f = ceil(Int, sqrt(length(z) / max_cells))
        for i in 1:size(z, 1); b = (i - 1) ÷ f + 1; g[b, b] = max(g[b, b], 1.0); end
    end
    return g, gnr, gnc
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
# Anything with no numeric rounding to apply (a symbolic expression, a unitful quantity, a
# string label) prints as itself rather than throwing a MethodError from inside `show`.
# A type that renders itself better should define `show(io, MIME"text/latex", ::AbstractArray{T})`
# — capture.jl defers to that and never reaches here.
_matrix_texnum(x, digits) = string(x)

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
# Symbolic notation for a large structured matrix, drawn by its shape: `:diagonal`, `:band` (tri- and
# bidiagonal), `:upper` or `:lower` triangular. Each entry label is the band's value when the band is
# constant, `\ast` when it varies, and `0` for a band the type does not have.
struct DottedMatrixTeX
    n::Int
    shape::Symbol
    diag::String
    upper::String
    lower::String
end
function Base.show(io::IO, ::MIME"text/latex", t::DottedMatrixTeX)
    d, u, l = t.diag, t.upper, t.lower
    rows = t.shape === :diagonal ? ["$d & 0 & \\cdots & 0", "0 & $d & \\ddots & \\vdots",
                                    "\\vdots & \\ddots & \\ddots & 0", "0 & \\cdots & 0 & $d"] :
           t.shape === :upper    ? ["$d & $u & \\cdots & $u", "0 & $d & \\ddots & \\vdots",
                                    "\\vdots & \\ddots & \\ddots & $u", "0 & \\cdots & 0 & $d"] :
           t.shape === :lower    ? ["$d & 0 & \\cdots & 0", "$l & $d & \\ddots & \\vdots",
                                    "\\vdots & \\ddots & \\ddots & 0", "$l & \\cdots & $l & $d"] :
                                   ["$d & $u & 0 & \\cdots & 0", "$l & $d & $u & \\ddots & \\vdots",
                                    "0 & $l & \\ddots & \\ddots & 0", "\\vdots & \\ddots & \\ddots & $d & $u",
                                    "0 & \\cdots & 0 & $l & $d"]
    print(io, "\$\$\\begin{bmatrix}", join(rows, " \\\\ "), "\\end{bmatrix}_{", t.n, "\\times", t.n, "}\$\$")
end

# The label for one band: its value when constant, `\ast` when not, `0` when the band is absent.
_band_label(v, digits) = isempty(v) ? "0" :
    all(==(first(v)), v) ? string(round(real(first(v)); digits = digits)) : "\\ast"

function _dotted(M, digits)
    LA = LinearAlgebra
    n = max(size(M)...)
    d = _band_label(LA.diag(M), digits)
    M isa LA.Diagonal && return DottedMatrixTeX(n, :diagonal, d, "0", "0")
    M isa LA.SymTridiagonal && (e = _band_label(M.ev, digits); return DottedMatrixTeX(n, :band, d, e, e))
    M isa LA.Tridiagonal && return DottedMatrixTeX(n, :band, d, _band_label(M.du, digits), _band_label(M.dl, digits))
    if M isa LA.Bidiagonal
        e = _band_label(M.ev, digits)
        return M.uplo == 'U' ? DottedMatrixTeX(n, :band, d, e, "0") : DottedMatrixTeX(n, :band, d, "0", e)
    end
    # A triangle's off-diagonal entries are not stored as a band, and reading them all is O(n²).
    upper = M isa Union{LA.UpperTriangular,LA.UnitUpperTriangular}
    return DottedMatrixTeX(n, upper ? :upper : :lower, d, "\\ast", "\\ast")
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
        (blockrows === nothing && blockcols === nothing) && return MatrixTeX(Mv, digits)
        # One side given: the other is a single block.
        br = blockrows === nothing ? [size(Mv, 1)] : collect(Int, blockrows)
        bc = blockcols === nothing ? [size(Mv, 2)] : collect(Int, blockcols)
        sum(br) == size(Mv, 1) || throw(ArgumentError("slate_matrix: blockrows add up to $(sum(br)), but the matrix has $(size(Mv, 1)) rows"))
        sum(bc) == size(Mv, 2) || throw(ArgumentError("slate_matrix: blockcols add up to $(sum(bc)), but the matrix has $(size(Mv, 2)) columns"))
        return BlockMatrixTeX(Mv, br, bc, digits)
    elseif k === :dotted
        Mv isa _MATRIX_BANDED_TYPES ||
            throw(ArgumentError("slate_matrix: kind=:dotted needs a Diagonal, Bidiagonal, Tridiagonal, SymTridiagonal or triangular matrix, not $(typeof(Mv))"))
        return _dotted(Mv, digits)
    else
        mc = downsample ? max_cells : typemax(Int)
        return _matrix_heatmap(Mv; max_cells = mc, colors = colors)
    end
end
