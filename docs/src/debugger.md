# Debugging a Cell

A code cell can be stepped through line by line, on this machine or on a region's worker. Click
**🐞** in the cell's header, or pick **Debug the selected cell** in the command palette. What is
stepped is the cell's current text in the editor, even unsaved. Clicking 🐞 again on the same cell
ends the session.

The session opens a workspace over the notebook: the source with the current line marked, a rail
with the call stack, breakpoints and watches, the variables, and a scratchpad. **Esc** closes the
workspace and leaves the session running, shown as a ribbon under the cell with where it stopped,
how many steps it has taken and a **⤢** to reopen it.

![The debugging workspace stopped at a breakpoint: source with the current line, the rail with the call stack and breakpoints, the variables, and the scratchpad](./assets/debugger-workspace.png)

## Stepping

| Button | Key | What it does |
| --- | --- | --- |
| ⤷ Next | F10 | Runs to the next line in this frame. |
| ⤓ Into | F11 | Steps into a call on this line. With more than one, a list asks which. |
| ⤒ Out | ⇧F11 | Finishes this call and stops at the caller. At the cell's top level, finishes the statement. |
| ▶▶ Continue | F5 | Runs to the next breakpoint, or to the end. |
| ▶\| Skip | | At a breakpoint: disables it and continues. |
| ■ Stop | ⇧F5 | Ends the session. |

The keys work only while a session is running, so F5 still reloads the page otherwise. They can be
rebound in **Keyboard shortcuts**.

![Into on a line that calls two functions of the notebook's own: the list asks which one to step into](./assets/debugger-into.png)

Your own code is interpreted, so it can be stepped: the notebook's cells and packages you develop
from a local checkout. Base, the standard libraries and registered packages run compiled, at full
speed, and Into passes over their calls and says so. Turn on **step into library code** to be
offered them as well. Picking one interprets that whole module from then on, which is slower; the
rail lists what is being interpreted, and **✕** on a module goes back to running it compiled.

A single step stops after 500 interpreter steps rather than run on indefinitely, and there is no
run-to-line: set a breakpoint and continue instead.

## Breakpoints

Click in the gutter of a cell's editor, or press **F9** on a line, to set a breakpoint. They can be
set before a session starts, which is the usual order: mark the line, then start. A line in a
package works the same way from the workspace's source view.

The rail lists every breakpoint. **●**/**○** enables or disables one without clearing it, **when**
gives it a condition, and **✕** clears it. A condition is a Julia expression evaluated in the
frame each time the line runs; the breakpoint stops only when it is `true`. A condition that does
not parse is refused when you set it. Breakpoints are kept by the hub for as long as it runs. They
are not saved in the notebook.

## Looking around

- **The call stack** lists the frames, current first. Click a caller to look at it; **▸ back to
  current** returns.
- **Variables** shows the frame's locals and the cell's bindings, each with its type and a short
  value. A binding still holding its value from the previous run is dimmed until this run assigns
  it. Values that changed with the last step flash.
- **The scratchpad** evaluates Julia in the paused frame, with completion that offers the frame's
  locals first. ↑ and ↓ recall what you typed before. An evaluation can change state, as it would
  at a REPL.

## Watches

A **watch** samples an expression every time a line runs, without stopping there. Add one with
**+** in the rail's watches at the current line. Each row shows the latest value; click it to plot
every sample so far, which is how a value's behaviour over a long loop is seen. A watch keeps up to
200,000 samples.

![A watch on u opened in the rail: every sample over the loop plotted against evaluation count, with its range and the latest value](./assets/debugger-watch.png)

A **live view** re-evaluates an expression, or renders another cell's output, after every step, as
a tile beside the source.

## Cells on a region

A cell tagged for a region is stepped on that region's worker, and the workspace shows where. A
region with no allocation yet waits for one first.

## Sessions and agents

There is one session per notebook. Anyone with the notebook open can step it. Ending or replacing
a session someone else started asks them first, with **Allow** or **Keep it**.

The agent can debug through its `dbg_start`, `dbg_step`, `dbg_frame`, `dbg_eval`, `dbg_break` and
`dbg_watch` tools. When **Settings → Specialists → Only the debug specialist may step code** is on,
stepping is left to a debugging specialist the agent brings in, and the workspace shows who is
driving.
