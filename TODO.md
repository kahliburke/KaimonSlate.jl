- should be able to shut down session/workers, especially from the main notebook view
- autocomplete for opening files, enter should commit to the path in the autocomplete dropdown list and show subpaths, pressing / should commit to a path and show subpaths, enter should not try to open a directory path, should have confirmation if a new file path is written to create a new file, if a new file is created and doesn not have .jl, prompt user about adding the extension (default yes),

- [x] autocomplete should include local variables in scope! — done: cell-local bindings (assignments, for/let/function/generator vars, params) are parsed from the cell and unioned into REPLCompletions (server.jl `_cell_locals`).

