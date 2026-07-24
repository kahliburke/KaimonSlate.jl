#!/usr/bin/env julia
# Dev helper: start an ISOLATED KaimonSlate hub for THIS worktree.
#
# It gets its own state home + port and does NOT register as a Kaimon extension — so several worktree
# hubs (and the installed extension) can run side by side without ever touching each other's prefs,
# secrets, publish ledger, or site-build cache. This is the same isolation `run.jl` uses for a
# standalone notebook; here it's keyed to the worktree instead of a notebook folder.
#
# Usage:
#   julia --project=. dev/hub.jl [notebook.jl]
#
# Env (all optional):
#   KAIMONSLATE_PORT=8901    pin the port                 (default: a free one, printed on start)
#   KAIMONSLATE_HOME=<dir>   pin the state home           (default: <worktree>/.kaimonslate-dev)
#   KAIMONSLATE_NO_OPEN=1    don't open a browser
using Sockets

# Isolation is set BEFORE `using KaimonSlate` so the package's __init__ and config load read the right
# home + port. An explicit KAIMONSLATE_HOME / KAIMONSLATE_CONFIG_HOME still wins.
const ROOT = dirname(@__DIR__)                       # worktree root (this script lives in <root>/dev/)
if get(ENV, "KAIMONSLATE_HOME", "") == "" && get(ENV, "KAIMONSLATE_CONFIG_HOME", "") == ""
    ENV["KAIMONSLATE_HOME"] = joinpath(ROOT, ".kaimonslate-dev")
end
ENV["KAIMONSLATE_NO_AUTOREGISTER"] = "1"             # never fight over the shared extensions.json
if get(ENV, "KAIMONSLATE_PORT", "") == ""
    s = Sockets.listen(Sockets.localhost, 0); ENV["KAIMONSLATE_PORT"] = string(Int(Sockets.getsockname(s)[2])); close(s)
end
const PORT = parse(Int, ENV["KAIMONSLATE_PORT"])

using KaimonSlate
const NS = KaimonSlate.NotebookServer
const SH = KaimonSlate.SlateHome

SH.ensure_homes!()                                   # mkpath the isolated homes
KaimonSlate._load_slate_config!()                    # honor this home's slate.json (worker threads, parallel, run-location)
const HUB = NS.start_hub(; port = PORT)
KaimonSlate._HUB[] = HUB                             # let the gate tools / `slate` app see this hub too
atexit(() -> (try; NS.stop_hub(HUB); catch; end))

const URL = "http://127.0.0.1:$PORT"
println("""
┌ KaimonSlate DEV hub (isolated — not registered as an extension)
│  worktree : $ROOT
│  state    : config=$(SH.config_home())
│             data=$(SH.data_home())  cache=$(SH.cache_home())
│  url      : $URL
└  Ctrl-C to stop.
""")
flush(stdout)

let open = get(ENV, "KAIMONSLATE_NO_OPEN", "") != "1"
    if !isempty(ARGS)                                # open the notebook passed as arg1 (created if missing)
        path = abspath(expanduser(ARGS[1]))
        isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
        nburl = "$URL/n/$(NS.open_notebook!(HUB, path))"
        println("→ opened $(basename(path)) at $nburl"); flush(stdout)
        open && NS._open_in_browser(nburl)
    elseif open
        NS._open_in_browser(URL)                     # else land on the front page
    end
end

while true; sleep(3600); end                         # serve until interrupted (atexit stops the hub)
