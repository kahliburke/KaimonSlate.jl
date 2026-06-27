#%% md id=intro
# ⏳ Progress reporting

Long-running cells can report progress to the cell's bar + the floating run chip. Several
ways, all ending up in the same meter:

1. **`slate_progress(frac; msg)`** — the lightweight explicit API (a no-op outside Slate).
2. **The standard protocol** — a `progress = frac` log record (what `@logmsg`/ProgressLogging emit).
3. **`@progress for …`** — ProgressLogging's one-line sugar over the protocol.
4. **`@withprogress` / `@logprogress`** — the full API: per-step messages, indeterminate, nested.

Run the cells below and watch the bar. `frac` is `0..1`; `NaN`/`nothing` = indeterminate;
`"done"` closes the bar.

#%% code id=setup
# Precise imports (not `using`) so this cell binds just these names without becoming a
# dependency barrier; every cell below uses them.
import Logging
import ProgressLogging: @progress, @withprogress, @logprogress

#%% md id=h_manual
## 1 · Manual — `slate_progress(frac; msg)`

The lightweight explicit API: a fraction plus a message, on every call. A no-op outside Slate.

#%% code id=manual
for i in 1:50
    slate_progress(i / 50; msg = "step $i / 50")
    sleep(0.04)
end
"done — manual slate_progress"

#%% md id=h_protocol
## 2 · The standard protocol

A `progress = frac` log record at `LogLevel(-1)` IS the wire protocol; Slate consumes it.
Emitted here with stdlib `Logging` — exactly what `@progress`/`@logprogress` produce.

#%% code id=protocol
for i in 1:40
    Logging.@logmsg Logging.LogLevel(-1) "crunching $i" progress = i / 40
    sleep(0.05)
end
Logging.@logmsg Logging.LogLevel(-1) "crunching" progress = "done"
"done — standard Progress log records"

#%% md id=h_macro
## 2b · The `@progress` macro

The ergonomic sugar: wrap any loop and the bar fills automatically — no manual fraction, no
Slate-specific call.

#%% code id=macro
@progress for i in 1:30
    sleep(0.06)
end
"done — @progress macro"

#%% md id=h_withprogress
## 2c · `@withprogress` / `@logprogress` — the full API

`@withprogress` opens a progress scope; `@logprogress` reports into it — with a **per-step
message**, an **indeterminate** phase, or `"done"`. Any control flow, not just a loop.

`@logprogress [name] progress` — one arg is the fraction; two are `name` (message) then fraction.

#%% code id=withprogress
@withprogress name = "training" begin
    for epoch in 1:12
        loss = exp(-epoch / 4)                 # pretend training
        @logprogress "epoch $epoch · loss $(round(loss; digits = 3))" epoch / 12
        sleep(0.15)
    end
end
"done — @withprogress with per-step messages"

#%% md id=h_indeterminate
## 3 · Indeterminate / status-only

`NaN` (or `nothing`) is progress with no known total — a spinner + message. Via the macro
(`@logprogress "msg" NaN`) or the lightweight API (`slate_progress(0; msg=…)`).

#%% code id=indeterminate
@withprogress name = "scanning" begin
    for f in ["alpha", "beta", "gamma", "delta"]
        @logprogress "scanning $f…" NaN        # indeterminate — fraction unknown
        sleep(0.4)
    end
end
"done — indeterminate (NaN)"

#%% code id=status
for i in 1:6
    slate_progress(i / 6; msg = "phase $i / 6")
    sleep(0.3)
end
"done — status updates (slate_progress)"

#%% md id=h_nested
## 4 · Nested scopes

Each `@withprogress` is its own scope (its own id, linked to the parent). In the REPL/VS Code
these render as a tree of bars; in Slate today they **collapse to one bar** (the latest) until
per-id multi-bar rendering lands.

#%% code id=nested
@withprogress name = "outer" begin
    for i in 1:3
        @logprogress "file $i" i / 3
        @withprogress name = "rows of file $i" begin
            for j in 1:5
                @logprogress j / 5
                sleep(0.08)
            end
        end
    end
end
"done — nested @withprogress"

# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   ProgressLogging 0.1.6 33c8b6b6-d38a-422a-b730-caa89a2f386c
# ╚═╡
