#%% md id=title title
# Spectral Methods for the Heat Equation
### A reproducible study
Ada Lovelace · Analytical Engine Lab

#%% md id=bib bibliography
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

#%% md id=prose
The fast Fourier transform [@cooley1965] reshaped numerical analysis, and later
treatments [@cooley1965, pp. 297-301] refined the radix-2 case. Typesetting the result
owes much to Knuth [@knuth1984]. As @knuth1984 observes, good notation is half the battle.
