# Time Machine

Every edit to a notebook is captured to a durable, content-addressed history — a built-in
"time machine" you open with the **🕘** button.

## What gets recorded

Each checkpoint stores the full serialized notebook plus per-cell digests, tagged by source:

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

## Browsing and diffing

The history panel lists checkpoints newest-first. Select one to see a **line diff** against
its parent. The current state is marked; drafts are dimmed.

## Restoring

Restoring is **non-destructive**: the current state is pushed onto the undo stack and the
restore is itself recorded as a new checkpoint, so you can always come straight back.

## Replay — the buildup

Press **▶ Replay** to step through every checkpoint in order, watching the notebook build
itself up from origin to now. This is both a storytelling tool and the basis for generating
the animated demos in this documentation: a headless browser replays a curated notebook's
history and records it.

## Undo / redo

Separately from the durable history, **⌘Z / ⌘⇧Z** provide in-session undo/redo over source
snapshots for quick reversals (deferring to the editor's own text undo when a cell editor is
focused).
