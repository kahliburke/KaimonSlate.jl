# Animation

`animate` plays a stack of precomputed frames back **entirely in the browser** on a WebGL
canvas. You compute the frames once in Julia; playback runs on the GPU, so a slow simulation
still plays at 60 fps and **nothing touches Julia during playback**.

Return an `animate(…)` from a cell to render the player (play/pause, a scrubber, and a frame
counter).

![The animate player: a WebGL canvas of a scalar field with a play/scrub control strip](./assets/animate.png)

## Heatmap frames (default)

`kind=:heatmap` takes a vector of 2-D scalar matrices, colormapped for you:

```julia
xs = range(-3, 3; length = 120)
frames = [[exp(-((x-cos(t))^2 + (y-sin(t))^2)) for x in xs, y in xs] for t in range(0, 2π; length = 60)]
animate(frames; x = xs, y = xs, title = "moving gaussian", autoplay = true)
```

Control how frames are colour-scaled with `clim`:

| `clim` | Meaning |
| --- | --- |
| `:global` (default) | one scale across all frames — frames are directly comparable |
| `:symmetric` | signed fields → a diverging map centred at 0 (skips `transform`) |
| `:perframe` | rescale each frame to its own min/max |
| `(lo, hi)` | an explicit fixed range |

Other keywords: `colormap` (`:auto` or any name), `fps`, `transform` (e.g. `log`), `dither`,
`loop`, `autoplay`, `title`, and `x`/`y` axis coordinates.

## Image frames

`kind=:image` plays back **true-color** frames — a `Vector` of H×W color matrices (e.g.
`Matrix{RGB}` from [VideoIO.jl](https://github.com/JuliaIO/VideoIO.jl) or Images.jl) or H×W×3
arrays — with no colormap:

```julia
using VideoIO
reader = VideoIO.openvideo("clip.mp4")
frames = [read(reader) for _ in 1:120]      # Vector{Matrix{RGB{N0f8}}}
animate(frames; kind = :image, fps = 25, title = "clip")
```

## Overlays

`overlay` draws frame-synced markers on top of either kind — a `Vector` with one entry per
frame, each a list of `(x, y)` or `(x, y, id)` points in frame-pixel space. An `id` keeps a
point's colour and trail stable across frames (handy for tracking):

```julia
tracks = [[(x1(t), y1(t), 1), (x2(t), y2(t), 2)] for t in 1:120]   # per-frame detections
animate(frames; kind = :image, overlay = tracks, fps = 25, title = "tracked beetles")
```

## Reacting to the current frame — `playhead`

`animate` plays without involving Julia, but you can still **react** to playback with the
`playhead` driven control. It's a `@bind` target that receives the animation's current 1-based
frame index (it has no input of its own):

```julia
#%% code id=anim
anim = animate(frames; x = xs, y = xs)

#%% code id=t
@bind t playhead(anim)

#%% code id=readout
"frame $t / $(length(frames)) — t = $(round(times[t]; digits = 2))"
```

Any cell that reads `t` recomputes as the animation plays — so a caption, a marker, or a linked
chart tracks the frame. Updates are throttled and never block playback. See
[Widgets & @bind](widgets.md) and [Reactive Cells](reactivity.md).

!!! tip "Compute once, cache it"
    The frame stack is usually the expensive part. Put it in its own cell so the reactive engine
    computes it once; expensive cells are also [auto-cached](cell-tags.md#caching) and restored
    after a restart.
