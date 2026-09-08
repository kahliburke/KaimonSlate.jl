# Timeline

Every edit to a notebook is captured to a durable, content-addressed history. Open it from
**☰ → 🕘 History**: scrub back through every checkpoint, diff, restore, or replay the notebook
building itself up from scratch.

## What gets recorded

Each checkpoint stores the full serialized notebook once as a content-addressed, compressed object,
plus a log entry recording only the cells that changed or were removed. That per-cell delta is also
the index behind a cell's own version timeline. Entries are tagged by source:

| Icon | Source |
| --- | --- |
| 👤 | a browser edit |
| 🤖 | an agent edit |
| 📝 | an external edit (VS Code, git) |
| ↩ | a restore |
| 🌱 | the notebook opening |
| · | a periodic auto-draft |

Captures are **deduplicated by content hash**, so a no-op capture is free and the store stays
clean. A low-frequency background snapshot guarantees an at-least-periodic capture even for
changes that slip past the op-level checkpoints.

History is filed under the notebook's **document id**, not its path, so moving or renaming the file
keeps it. The id lives in the `.jl`, which means copying the file gives both copies one history (and
one agent transcript, and one published slot). Slate says so once and offers
**☰ → ⑂ Split from copy…**, which gives this file a fresh id and copies the stores, so neither side
loses anything. See [Publishing](publishing.md#Copying-a-notebook-copies-its-identity).

## Browsing and diffing

The history panel lists checkpoints newest-first. Select one to see a **line diff** against
its parent. The current state is marked; drafts are dimmed.

![The history panel listing checkpoints with source icons, newest first](./assets/history-panel.png)

## Restoring

Restoring is **non-destructive**: the current state is pushed onto the undo stack and the
restore is itself recorded as a new checkpoint, so you can always come straight back.

## Replay — the buildup

Press **▶ Replay** to step through the checkpoints in order, showing each one's diff in the preview
pane, so you can watch the notebook take shape change by change.

Replay only shows. Putting the notebook back into one of those states is the separate
**↩ Restore this version** button.

## Undo / redo

**⌘Z / ⌘⇧Z** step back through source snapshots for quick reversals. Each entry is labelled with the
action it reverses, so the menu reads **↶ Undo cut 3 cells**.

Inside a focused cell editor, ⌘Z first undoes your typing. Once that stack is spent it keeps going,
stepping back through that cell's own recorded versions from the history store. The cell header shows
the age of the version you land on (`↶ 2h ago`, then `· oldest` at the beginning), ⌘⇧Z steps forward
again, and typing commits the version you are on.

That per-cell history is a different axis from restoring: it walks one cell's distinct past sources,
where a restore puts the whole notebook back to a checkpoint.

The stack lives in the hub alongside the open notebook — not in the page — so it **survives a
reload, a closed tab, and a reconnect days later**. You come back to a notebook and pick up where
you left off instead of a blank undo stack. It holds the last 100 steps.

The Timeline is the durable, unbounded counterpart: it outlives the hub, and since undo and restore
are themselves recorded as new checkpoints, nothing you do can lose earlier state.
