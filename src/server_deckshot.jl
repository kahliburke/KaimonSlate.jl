# Part of the NotebookServer submodule — included by server.jl. Names here resolve in NotebookServer.
#
# ── Deck captures: a slide as the audience sees it ────────────────────────────────────────────────
# An agent that builds a deck needs to look at it: whether the text fits beside the figure, whether a
# build step lands, whether a term lights. `deck_shot` opens the notebook in a headless Chrome at
# `?deck=S.K&shot=1` (slides.js: the page presents slide S at step K, clips at their end, controls
# hidden, and marks `<html data-deck-shot="ready">` when it is in) and captures the page.
#
# Chrome is driven over its DevTools protocol on a WebSocket, so nothing beyond HTTP.jl is needed.
# Its own `--screenshot` flag is no use here: it waits on virtual time, which a page holding a live
# WebSocket never lets run out. One browser is started on first use and kept for the hub's life.

const _DECKSHOT_LOCK = ReentrantLock()
const _DECKSHOT_BROWSER = Ref{Any}(nothing)    # (process, port, profile dir)

function _chrome_path()
    p = get(ENV, "KAIMONSLATE_CHROME", "")
    isempty(p) || return isfile(p) ? p : nothing
    for c in ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
              "/Applications/Chromium.app/Contents/MacOS/Chromium",
              raw"C:\Program Files\Google\Chrome\Application\chrome.exe",
              raw"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe")
        isfile(c) && return c
    end
    for c in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome")
        q = Sys.which(c)
        q === nothing || return q
    end
    return nothing
end

# The running browser's DevTools port, starting it if need be.
function _deckshot_browser()
    b = _DECKSHOT_BROWSER[]
    b !== nothing && process_running(b[1]) && return b[2]
    exe = _chrome_path()
    exe === nothing && error("no Chrome or Chromium found (set KAIMONSLATE_CHROME to its executable)")
    prof = mktempdir(; cleanup = true)
    proc = run(pipeline(`$exe --headless=new --remote-debugging-port=0 --user-data-dir=$prof --no-first-run
                         --no-default-browser-check --hide-scrollbars --mute-audio --force-dark-mode about:blank`;
                        stdout = devnull, stderr = devnull); wait = false)
    portfile = joinpath(prof, "DevToolsActivePort")
    t0 = time()
    while !(isfile(portfile) && countlines(portfile) >= 1)
        time() - t0 > 20 && (kill(proc); error("headless Chrome did not start"))
        sleep(0.1)
    end
    port = parse(Int, strip(first(eachline(portfile))))
    _DECKSHOT_BROWSER[] = (proc, port, prof)
    atexit(() -> (try; kill(proc); catch; end))
    return port
end

# One DevTools session on a fresh tab: `call(method, params)` sends a command and returns its result.
function _with_cdp_tab(f, port::Integer)
    tab = JSON.parse(String(HTTP.request("PUT", "http://127.0.0.1:$port/json/new?about:blank").body))
    try
        HTTP.WebSockets.open(tab["webSocketDebuggerUrl"]) do ws
            n = Ref(0)
            call = (method, params = Dict{String,Any}()) -> begin
                id = (n[] += 1)
                HTTP.WebSockets.send(ws, JSON.json(Dict("id" => id, "method" => method, "params" => params)))
                while true
                    msg = JSON.parse(String(HTTP.WebSockets.receive(ws)))
                    get(msg, "id", nothing) == id || continue      # an event, or another reply
                    haskey(msg, "error") && error("DevTools $method: $(msg["error"])")
                    return get(msg, "result", Dict{String,Any}())
                end
            end
            f(call)
        end
    finally
        try; HTTP.request("GET", "http://127.0.0.1:$port/json/close/$(tab["id"])"); catch; end
    end
end

"""
    deck_shot(url; width = 1600, height = 900, timeout = 90) -> (png, position, tex_errors)

A PNG of the page at `url` (a notebook URL with `?deck=S.K&shot=1`, or `?deck=sheet&shot=1` for
the whole deck) once it marks itself ready, the deck's position line (slide and step counts) as the
page shows it, and the messages of any math that failed to typeset. A contact sheet taller than
the window is captured whole.
"""
function deck_shot(url::AbstractString; width::Integer = 1600, height::Integer = 900, timeout::Real = 90)
    lock(_DECKSHOT_LOCK) do
        port = _deckshot_browser()
        _with_cdp_tab(port) do call
            call("Emulation.setDeviceMetricsOverride",
                 Dict("width" => width, "height" => height, "deviceScaleFactor" => 1, "mobile" => false))
            call("Emulation.setEmulatedMedia",
                 Dict("features" => [Dict("name" => "prefers-color-scheme", "value" => "dark")]))
            call("Page.navigate", Dict("url" => String(url)))
            t0 = time()
            while true
                r = call("Runtime.evaluate", Dict("expression" => "document.documentElement.dataset.deckShot || ''",
                                                  "returnByValue" => true))
                get(get(r, "result", Dict()), "value", "") == "ready" && break
                time() - t0 > timeout && error("the slide did not finish loading within $(timeout)s")
                sleep(0.25)
            end
            val(js) = get(get(call("Runtime.evaluate", Dict("expression" => js, "returnByValue" => true)), "result", Dict()), "value", nothing)
            pos = something(val("(document.getElementById('deckpos') || {}).textContent || ''"), "")
            errs = something(val("""[...document.querySelectorAll('#deckstage .katex-error, .deck-sheet .katex-error')]
                                    .map(e => e.getAttribute('title') || e.textContent).slice(0, 12)"""), Any[])
            tall = something(val("document.documentElement.scrollHeight"), height)
            if tall > height
                call("Emulation.setDeviceMetricsOverride",
                     Dict("width" => width, "height" => min(Int(tall), 8000), "deviceScaleFactor" => 1, "mobile" => false))
                sleep(0.5)
            end
            shot = call("Page.captureScreenshot", Dict("format" => "png"))
            return Base64.base64decode(shot["data"]), String(pos), String[string(e) for e in errs]
        end
    end
end
