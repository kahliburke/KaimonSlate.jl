try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=title title
@md"""
# Spectral Methods for the Heat Equation
### A reproducible study
Ada Lovelace · Analytical Engine Lab
"""

#%% md id=bib bibliography
@md"""
@book{knuth1984,
  author = {Donald E. Knuth},
  title  = {The TeXbook},
  year   = {1984},
  publisher = {Addison-Wesley}
}
@article{cooley1965,
  author = {James W. Cooley and John W. Tukey},
  title  = {An algorithm for the machine calculation of complex Fourier series},
  journal = {Mathematics of Computation},
  year   = {1965}
}
"""

#%% md id=prose
@md"""
The fast Fourier transform [@cooley1965] reshaped numerical analysis, and later
treatments [@cooley1965, pp. 297-301] refined the radix-2 case. Typesetting the result
owes much to Knuth [@knuth1984]. As @knuth1984 observes, good notation is half the battle.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = d45569d9-f5e5-4568-8d3b-17fbf5a9f33f
# ╚═╡
