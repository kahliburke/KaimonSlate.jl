#%% md id=intro
# 🪲 Video → tracks → figures — a pipeline preview

This notebook sketches the shape of a **dung-beetle navigation pipeline**: raw
video → detected/tracked positions → calibrated real-world coordinates →
navigation analysis → figures — as a single reactive notebook.

The clip here is [`vtest.avi`](https://github.com/opencv/opencv/blob/master/samples/data/vtest.avi),
OpenCV's classic pedestrian-tracking test video — people, not beetles, but the
same shape of problem: several independently-moving objects on a mostly-static
background, filmed from a fixed camera. Swap in real footage and a real
detector/tracker and the rest of the pipeline (calibration → world coordinates
→ navigation stats → figures) is unchanged.

**Scale note:** this notebook is for *previewing* the pipeline on a short clip
while iterating — tuning a threshold, checking a calibration, sanity-checking a
few tracks — not for running it over the TB-scale video corpus itself. The same
`detect_blobs` / `track_blobs` / `to_world` functions defined below are plain
Julia; a batch job would call them headlessly over the full corpus, with this
notebook as the place you came to *develop and spot-check* them.

#%% code id=imports
using VideoIO, ColorTypes, FixedPointNumbers, ImageMorphology, Statistics, DataFrames, LinearAlgebra, CairoMakie
CairoMakie.activate!(type = "png")
set_theme!(theme_dark())              # dark plots to match the UI

#%% code id=fetch_video
# The demo clip: OpenCV's classic **vtest.avi** (people crossing a courtyard, 768×576 @ 10 fps).
# Auto-downloaded next to the notebook env on first run, so the notebook is self-contained.
import Downloads
const VIDEO_URL = "https://github.com/opencv/opencv/raw/master/samples/data/vtest.avi"
const VIDEO_PATH = joinpath(dirname(Base.active_project()), "assets", "vtest.avi")

if !isfile(VIDEO_PATH)
    mkpath(dirname(VIDEO_PATH))
    @info "Downloading demo video (~2 MB)…" VIDEO_URL
    Downloads.download(VIDEO_URL, VIDEO_PATH)
end
(video = VIDEO_PATH, size_mb = round(filesize(VIDEO_PATH) / 1e6, digits = 1))

#%% md id=extract_md
## 1. Extract frames

Read the clip and downsample it — spatially (block-average, ×4) and temporally
(every 2nd frame) — to keep the preview light. Keep both a **color** stack (for
the video player) and a **grayscale** stack (for detection).

#%% code id=helpers
# Duck-typed on ColorTypes' `.r/.g/.b`, so it works for whatever colorant VideoIO
# hands back without pinning a specific type.
function mean_color(block)
    n = length(block)
    r = 0.0; g = 0.0; b = 0.0
    @inbounds for c in block
        r += Float64(c.r); g += Float64(c.g); b += Float64(c.b)
    end
    RGB{N0f8}(r / n, g / n, b / n)
end

function downsample(frame::AbstractMatrix, f::Int)
    H, W = size(frame)
    H2, W2 = H ÷ f, W ÷ f
    out = similar(frame, H2, W2)
    @inbounds for i in 1:H2, j in 1:W2
        out[i, j] = mean_color(view(frame, (i-1)*f+1:i*f, (j-1)*f+1:j*f))
    end
    out
end

gray(c) = 0.299 * Float64(c.r) + 0.587 * Float64(c.g) + 0.114 * Float64(c.b)

#%% code id=extract
const STRIDE = 2            # every 2nd frame (native 10 fps → 5 fps preview)
const DOWNSAMPLE = 4        # 576×768 → 144×192

function extract_frames(path; stride = STRIDE, downsample_by = DOWNSAMPLE)
    reader = VideoIO.openvideo(path)
    frames = Matrix{RGB{N0f8}}[]
    i = 0
    while !eof(reader)
        fr = read(reader)
        i % stride == 0 && push!(frames, downsample(fr, downsample_by))
        i += 1
    end
    close(reader)
    return frames
end

color_frames = extract_frames(VIDEO_PATH)
gray_frames = [gray.(f) for f in color_frames]
(nframes = length(color_frames), size = size(color_frames[1]))

#%% md id=detect_md
## 2. Detect moving objects (per frame)

A minimal background-subtraction detector: the per-pixel **median** over the
whole clip is a solid stand-in background (each pixel is "background" most of
the time), so anything that differs from it is foreground. Connected
components → centroids gives per-frame detections. This is intentionally the
simplest thing that could work — a real pipeline would swap this cell for a
trained detector (YOLO, a custom beetle model, …) without touching anything
downstream.

#%% code id=background
H, W = size(gray_frames[1])
background = [median(getindex.(gray_frames, r, c)) for r in 1:H, c in 1:W]
nothing

#%% code id=detect
function detect_blobs(mask; min_area = 3, max_blobs = 8)
    lbl = ImageMorphology.label_components(mask)
    nlbl = maximum(lbl)
    nlbl == 0 && return Tuple{Float64,Float64,Int}[]
    counts = zeros(Int, nlbl); sx = zeros(Float64, nlbl); sy = zeros(Float64, nlbl)
    for r in 1:size(lbl, 1), c in 1:size(lbl, 2)
        l = lbl[r, c]
        l == 0 && continue
        counts[l] += 1; sx[l] += c; sy[l] += r
    end
    blobs = [(sx[l] / counts[l], sy[l] / counts[l], counts[l]) for l in 1:nlbl if counts[l] >= min_area]
    sort!(blobs; by = b -> -b[3])
    return blobs[1:min(max_blobs, length(blobs))]
end

@bind thresh Slider(0.05:0.01:0.3; default = 0.15, label = "diff threshold")

#%% code id=detections
detections = [detect_blobs(abs.(g .- background) .> thresh) for g in gray_frames]
"$(sum(length, detections)) detections across $(length(detections)) frames"

#%% md id=track_md
## 3. Track — greedy nearest-neighbor identity across frames

Assign each detection to the nearest active track (within `max_dist`), or
start a new one. This is the simplest tracker that gives stable IDs; a real
pipeline would reach for something like SORT/Kalman-filter tracking for
occlusion-robust identities. Short tracks (mostly detector noise) are dropped.

#%% code id=track
function track_blobs(dets; max_dist = 15.0, max_gap = 5)
    tracks = NamedTuple{(:frame, :id, :x, :y),Tuple{Int,Int,Float64,Float64}}[]
    active = Dict{Int,Tuple{Float64,Float64,Int}}()
    next_id = 1
    for (fi, ds) in enumerate(dets)
        used = Set{Int}()
        for (x, y, _area) in ds
            best_id, best_d = 0, max_dist
            for (id, (px, py, lf)) in active
                (fi - lf > max_gap || id in used) && continue
                d = hypot(x - px, y - py)
                d < best_d && ((best_id, best_d) = (id, d))
            end
            best_id == 0 && (best_id = next_id; next_id += 1)
            active[best_id] = (x, y, fi)
            push!(used, best_id)
            push!(tracks, (frame = fi, id = best_id, x = x, y = y))
        end
    end
    return tracks
end

raw_tracks = track_blobs(detections)
track_len = Dict{Int,Int}()
for t in raw_tracks
    track_len[t.id] = get(track_len, t.id, 0) + 1
end
const MIN_TRACK_LEN = 15
keep_ids = Set(id for (id, n) in track_len if n >= MIN_TRACK_LEN)
tracks = filter(t -> t.id in keep_ids, raw_tracks)
"$(length(keep_ids)) tracks kept (≥ $MIN_TRACK_LEN frames) out of $(length(track_len)) raw"

#%% md id=calib_md
## 4. Camera calibration → pixel-to-world coordinates

Real calibration (checkerboard/ArUco intrinsics + a ground-plane homography)
is out of scope for a stand-in clip with no known landmarks — so this is an
**illustrative placeholder**: four pixel points forming the visible ground
trapezoid, mapped to a made-up 10 m × 6 m rectangle. Swap `PIXEL_CORNERS` /
`WORLD_CORNERS` for real correspondences (from a checkerboard shot or measured
landmarks in the enclosure) and everything downstream — the world-coordinate
tracks, speeds, headings, figures — works unchanged.

#%% code id=homography
# Direct Linear Transform: solve the 8 DOF of a homography from 4 exact
# point correspondences (h33 fixed to 1).
function compute_homography(pix, world)
    A = zeros(8, 8); b = zeros(8)
    for (k, ((x, y), (X, Y))) in enumerate(zip(pix, world))
        r1, r2 = 2k - 1, 2k
        A[r1, :] = [x, y, 1, 0, 0, 0, -X*x, -X*y]; b[r1] = X
        A[r2, :] = [0, 0, 0, x, y, 1, -Y*x, -Y*y]; b[r2] = Y
    end
    h = A \ b
    return [h[1] h[2] h[3]; h[4] h[5] h[6]; h[7] h[8] 1.0]
end

to_world(H, x, y) = ((v = H * [x, y, 1.0]); (v[1] / v[3], v[2] / v[3]))

# Placeholder ground-plane correspondences — see the note above.
const PIXEL_CORNERS = [(20.0, 130.0), (170.0, 130.0), (150.0, 40.0), (40.0, 40.0)]
const WORLD_CORNERS = [(0.0, 0.0), (10.0, 0.0), (10.0, 6.0), (0.0, 6.0)]
const H_CAL = compute_homography(PIXEL_CORNERS, WORLD_CORNERS)
nothing

#%% md id=analysis_md
## 5. Navigation analysis

Per-track speed and heading between consecutive detections, in world units.
This is the shape of the beetle-navigation questions (straightness, heading
distribution, turning behavior) — plug in the real navigation stats you need
once tracks are in world coordinates.

#%% code id=analysis
const DT = STRIDE / 10.0   # seconds/frame at the clip's native 10 fps

function track_dataframe(tracks, H)
    rows = NamedTuple[]
    by_id = Dict{Int,Vector{NamedTuple}}()
    for t in tracks
        push!(get!(by_id, t.id, NamedTuple[]), t)
    end
    for (id, ts) in by_id
        sort!(ts; by = r -> r.frame)
        wpts = [to_world(H, r.x, r.y) for r in ts]
        for i in eachindex(ts)
            wx, wy = wpts[i]
            speed, heading = missing, missing
            if i > 1
                dx, dy = wx - wpts[i-1][1], wy - wpts[i-1][2]
                speed = hypot(dx, dy) / DT
                heading = rad2deg(atan(dy, dx))
            end
            push!(rows, (id = id, frame = ts[i].frame, x_px = ts[i].x, y_px = ts[i].y,
                         x_m = round(wx, digits = 3), y_m = round(wy, digits = 3),
                         speed_mps = speed === missing ? missing : round(speed, digits = 3),
                         heading_deg = heading === missing ? missing : round(heading, digits = 1)))
        end
    end
    return DataFrame(rows)
end

tracks_df = track_dataframe(tracks, H_CAL)
slate_table(sort(tracks_df, [:id, :frame]); paged = true)

#%% code id=trajplot
echart(Dict(
    "title"  => Dict("text" => "Tracks in world coordinates (m)"),
    "xAxis"  => Dict("type" => "value", "name" => "x (m)"),
    "yAxis"  => Dict("type" => "value", "name" => "y (m)"),
    "legend" => Dict("show" => true),
    "series" => [
        Dict("type" => "line", "name" => "track $id", "showSymbol" => false,
             "data" => [[r.x_m, r.y_m] for r in eachrow(tracks_df) if r.id == id])
        for id in sort(collect(keep_ids))
    ],
))

#%% md id=video_md
## 6. Video preview with the tracked overlay

The same detections drive a color video player — `animate(...; kind=:image,
overlay=...)` — so you can scrub to a frame and see exactly what the detector
saw. Trails fade over the last dozen frames; colors are stable per track id.

#%% code id=video
overlay_by_frame = [Tuple{Float64,Float64,Int}[] for _ in 1:length(color_frames)]
for t in tracks
    push!(overlay_by_frame[t.frame], (t.x, t.y, t.id))
end

anim = animate(color_frames; kind = :image, overlay = overlay_by_frame,
               fps = 1 / DT, title = "vtest.avi — tracked (stand-in for beetles)")

#%% code id=playhead
@bind t playhead(anim)

#%% md id=playhead_show
Scrubbing the player above updates `t` here: currently on frame **{{ t }}**,
with **{{ length(overlay_by_frame[t]) }}** tracked point(s) in view.

#%% md id=focus_md
## 7. Follow one tracked individual

Pick a track id and the video restricts to just the frames that beetle was
seen in, with its accumulated path drawn on top (dim dots for history, a
bright highlighted dot for the current frame's position) — the shape of
"pull up beetle #12's run and watch it."

#%% code id=focus_pick
const TRACK_IDS = sort(collect(keep_ids))
@bind focus_id Select(TRACK_IDS, first(TRACK_IDS); label = "beetle")

#%% code id=focus_video
focus_rows = sort([r for r in eachrow(tracks_df) if r.id == focus_id]; by = r -> r.frame)
fmin, fmax = first(focus_rows).frame, last(focus_rows).frame
focus_frames = color_frames[fmin:fmax]

# Per relative frame: the FULL path so far (dim, id=focus_id) plus a highlighted
# current-position marker (a distinct id so it gets a different color) when this
# beetle was actually detected that frame (tracker gaps leave just the path-so-far).
focus_overlay = [Tuple{Float64,Float64,Int}[] for _ in fmin:fmax]
for rel in eachindex(focus_frames)
    absf = fmin + rel - 1
    for r in focus_rows
        r.frame > absf && break
        push!(focus_overlay[rel], (r.x_px, r.y_px, focus_id))
    end
    cur = findfirst(r -> r.frame == absf, focus_rows)
    cur !== nothing && push!(focus_overlay[rel], (focus_rows[cur].x_px, focus_rows[cur].y_px, focus_id + 1000))
end

dist_m = sum(skipmissing(r.speed_mps * DT for r in focus_rows))
anim_focus = animate(focus_frames; kind = :image, overlay = focus_overlay, fps = 1 / DT,
                     title = "beetle #$focus_id — frames $fmin:$fmax, $(round(dist_m, digits=2)) m")

#%% md id=pose3d_md
## 8. A 3-D scene from the cheap projection

We only ever calibrated a *ground plane* (§4) — there's no real depth
information in a single monocular view, so the tracks themselves stay flat
(z = 0). But the same homography, under an assumed camera intrinsics guess,
can be decomposed into an approximate **camera pose** (position + view
direction) — the standard cheap trick planar/checkerboard calibration uses.
That gives an actual 3-D scene: the flat trajectories on their ground plane,
plus *where the camera was and which way it looked* to produce them.

This is an estimate, not a measurement — a real intrinsics calibration
(checkerboard, known focal length) replaces `estimate_intrinsics` below with
the real thing and everything downstream is unchanged.

#%% code id=pose3d_decompose
# A rough intrinsics guess (no real calibration data) — a common cheap heuristic:
# focal length ≈ the image's larger dimension, principal point at the image center.
estimate_intrinsics(w, h) = [max(w, h) 0.0 w/2; 0.0 max(w, h) h/2; 0.0 0.0 1.0]

# Decompose a planar homography into an approximate camera pose (R, t, camera position C),
# given intrinsics K. `Hmat` must map WORLD → PIXEL (our `H_CAL` is the inverse, pixel→world,
# so we decompose `inv(H_CAL)`). Standard technique: normalize by K⁻¹, recover the first two
# rotation columns from the (equal-norm) H columns, the third by their cross product, then
# SVD-orthogonalize (the raw cross product isn't exactly orthonormal).
function decompose_homography(Hmat, K)
    Hn = K \ Hmat
    h1, h2, h3 = Hn[:, 1], Hn[:, 2], Hn[:, 3]
    λ = 2 / (norm(h1) + norm(h2))
    r1, r2 = λ .* h1, λ .* h2
    r3 = cross(r1, r2)
    U, _, V = svd([r1 r2 r3])
    R = U * V'
    t = λ .* h3
    C = -R' * t                  # camera position, world coordinates
    return R, t, C
end

K_est = estimate_intrinsics(W, H)
R_est, t_est, C_est = decompose_homography(inv(H_CAL), K_est)
view_dir = R_est[3, :]           # camera's optical axis, expressed in world coordinates
(camera_position_m = round.(C_est, digits = 2), view_direction = round.(view_dir, digits = 2))

#%% code id=pose3d_scene
fig3d = Figure(size = (720, 620))
ax3d = Axis3(fig3d[1, 1]; xlabel = "x (m)", ylabel = "y (m)", zlabel = "z (m)",
            title = "Ground-plane tracks + estimated camera pose", aspect = :data)

gx, gy = [0, 10, 10, 0, 0], [0, 0, 6, 6, 0]
lines!(ax3d, gx, gy, zeros(5); color = :gray50, linewidth = 2)

for id in TRACK_IDS
    rows = sort([r for r in eachrow(tracks_df) if r.id == id]; by = r -> r.frame)
    lines!(ax3d, [r.x_m for r in rows], [r.y_m for r in rows], zeros(length(rows));
          label = "track $id")
end

scatter!(ax3d, [C_est[1]], [C_est[2]], [C_est[3]]; markersize = 16, color = :gold, label = "camera (est.)")
tip = C_est .+ 3.0 .* view_dir
lines!(ax3d, [C_est[1], tip[1]], [C_est[2], tip[2]], [C_est[3], tip[3]]; color = :gold, linewidth = 3)

fig3d

# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   ColorTypes 0.12.1 3da002f7-5984-5a60-b8a6-cbb66c0b333f
#   Downloads 1.7.0 f43a241f-c20a-4ad4-852c-f6b1247861c6
#   FixedPointNumbers 0.8.6 53c48c17-4a7d-5ca2-90c5-79b7896eea93
#   ImageMorphology 0.4.7 787d08f9-d448-5407-9aad-5290dd7ab264
#   VideoIO 1.8.0 d6d074c3-1acf-5d4c-9a43-ef38773959a2
# ╚═╡
