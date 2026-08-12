try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Matrix display in Slate

Slate renders any `AbstractMatrix` a cell returns as **whichever form actually reads well** for its
size and structure — you never see a dumped terminal grid. Three forms, picked automatically:

- **Exact KaTeX** `bmatrix` — small matrices (≤ 144 entries), real values, nothing lost.
- **Symbolic dotted notation** — large but *recognised banded* `LinearAlgebra` types
  (`Diagonal` / `Tridiagonal` / `SymTridiagonal` / `Bidiagonal` / triangular): the type guarantees
  the structure, so we describe it like a textbook instead of enumerating a million entries.
- **Downsampled ECharts heatmap** — everything else large, **including sparse**: only the matrix's
  own storage is walked (never the full `nr×nc` grid), block-**max** downsampling so thin lines and
  isolated points survive instead of blurring to grey.

`slate_matrix(M; …)` is the same choice made explicit, with kwargs to override any of it.
"""

#%% code id=setup
using LinearAlgebra, SparseArrays
nothing

#%% md id=s1
@md"""
## 1 · Small dense → exact KaTeX

A small matrix returns as an exact `bmatrix` — real values, rounded to `digits` (default 3).
"""

#%% code id=dense_small
A = [ 1.0   2.0   3.0
      4.0   5.0   6.0
      7.0   8.0  10.0 ]

#%% md id=s2
@md"""
## 2 · Large dense → downsampled heatmap

Past 144 entries a generic matrix becomes a heatmap, block-averaged down to a readable grid and
sized to the **original** aspect ratio (not the downsampled grid's).
"""

#%% code id=dense_big
G = [sin(i / 18) * cos(j / 12) for i in 1:200, j in 1:260] 

#%% md id=s3
@md"""
## 3 · Banded structured types → symbolic dotted notation

For the recognised banded `LinearAlgebra` types the *type itself* tells us the structure. Small ones
still render as exact KaTeX; large ones become symbolic dotted notation — no per-entry enumeration.
"""

#%% code id=banded_small
# 4×4 tridiagonal — small enough to show every entry exactly
Tridiagonal(fill(-1.0, 3), fill(2.0, 4), fill(-1.0, 3))

#%% code id=banded_diag
Diagonal([2.0, 5.0, 11.0, 7.0])

#%% code id=banded_triangular
UpperTriangular([1.0 2.0 3.0; 0.0 4.0 5.0; 0.0 0.0 6.0])

#%% code id=banded_big
# 500×500 SymTridiagonal — too big to enumerate, but its structure is exact, so it reads
# as textbook dotted notation rather than a fuzzy heatmap.
SymTridiagonal(fill(2.0, 500), fill(-1.0, 499))

#%% md id=s4
@md"""
## 4 · Sparse → structure-preserving heatmap

A `SparseMatrixCSC` walks only its stored nonzeros (via the CSC arrays directly — no `findnz`
allocation), and downsamples with block-**max** so a thin band or scattered points stay visible.
"""

#%% code id=sparse_band
# A large banded sparse (1-D Laplacian stencil) — the diagonal band survives downsampling.
n = 2000
S = spdiagm(-1 => fill(-1.0, n - 1), 0 => fill(2.0, n), 1 => fill(-1.0, n - 1))

#%% code id=sparse_random
# Scattered nonzeros (2% density) — block-max keeps isolated points from washing out.
sprand(400, 400, 0.02)

#%% md id=s5
@md"""
## 5 · Explicit `slate_matrix` — overriding the choice

Call `slate_matrix` directly to force a form, crop a sub-region, draw block dividers, or restyle.
"""

#%% code id=ov_force_heatmap
# Force a heatmap on a small matrix that would otherwise be KaTeX
slate_matrix(A; kind = :heatmap)

#%% code id=ov_crop
# Crop one 8×8 tile out of the large dense matrix, then render it exactly
slate_matrix(G; rows = 1:8, cols = 1:8, digits = 2)

#%% code id=ov_blocks
# Block dividers: draw a 4×4 as four 2×2 blocks
M4 = [1.0 2 3 4; 5 6 7 8; 9 10 11 12; 13 14 15 16]
slate_matrix(M4; blockrows = [2, 2], blockcols = [2, 2])

#%% code id=ov_colors
# Custom heatmap ramp (low → high) on the sparse band
slate_matrix(S; colors = ["transparent", "#00e0a0", "#ff5588"])

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = e5d02eec-c08f-4f86-9dc5-d2c429274a36
# ╚═╡
