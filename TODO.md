- [x] shut down session/workers — done: index page lists each session with a ⨯ shutdown button (closes the notebook + kills its worker); notebook view gains a ⟲ Restart worker button (kills + respawns the process, fresh namespace).
- [x] autocomplete for opening files — done: Tab-complete dropdown with ~ resolution; Enter / click / `/` commit a directory and show its subpaths (never opens a dir), Enter opens a file; a new path is confirmed before creation and prompts to add a `.jl` extension (default yes).

- [x] autocomplete should include local variables in scope! — done: cell-local bindings (assignments, for/let/function/generator vars, params) are parsed from the cell and unioned into REPLCompletions (server.jl `_cell_locals`).

