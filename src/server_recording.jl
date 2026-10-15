# Presentation recording: the deck captures its own tab (plus a microphone) with MediaRecorder and
# streams the encoded bytes here in chunks, so a long talk never sits in browser memory. The hub
# owns every path: the client gets an opaque recording id from `start` and can only append to, and
# finish, the file that id names. Files land in `<notebook dir>/recordings/`.
#
# Not in app mode's allowlist (server_app.jl), so an app reader cannot write files through this.

mutable struct _Recording
    nbid::String
    path::String          # the media file chunks are appended to
    bytes::Int
    started::Float64
end

const _REC_LOCK = ReentrantLock()
const _RECORDINGS = Dict{String,_Recording}()
const _REC_ID = r"^[0-9a-f]{32}$"
const _REC_STALE_S = 24 * 3600.0         # an unfinished recording's entry is dropped after this

_recording_ext(mime::AbstractString) = startswith(lowercase(mime), "video/mp4") ? "mp4" : "webm"

function _recording_stem(nbpath::AbstractString)
    base = replace(splitext(basename(nbpath))[1], r"[^A-Za-z0-9_.-]" => "_")
    isempty(base) && (base = "notebook")
    return base * "-" * Dates.format(Dates.now(), "yyyymmdd-HHMMSS")
end

"""
    recording_start!(nbid, nbpath; mime) -> Dict

Open a new recording file for the notebook at `nbpath` and register it under a fresh random id.
The extension follows the recorder's `mime` (mp4 or webm); the name is the notebook's plus a
timestamp, suffixed if a recording with that name already exists.
"""
function recording_start!(nbid::AbstractString, nbpath::AbstractString; mime::AbstractString = "video/webm")
    dir = joinpath(dirname(abspath(nbpath)), "recordings")
    mkpath(dir)
    ext = _recording_ext(mime)
    stem = _recording_stem(nbpath)
    path = joinpath(dir, stem * "." * ext)
    n = 2
    while isfile(path)
        path = joinpath(dir, string(stem, "-", n, ".", ext)); n += 1
    end
    write(path, UInt8[])
    rid = bytes2hex(rand(UInt8, 16))
    lock(_REC_LOCK) do
        now = time()
        filter!(kv -> now - kv[2].started < _REC_STALE_S, _RECORDINGS)
        _RECORDINGS[rid] = _Recording(String(nbid), path, 0, now)
    end
    return Dict{String,Any}("id" => rid, "file" => joinpath("recordings", basename(path)), "ext" => ext)
end

# The recording `rid` names, if it is well-formed and belongs to this notebook.
function _recording(nbid::AbstractString, rid::AbstractString)
    occursin(_REC_ID, rid) || return nothing
    r = lock(() -> get(_RECORDINGS, String(rid), nothing), _REC_LOCK)
    (r === nothing || r.nbid != nbid) && return nothing
    return r
end

"Append `bytes` to the recording. `false` when `rid` is not a live recording of `nbid`."
function recording_chunk!(nbid::AbstractString, rid::AbstractString, bytes::AbstractVector{UInt8})
    r = _recording(nbid, rid)
    r === nothing && return false
    lock(_REC_LOCK) do                     # chunks must land in order; the client sends them one at a time
        open(io -> write(io, bytes), r.path, "a")
        r.bytes += length(bytes)
    end
    return true
end

"""
    recording_finish!(nbid, rid; vtt, timings) -> Union{Dict,Nothing}

Close the recording: write the chapters (`vtt`, WebVTT text) and the slide timings (`timings`, any
JSON value) beside the media file, and drop the id. A webm is transcoded to mp4 in the background
when `ffmpeg` is available, since browsers record webm without a seekable index and many players
won't open it; the webm is kept if that fails.
"""
function recording_finish!(nbid::AbstractString, rid::AbstractString; vtt::AbstractString = "", timings = nothing)
    r = _recording(nbid, rid)
    r === nothing && return nothing
    lock(() -> delete!(_RECORDINGS, String(rid)), _REC_LOCK)
    stem = splitext(r.path)[1]
    out = Dict{String,Any}("file" => r.path, "bytes" => r.bytes)
    if !isempty(vtt)
        write(stem * ".vtt", vtt); out["chapters"] = stem * ".vtt"
    end
    if timings !== nothing
        write(stem * ".json", JSON.json(Dict("media" => basename(r.path), "bytes" => r.bytes,
                                             "timings" => timings), 2))
        out["timings"] = stem * ".json"
    end
    ff = Sys.which("ffmpeg")
    if endswith(r.path, ".webm") && ff !== nothing && r.bytes > 0
        out["converting"] = stem * ".mp4"
        Threads.@spawn _recording_to_mp4(ff, r.path, stem * ".mp4")
    end
    return out
end

function _recording_to_mp4(ff::AbstractString, src::AbstractString, dst::AbstractString)
    part = dst * ".part.mp4"
    cmd = `$ff -nostdin -loglevel error -y -i $src -c:v libx264 -preset veryfast -crf 20
           -pix_fmt yuv420p -c:a aac -b:a 160k -movflags +faststart $part`
    try
        run(pipeline(cmd; stdout = devnull, stderr = devnull))
        mv(part, dst; force = true)
        rm(src; force = true)
    catch e
        rm(part; force = true)
        @warn "Kaimon Slate: recording kept as webm; mp4 conversion failed" src exception = e
    end
    return nothing
end

function _register_recording_routes!(router, h::Hub)
    HTTP.register!(router, "POST", "/api/{id}/recording/start", req -> _withnb(h, req, nb ->
        _json(recording_start!(nb.id, nb.path; mime = String(get(_body(req), "mime", "video/webm"))))))
    HTTP.register!(router, "POST", "/api/{id}/recording/{rid}/chunk", req -> _withnb(h, req, nb ->
        recording_chunk!(nb.id, String(HTTP.getparam(req, "rid")), Vector{UInt8}(req.body)) ?
            _json(Dict("ok" => true)) : HTTP.Response(404, "no such recording")))
    HTTP.register!(router, "POST", "/api/{id}/recording/{rid}/finish", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        r = recording_finish!(nb.id, String(HTTP.getparam(req, "rid"));
                              vtt = String(get(b, "chapters_vtt", "")), timings = get(b, "timings", nothing))
        r === nothing ? HTTP.Response(404, "no such recording") : _json(r)
    end))
end
