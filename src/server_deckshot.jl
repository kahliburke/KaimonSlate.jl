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

# Where a Chrome-family browser is installed, in the order they are tried. Any of them drives the
# same way over the DevTools protocol.
const _MAC_BROWSERS = ("Google Chrome", "Chromium", "Microsoft Edge", "Brave Browser",
                       "Google Chrome Beta", "Google Chrome Canary")
const _WIN_BROWSERS = (joinpath("Google", "Chrome", "Application", "chrome.exe"),
                       joinpath("Microsoft", "Edge", "Application", "msedge.exe"),
                       joinpath("BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
                       joinpath("Chromium", "Application", "chrome.exe"))
const _PATH_BROWSERS = ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome",
                        "microsoft-edge", "microsoft-edge-stable", "msedge", "brave-browser")

function _browser_files()
    out = String[]
    for dir in ("/Applications", joinpath(homedir(), "Applications")), app in _MAC_BROWSERS
        push!(out, joinpath(dir, app * ".app", "Contents", "MacOS", app))
    end
    for var in ("PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA")
        root = get(ENV, var, "")
        isempty(root) && continue
        append!(out, joinpath(root, rel) for rel in _WIN_BROWSERS)
    end
    return out
end

"""
    chrome_status() -> (; path, problem)

The browser the deck captures, prints and videos use: `KAIMONSLATE_CHROME` if it is set, else the
first Chrome, Chromium, Edge or Brave found in the usual install places or on the PATH. `path` is
`nothing` when there is none, and `problem` then says why, naming a `KAIMONSLATE_CHROME` that points
at no file.
"""
function chrome_status()
    p = get(ENV, "KAIMONSLATE_CHROME", "")
    if !isempty(p)
        isfile(p) && return (path = p, problem = "")
        return (path = nothing, problem = "KAIMONSLATE_CHROME is set to $p, which does not exist")
    end
    for c in _browser_files()
        isfile(c) && return (path = c, problem = "")
    end
    for c in _PATH_BROWSERS
        q = Sys.which(c)
        q === nothing || return (path = q, problem = "")
    end
    return (path = nothing, problem = "no Chrome, Chromium, Edge or Brave on the hub's machine " *
                                      "(set KAIMONSLATE_CHROME to one)")
end

# The status a page shows, looked up again at most once a minute: the notebook state carries it on
# every push, and a browser installed while the hub runs is found within the minute.
const _CHROME_SEEN = Ref{Any}((0.0, nothing))
function chrome_status_cached(; ttl::Real = 60)
    t, s = _CHROME_SEEN[]
    if s === nothing || time() - t > ttl
        s = chrome_status()
        _CHROME_SEEN[] = (time(), s)
    end
    return s
end

# The running browser's DevTools port, starting it if need be.
function _deckshot_browser()
    b = _DECKSHOT_BROWSER[]
    b !== nothing && process_running(b[1]) && return b[2]
    st = chrome_status()
    st.path === nothing && error(st.problem)
    exe = st.path
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
# A reader task takes every message off the socket as it arrives, handing replies to the call that
# waits on them and events to `on_event(msg, send)`, so an event that must be answered at once (a
# screencast frame's ack, which paces the next frame) never waits behind a command.
function _with_cdp_tab(f, port::Integer; on_event = nothing, timeout::Real = 120)
    tab = JSON.parse(String(HTTP.request("PUT", "http://127.0.0.1:$port/json/new?about:blank").body))
    try
        HTTP.WebSockets.open(tab["webSocketDebuggerUrl"]) do ws
            n = Ref(0); lk = ReentrantLock(); wl = ReentrantLock()
            waiting = Dict{Int,Channel{Any}}()
            send = (method, params = Dict{String,Any}(); ch = nothing) -> begin
                id = lock(lk) do
                    i = (n[] += 1); ch === nothing || (waiting[i] = ch); i
                end
                lock(() -> HTTP.WebSockets.send(ws, JSON.json(Dict("id" => id, "method" => method, "params" => params))), wl)
                id
            end
            reader = @async try
                for raw in ws
                    msg = JSON.parse(String(raw))
                    id = get(msg, "id", nothing)
                    if id === nothing
                        on_event === nothing || on_event(msg, send)
                    else
                        ch = lock(() -> pop!(waiting, id, nothing), lk)
                        ch === nothing || put!(ch, msg)
                    end
                end
            catch
            end
            call = (method, params = Dict{String,Any}()) -> begin
                ch = Channel{Any}(1)
                send(method, params; ch)
                t = Timer(_ -> close(ch), timeout)
                msg = try
                    take!(ch)
                catch
                    error("DevTools $method: no reply within $(timeout)s")
                finally
                    close(t)
                end
                haskey(msg, "error") && error("DevTools $method: $(msg["error"])")
                get(msg, "result", Dict{String,Any}())
            end
            f(call)
        end
    finally
        try; HTTP.request("GET", "http://127.0.0.1:$port/json/close/$(tab["id"])"); catch; end
    end
