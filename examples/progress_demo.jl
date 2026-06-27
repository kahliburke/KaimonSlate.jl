#%% md id=intro
# ⏳ Progress reporting

Long-running cells can report progress to the cell meter + the floating run chip. Two ways,
both ending up in the same place:

1. **`slate_progress(frac; msg)`** — the lightweight explicit API (a no-op outside Slate).
2. **The Julia-standard progress protocol** — a log record carrying `progress = frac`
   (this is exactly what `ProgressLogging`'s `@progress` macro emits). Slate consumes it,
   so a plain `@progress for …` loop drives the meter with **no progress-specific API at all**.

Run the cells below and watch the run chip's bar.

#%% md id=h_manual
## 1 · Manual — `slate_progress(frac; msg)`

#%% code id=manual
for i in 1:50 
    slate_progress(i / 50; msg = "step $i / 50")
    sleep(0.04)
end
"done — manual slate_progress"

#%% md id=h_protocol
## 2 · The standard protocol (zero progress API)

A `progress = frac` log record at `LogLevel(-1)` IS the wire protocol. We emit it here with
stdlib `Logging` so the demo needs no extra package — but `using ProgressLogging; @progress
for …` produces the identical records (and would render a bar in the REPL/VS Code too).

#%% code id=protocol
import Logging
for i in 1:40
    Logging.@logmsg Logging.LogLevel(-1) "crunching" progress = i / 40
    sleep(0.05) 
end
Logging.@logmsg Logging.LogLevel(-1) "crunching" progress = "done"
"done — standard Progress log records (what @progress emits)"

#%% md id=h_macro
## 2b · The `@progress` macro (ProgressLogging)

The ergonomic form: wrap any loop in `@progress` and the bar fills automatically — no manual
fraction, no Slate-specific call. It emits the same records as cell 2; Slate just consumes them.

#%% code id=macro
using ProgressLogging
@progress for i in 1:30
    sleep(0.06)
end
"done — @progress macro"

#%% md id=h_indeterminate
## 3 · Indeterminate / status-only

`progress = nothing` (or `slate_progress(0; msg=…)`) is a status update without a known
fraction — useful while you don't yet know the total work.

#%% code id=status
for i in 1:6 
    slate_progress(i / 6; msg = "phase $i / 6")
    sleep(0.3)
end
"done — status updates"

# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   ProgressLogging 0.1.6 33c8b6b6-d38a-422a-b730-caa89a2f386c
# ╚═╡
