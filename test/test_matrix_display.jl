# How a matrix value renders: the KaTeX, dotted and heatmap forms `slate_matrix` picks between.
using ReTest
using KaimonSlate
using LinearAlgebra
const RE = KaimonSlate.ReportEngine

tex(x) = sprint(show, MIME"text/latex"(), x)

# A CSC-shaped stand-in for a sparse matrix (SparseArrays is not a test dependency). It counts
# reads, so a test can tell storage traversal from an entry-by-entry walk.
mutable struct _CSC <: AbstractMatrix{Float64}
    m::Int; n::Int
    colptr::Vector{Int}; rowval::Vector{Int}; nzval::Vector{Float64}
    reads::Int
end
Base.size(z::_CSC) = (z.m, z.n)
function Base.getindex(z::_CSC, i::Int, j::Int)
    z.reads += 1
    for k in z.colptr[j]:(z.colptr[j+1]-1)
        z.rowval[k] == i && return z.nzval[k]
    end
    return 0.0
end
# n×n with one stored entry, at (1, n).
_corner(n) = _CSC(n, n, vcat(ones(Int, n), [2]), [1], [5.0], 0)

@testset "dotted notation draws the matrix's shape" begin
    t = tex(RE.slate_matrix(Diagonal(fill(2.0, 50))))
    @test occursin("2.0 & 0 & \\cdots & 0", t)
    t = tex(RE.slate_matrix(SymTridiagonal(fill(2.0, 50), fill(-1.0, 49))))
    @test occursin("2.0 & -1.0 & 0 & \\cdots & 0", t) && occursin("-1.0 & 2.0 & -1.0", t)
    t = tex(RE.slate_matrix(Bidiagonal(fill(1.0, 50), fill(3.0, 49), :U)))
    @test occursin("1.0 & 3.0 & 0", t) && occursin("0 & 1.0 & 3.0", t)   # no lower band
    t = tex(RE.slate_matrix(UpperTriangular(ones(50, 50))))
    @test occursin("1.0 & \\ast & \\cdots & \\ast", t) && occursin("0 & \\cdots & 0 & 1.0", t)
    t = tex(RE.slate_matrix(Diagonal(collect(1.0:50.0))))                      # a varying diagonal
    @test occursin("\\ast & 0", t) && !occursin("1.0 &", t)
    @test_throws ArgumentError RE.slate_matrix(ones(30, 30); kind = :dotted)
end

@testset "block dividers default the side not given" begin
    M = reshape(collect(1.0:16.0), 4, 4)
    @test RE.slate_matrix(M; blockrows = [2, 2]) isa RE.BlockMatrixTeX
    @test RE.slate_matrix(M; blockcols = [1, 3]) isa RE.BlockMatrixTeX
    err = try; RE.slate_matrix(M; blockrows = [2, 3]); nothing; catch e; e; end
    @test err isa ArgumentError && occursin("5", err.msg) && occursin("4 rows", err.msg)
end

@testset "a view of a sparse matrix is gridded from its storage" begin
    n = 2000
    for (view, at) in ((A -> A', (n, 1)), (transpose, (n, 1)), (Symmetric, (1, n)), (UpperTriangular, (1, n)))
        A = _corner(n)
        g, gnr, gnc = RE._matrix_grid(view(A); max_cells = 100)
        f = ceil(Int, sqrt(n * n / 100))
        @test A.reads == 0                                   # storage only, no entry-by-entry walk
        @test g[cld(at[1], f), cld(at[2], f)] == 5.0
    end
    S = Symmetric(_corner(n))
    g, _, _ = RE._matrix_grid(S; max_cells = 100)
    @test g[1, end] == 5.0 && g[end, 1] == 5.0              # mirrored
end