end

_cdp_value(call, js) = get(get(call("Runtime.evaluate", Dict("expression" => js, "returnByValue" => true)), "result", Dict()), "value", nothing)

# Open `url` in the tab at the given size, dark, and wait for the page's `data-deck-shot="ready"` mark.
function _cdp_open_deck(call, url, width, height, timeout)
    call("Emulation.setDeviceMetricsOverride",
         Dict("width" => width, "height" => height, "deviceScaleFactor" => 1, "mobile" => false))
    call("Emulation.setEmulatedMedia", Dict("features" => [Dict("name" => "prefers-color-scheme", "value" => "dark")]))
    call("Page.navigate", Dict("url" => String(url)))
    t0 = time()
    while _cdp_value(call, "document.documentElement.dataset.deckShot || ''") != "ready"
        time() - t0 > timeout && error("the deck did not finish loading within $(timeout)s")
        sleep(0.25)
    end
end

# The query part that paints a captured page in Slate palette `theme` (notebook.html reads
# `?slatetheme=`). The headless browser has a fresh profile with no saved theme, so without it every
# capture is in the default palette, whatever the author works in. "" or a malformed name: default.
_slatetheme_qs(theme::AbstractString) = occursin(r"^[a-z0-9-]{1,32}$", theme) ? "&slatetheme=$theme" : ""

# The slide canvas in pixels for a notebook's `slideratio`, as the deck draws it (`_canvasSize` in
# slides.js). A video is recorded at this size, so it has no bars at the deck's own ratio.
deck_canvas(ratio::AbstractString) = ratio == "4:3" ? (1440, 1080) : ratio == "16:10" ? (1920, 1200) : (1920, 1080)

# The page `deck_pdf` prints for notebook `id` on the hub at `base`: every slide at its last step, or
# with `steps = "all"` a page for each step of each slide, in Slate palette `theme`.
deck_print_url(base::AbstractString, id::AbstractString; theme::AbstractString = "", steps::AbstractString = "") =
    string(base, "/n/", id, "?deck=print&shot=1", steps == "all" ? "&steps=all" : "", _slatetheme_qs(theme))

"""
    deck_shot(url; width = 1600, height = 900, timeout = 90) -> (png, position, tex_errors)

A PNG of the page at `url` (a notebook URL with `?deck=S.K&shot=1`, or `?deck=sheet&shot=1` for
the whole deck) once it marks itself ready, the deck's position line (slide and step counts) as the
page shows it, and the messages of any math that failed to typeset. A contact sheet taller than
the window is captured whole.
"""
function deck_shot(url::AbstractString; width::Integer = 1600, height::Integer = 900, timeout::Real = 90)
    lock(_DECKSHOT_LOCK) do
        _with_cdp_tab(_deckshot_browser()) do call
            _cdp_open_deck(call, url, width, height, timeout)
            val(js) = _cdp_value(call, js)
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

"""
    deck_pdf(url; timeout = 120) -> Vector{UInt8}

A PDF of the deck at `url` (from `deck_print_url`) as the audience sees it: one page per slide at its
last step, or per step of each slide, each the slide's own size. Text and SVG stay vector; a chart is
the snapshot the deck shows.
"""
function deck_pdf(url::AbstractString; timeout::Real = 120)
    lock(_DECKSHOT_LOCK) do
        _with_cdp_tab(_deckshot_browser(); timeout) do call
            _cdp_open_deck(call, url, 1920, 1080, timeout)
            # Read back as a stream in chunks: in one reply, a large PDF's base64 would pass the
            # WebSocket's frame limit (16 MiB in HTTP.jl) and the socket would close.
            h = call("Page.printToPDF", Dict("preferCSSPageSize" => true, "printBackground" => true,
                                             "transferMode" => "ReturnAsStream"))["stream"]
            io = IOBuffer()
            while true
                r = call("IO.read", Dict("handle" => h, "size" => 4 * 1024 * 1024))
                d = r["data"]
                write(io, get(r, "base64Encoded", false) === true ? Base64.base64decode(d) : codeunits(d))
                get(r, "eof", false) === true && break
            end
            call("IO.close", Dict("handle" => h))
            return take!(io)
        end
    end
end

# ── Rendering the whole deck to a video ───────────────────────────────────────────────────────────
# The deck is stepped through once in the headless browser while its screencast records every frame
# that changes. Only the motion is recorded in real time (a transition, a build, a figure's clip);
# each step's last frame is then held for its share of the video's length, so a ten-minute video
# takes about as long to make as its moving parts take to play. The length is shared out by weight:
# a step's rehearsed time when it has one, else a reading time from the words it brings in, scaled
# so the steps fill the length; no step is shorter than its own motion.

