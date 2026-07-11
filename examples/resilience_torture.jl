#%% md id=title title
# Resilience Torture Test
#
# A notebook that gets itself into trouble on purpose — to exercise the eval-level self-healing
# (run supervisor + watchdog). **Every control is OFF/0 by default, so opening this is safe.** Flip
# one at a time and watch how the system detects and recovers.

#%% md id=intro
# ## What each control does
# - **cooperative stall** — a cancellable `sleep`. Tests *slow-but-alive* (heartbeat keeps flowing)
#   and `cancel_eval`. Restart the worker mid-sleep to test **orphan reconciliation**.
# - **tight-loop hang** — an *uncancellable* `while true`. Only **⟲ Restart worker** recovers it;
#   the supervisor then resets the orphaned `RUNNING` cell to stale on its own.
# - **memory runaway** — allocate + hold N GB → RSS balloon (watchdog runaway signal).
# - **exception** — surfaces an error.
# - **kill worker** — hard process exit → worker death → reconnect/respawn + reconciliation.

#%% code id=diag
# Quick in-notebook diagnostics: this worker's pid + peak RSS (Sys.maxrss is cross-platform; on
# slate-remote the 2s telemetry sampler also streams live cpu/rss from /proc).
"pid $(getpid()) · peak RSS $(round(Sys.maxrss() / 1024^3; digits = 2)) GB · threads $(Threads.nthreads())"

#%% code id=stall_ctl
@bind stall_secs Slider(0, 300, 0; step = 10, label = "cooperative stall (s)")

#%% code id=stall nocache
# Cancellable — the watchdog should see a live heartbeat and NOT flag it; cancel_eval stops it;
# restarting the worker mid-sleep leaves it orphaned for the supervisor to reset.
stall_secs > 0 && sleep(stall_secs)
"slept $(stall_secs)s"

#%% code id=hang_ctl
@bind hang Toggle(false; label = "UNCANCELLABLE tight-loop hang")

#%% code id=hang nocache
# ⚠ No yield point → InterruptException can't land. The ONLY recovery is ⟲ Restart worker, after
# which the supervisor resets this cell (left RUNNING with no kernel evaluating it) back to stale.
hang && (while true; end)
"not hanging"

#%% code id=alloc_ctl
@bind alloc_gb Slider(0, 16, 0; step = 1, label = "memory runaway (GB)")

#%% code id=runaway nocache
# Allocate + HOLD `alloc_gb` GB (kept in a binding so GC can't reclaim it) → the worker's RSS
# balloons, which the watchdog reads as a runaway. Keep it modest — a big value can OOM the box.
hog = alloc_gb > 0 ? fill(0x01, alloc_gb * 1024^3) : UInt8[]
"holding $(round(length(hog) / 1024^3; digits = 2)) GB"

#%% code id=boom_ctl
@bind boom Toggle(false; label = "throw an exception")

#%% code id=boom nocache
boom && error("intentional boom — testing error surfacing")
"no error"

#%% code id=crash_ctl
@bind crash Toggle(false; label = "KILL the worker process")

#%% code id=crash nocache
# Hard process exit → the worker dies under the hub. Tests reconnect/respawn + reconciliation of
# anything left RUNNING. Watch the worker log for the exit and the notebook for auto-recovery.
crash && (flush(stdout); ccall(:exit, Cvoid, (Cint,), 1))
"alive"