const _RENDER_SETTLE_S = 0.35     # a beat after a step's motion before the next one
const _DECK_RENDERS = Dict{String,Dict{String,Any}}()
const _DECK_RENDER_LOCK = ReentrantLock()

# Seconds a step wants on screen when it has no rehearsed time: a base, the words it brings in, more
# for a new slide (taking in its layout) and for a figure that changes (looking at it).
_reading_time(st) = 1.2 + 0.3 * Float64(get(st, "words", 0)) + (get(st, "step", 0) == 0 ? 1.0 : 0.0) +
                    (get(st, "figure", false) === true ? 2.0 : 0.0)

"""
    deck_hold_times(steps, seconds) -> Vector{Float64}

How long each step stays on screen in a video `seconds` long: at least its motion (`t1 - t0`) and a
beat, otherwise in proportion to its weight (rehearsed `timing`, else reading time). Errors when the
motion alone is longer than `seconds`.
"""
function deck_hold_times(steps, seconds::Real)
    m = [max(0.0, Float64(st["t1"]) - Float64(st["t0"])) + _RENDER_SETTLE_S for st in steps]
    w = [(t = get(st, "timing", nothing); t isa Real && t > 0 ? Float64(t) : _reading_time(st)) for st in steps]
    sum(m) > seconds && error("the deck's transitions and clips alone take $(round(sum(m); digits = 1)) s; " *
                              "give it at least that long")
    total(k) = sum(max(m[i], k * w[i]) for i in eachindex(m))
    lo, hi = 0.0, seconds / minimum(w)
    for _ in 1:100
        mid = (lo + hi) / 2
        total(mid) < seconds ? (lo = mid) : (hi = mid)
    end
    return [max(m[i], hi * w[i]) for i in eachindex(m)]
end

"""
    deck_render(url, out; seconds, fps = 30, width = 1920, height = 1080, progress = msg -> nothing)

Render the deck at `url` (a notebook URL with `?deck=1.0&render=1`) to an MP4 at `out`, `seconds`
long, with a WebVTT chapter per slide beside it. Needs `ffmpeg` on the PATH.
"""
function deck_render(url::AbstractString, out::AbstractString; seconds::Real, fps::Integer = 30,
                     width::Integer = 1920, height::Integer = 1080, progress = msg -> nothing)
    ff = Sys.which("ffmpeg")
    ff === nothing && error("rendering a video needs ffmpeg on the PATH")
    frames = Tuple{Float64,Vector{UInt8}}[]
    flk = ReentrantLock()
    on_event = (msg, send) -> begin
        get(msg, "method", "") == "Page.screencastFrame" || return
        p = msg["params"]
        send("Page.screencastFrameAck", Dict("sessionId" => p["sessionId"]))
        lock(() -> push!(frames, (Float64(p["metadata"]["timestamp"]), Base64.base64decode(p["data"]))), flk)
    end
    steps = Dict{String,Any}[]
    lock(_DECKSHOT_LOCK) do
        _with_cdp_tab(_deckshot_browser(); on_event) do call
            _cdp_open_deck(call, url, width, height, 120)
            info() = Dict{String,Any}(_cdp_value(call, "deckRenderInfo()"))
            settled() = _cdp_value(call, "deckRenderInfo().settled") === true
            call("Page.startScreencast", Dict("format" => "jpeg", "quality" => 92, "maxWidth" => width,
                                              "maxHeight" => height, "everyNthFrame" => 1))
            sleep(0.6)
            st = info(); t = time()
            push!(steps, merge(st, Dict{String,Any}("t0" => t, "t1" => t)))
            while !st["end"]
                t0 = time()
                call("Runtime.evaluate", Dict("expression" => "slideNext()"))
                sleep(0.15)
                while !settled() && time() - t0 < 60
                    sleep(0.04)
                end
                t1 = time()
                st = info()
                push!(steps, merge(st, Dict{String,Any}("t0" => t0, "t1" => t1)))
                progress("recording slide $(st["slide"] + 1) of $(st["slides"])")
            end
            sleep(0.3)
            call("Page.stopScreencast")
        end
    end
    isempty(frames) && error("the browser sent no frames")
    progress("encoding")
    holds = deck_hold_times(steps, seconds)
    _encode_deck(ff, frames, steps, holds, out, fps)
    return out
end

# The video as a timeline of (frame, seconds shown): each step opens on the frame it starts from,
# runs through the frames its motion produced, and holds the last one to the end of its share.
function _deck_timeline(ts, steps, holds)
    seq = Tuple{Int,Float64}[]
    for (i, st) in enumerate(steps)
        t0, t1, H = Float64(st["t0"]), Float64(st["t1"]), holds[i]
        entry = max(1, searchsortedlast(ts, t0))
        marks = vcat([(entry, 0.0)], [(j, clamp(ts[j] - t0, 0.0, H)) for j in entry+1:length(ts) if ts[j] <= t1])
        for (k, (j, at)) in enumerate(marks)
            until = k < length(marks) ? marks[k+1][2] : H
            until > at && push!(seq, (j, until - at))
        end
    end
    return seq
end

# WebVTT time, hh:mm:ss.mmm
function _vtt_time(x::Real)
    ms = round(Int, x * 1000)
    h, ms = divrem(ms, 3_600_000); m, ms = divrem(ms, 60_000); s, ms = divrem(ms, 1000)
    return string(lpad(h, 2, '0'), ":", lpad(m, 2, '0'), ":", lpad(s, 2, '0'), ".", lpad(ms, 3, '0'))
end

# Frames are laid out at exactly `fps` here and piped in, so the video is exactly as long as the steps'
# shares add up to: left to time still images itself, ffmpeg gives each at least its own default
# frame length, and a run of short motion frames comes out longer than it was recorded.
function _encode_deck(ff, frames, steps, holds, out, fps)
    sort!(frames; by = first)
    seq = _deck_timeline(first.(frames), steps, holds)
    isempty(seq) && error("nothing to encode")
    n = round(Int, sum(holds) * fps)
    part = out * ".part.mp4"
    cmd = `$ff -nostdin -loglevel error -y -f image2pipe -c:v mjpeg -framerate $fps -i -
           -vf format=yuv420p -c:v libx264 -preset medium -crf 18 -movflags +faststart $part`
    open(pipeline(cmd; stdout = devnull, stderr = devnull), "w") do io
        k, upto = 1, seq[1][2]
        for f in 0:n-1
            t = (f + 0.5) / fps
            while t > upto && k < length(seq)
                k += 1; upto += seq[k][2]
            end
            write(io, frames[seq[k][1]][2])
        end
    end
    mv(part, out; force = true)
    # A chapter per slide, from the time its first step comes up
    starts = cumsum(vcat(0.0, holds[1:end-1]))
    chap = [(starts[i], String(get(st, "title", ""))) for (i, st) in enumerate(steps) if get(st, "step", 0) == 0]
    total = sum(holds)
    open(splitext(out)[1] * ".vtt", "w") do io
        println(io, "WEBVTT\n")
        for (k, (t, title)) in enumerate(chap)
            stop = k < length(chap) ? chap[k+1][1] : total
            println(io, _vtt_time(t), " --> ", _vtt_time(stop)); println(io, isempty(title) ? "Slide $k" : title); println(io)
        end
    end
end

"""
    deck_render_start!(nb, base; seconds, fps = 30, theme = "") -> Dict

Start rendering notebook `nb`'s deck to a video `seconds` long, served from `base` (the hub's URL),
in the background, into `recordings/` beside the notebook, in Slate palette `theme` ("" for the
default). One render per notebook at a time. Returns the status that `deck_render_status` reports.
"""
function deck_render_start!(nb, base::AbstractString; seconds::Real, fps::Integer = 30, theme::AbstractString = "")
    st, fresh = lock(_DECK_RENDER_LOCK) do
        cur = get(_DECK_RENDERS, nb.id, nothing)
        cur !== nothing && cur["state"] == "running" && return (cur, false)
        dir = joinpath(dirname(abspath(nb.path)), "recordings"); mkpath(dir)
        len = string(floor(Int, seconds ÷ 60), "m", lpad(round(Int, seconds % 60), 2, '0'), "s")
        out = joinpath(dir, string(_recording_stem(nb.path), "-", len, ".mp4"))
        new = Dict{String,Any}("state" => "running", "message" => "starting", "file" => out,
                               "seconds" => Float64(seconds), "started" => time())
        _DECK_RENDERS[nb.id] = new
        (new, true)
    end
    fresh || return copy(st)
    set!(k, v) = lock(() -> (st[k] = v), _DECK_RENDER_LOCK)
    url = "$(base)/n/$(nb.id)?deck=1.0&render=1" * _slatetheme_qs(theme)
    width, height = deck_canvas(String(get(nb.report.meta, "slideratio", "16:9")))
    Threads.@spawn try
        deck_render(url, st["file"]; seconds, fps, width, height, progress = msg -> set!("message", msg))
        set!("message", "done"); set!("state", "done")
    catch e
        set!("message", sprint(showerror, e)); set!("state", "error")
    end
    return lock(() -> copy(st), _DECK_RENDER_LOCK)
end

deck_render_status(nb) = lock(() -> copy(get(_DECK_RENDERS, nb.id, Dict{String,Any}("state" => "idle"))), _DECK_RENDER_LOCK)
