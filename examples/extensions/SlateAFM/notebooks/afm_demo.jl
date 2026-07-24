try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🧩 AFM widgets in Slate

**SlateAFM** hosts **Anywidget Front-End Modules (AFM)** — framework-agnostic ES modules that
`export default { initialize?, render? }` and drive a host `model`. It implements the AFM contract on
Slate's own seams: `provide_frontend!` injects the host shim, `provide_assets!` serves the modules, and
the bound value becomes the widget's **traits dict**.
"""

#%% code id=use
using SlateAFM

#%% md id=h_counter
@md"""
## Counter — the canonical AFM module

`ext_asset_url(SlateAFM, "examples/counter.js")` is a self-contained AFM module (no imports): `model.get/set("count")` +
`save_changes()` on click, and `on("change:count")` to redraw. Bound below to the trait dict `st`.
"""

#%% code id=counter
@bind st afm(ext_asset_url(SlateAFM, "examples/counter.js"); count = 0)

#%% md id=counter_read
@md"""
The bound value is a live dict: **`st` = {{st}}**. Click the button — `save_changes()` commits the trait
and this line re-renders reactively, exactly like any `@bind`.
"""

#%% md id=h_slider
@md"""
## Slider — multiple traits

`slider.js` drives a `value` trait live while dragging and reads a `label` trait. Multiple observable
traits over the same bound dict.
"""

#%% code id=slider
@bind sl afm(ext_asset_url(SlateAFM, "examples/slider.js"); value = 25, min = 0, max = 100, label = "gain")

#%% md id=slider_read
@md"""
**`sl` = {{sl}}** — drag the slider and the `value` trait commits live.
"""

#%% md id=h_compose
@md"""
## Composition — `host.getWidget`

A widget can resolve *another* mounted AFM widget by ref and use its exports. `control.js` exports
`getValue`/`onChange` from `initialize`; `readout.js` does `host.getWidget("ctl")`, renders a second live
view of the control, and shows its value. Drag either slider — both views + the value track together.
"""

#%% code id=control
@bind ctl afm(ext_asset_url(SlateAFM, "examples/control.js"); id = "ctl", value = 40, min = 0, max = 100)

#%% code id=readout
@bind ro afm(ext_asset_url(SlateAFM, "examples/readout.js"); control = "ctl")

#%% md id=h_buffers
@md"""
## Binary buffers — `model.send` / `on("msg:custom")` both ways

`buffers.js` sends a `Uint8Array` to Julia (`model.send(content, cb, [buffer])`) and shows Julia's reply.
The handler (defined first, below) echoes the bytes back **reversed**. Both directions carry real bytes over
Slate's binary WebSocket — JS→Julia as a binary uplink frame, Julia→JS as a `SlateBinary` frame. No base64.
"""

#%% code id=buffers_handler
afm_on_msg("bz") do content, buffers
    bytes = isempty(buffers) ? UInt8[] : buffers[1]
    afm_emit("bz", Dict("op" => "echoed", "n" => length(bytes)); buffers = [reverse(bytes)])
end

#%% code id=buffers
@bind bz afm(ext_asset_url(SlateAFM, "examples/buffers.js"); id = "bz")

#%% md id=h_image
@md"""
## Showcase — real image processing in Julia over binary buffers

The widget draws an image in the browser, ships its **raw RGBA pixels** (~130 KB) to Julia via
`model.send(content, cb, [buffer])`, Julia runs an actual filter on the bytes, and returns the processed
pixels over the binary WebSocket to paint. Real bytes both ways — no base64. Click a filter and watch the
round-trip time.
"""

#%% code id=image_filters
# Image filters over a row-major RGBA byte buffer (length w*h*4). Plain Julia on the raw `Vector{UInt8}` —
# this is the "real work" the binary transport exists to make cheap in both directions.
lum(r, g, b) = 0.299 * r + 0.587 * g + 0.114 * b

function apply_filter(name::AbstractString, rgba::Vector{UInt8}, w::Int, h::Int)
    out = copy(rgba)
    if name == "invert"
        @inbounds for i in 1:4:length(rgba)
            out[i], out[i+1], out[i+2] = 0xff - rgba[i], 0xff - rgba[i+1], 0xff - rgba[i+2]
        end
    elseif name == "grayscale"
        @inbounds for i in 1:4:length(rgba)
            v = round(UInt8, lum(rgba[i], rgba[i+1], rgba[i+2]))
            out[i] = out[i+1] = out[i+2] = v
        end
    elseif name == "threshold"
        @inbounds for i in 1:4:length(rgba)
            v = lum(rgba[i], rgba[i+1], rgba[i+2]) > 127 ? 0xff : 0x00
            out[i] = out[i+1] = out[i+2] = v
        end
    elseif name == "edges"                       # Sobel gradient magnitude on luminance
        L = Array{Float64}(undef, h, w)
        @inbounds for y in 0:h-1, x in 0:w-1
            i = (y * w + x) * 4 + 1
            L[y+1, x+1] = lum(rgba[i], rgba[i+1], rgba[i+2])
        end
        @inbounds for y in 0:h-1, x in 0:w-1
            xm, xp = max(x-1, 0), min(x+1, w-1); ym, yp = max(y-1, 0), min(y+1, h-1)
            gx = (L[ym+1,xp+1] + 2L[y+1,xp+1] + L[yp+1,xp+1]) - (L[ym+1,xm+1] + 2L[y+1,xm+1] + L[yp+1,xm+1])
            gy = (L[yp+1,xm+1] + 2L[yp+1,x+1] + L[yp+1,xp+1]) - (L[ym+1,xm+1] + 2L[ym+1,x+1] + L[ym+1,xp+1])
            v = round(UInt8, clamp(sqrt(gx^2 + gy^2), 0, 255))
            i = (y * w + x) * 4 + 1
            out[i] = out[i+1] = out[i+2] = v; out[i+3] = 0xff
        end
    end
    return out
end

# Read a field whether the message content arrived as a NamedTuple (the usual shape) or a Dict.
_field(c, k) = c isa NamedTuple ? getproperty(c, Symbol(k)) : c[String(k)]

#%% code id=image_handler
afm_on_msg("imgfx") do content, buffers
    isempty(buffers) && return nothing
    name = String(_field(content, :name)); w = Int(_field(content, :w)); h = Int(_field(content, :h))
    afm_emit("imgfx", Dict("op" => "done", "name" => name); buffers = [apply_filter(name, buffers[1], w, h)])
    return nothing
end

#%% code id=image_widget
@bind imgfx afm(ext_asset_url(SlateAFM, "examples/image_filter.js"); id = "imgfx", w = 180, h = 180)

#%% md id=h_bench
@md"""
## Benchmark — sustained load, binary channel vs base64-in-JSON

Pick a payload size and a duration; each mode round-trips to Julia **back-to-back for the full duration**, so
the numbers are steady-state: throughput (MB/s, counting bytes up + down), messages/s, total data moved, and
the latency distribution (mean / p50 / p95 / p99 / max) over hundreds of round-trips. **binary** =
`model.send(…, [buffer])` (raw bytes both ways); **base64** = bytes base64'd into the JSON call,
decoded/re-encoded in Julia, base64 back (what we'd do without the uplink). Single-stream (one round-trip in
flight). The base64 handler below uses stdlib `Base64` in the *notebook* — SlateAFM carries no base64 dep.
"""

#%% code id=bench_handler
import Base64
afm_on_msg("bench") do content, buffers
    if String(_field(content, :mode)) == "binary"
        afm_emit("bench", Dict("op" => "echo", "mode" => "binary"); buffers = [buffers[1]])   # raw bytes back
    else                                                                                      # base64 path
        bytes = Base64.base64decode(String(_field(content, :b64)))
        afm_emit("bench", Dict("op" => "echo", "mode" => "base64", "b64" => Base64.base64encode(bytes)))
    end
    return nothing
end

#%% code id=bench_widget
@bind bench afm(ext_asset_url(SlateAFM, "examples/benchmark.js"); id = "bench")

#%% md id=h_pypi
@md"""
## Third-party widget from PyPI — `pypi_afm`

An anywidget published on PyPI runs here **unchanged**. `pypi_afm` shells out to the system `python3 -m pip`
(SlateAFM takes no Python dependency) to install the package into a cached deploy dir and read its
`_esm`/`_css`/trait-defaults — no widget instantiation, no kernel. The provisioned module is kept strictly
apart from this package's own assets (served under `/ext-assets/SlateAFMpypi/…`, in `SlateAFM.deploy_dir()`).
If no `pip` is present it errors with the manual fallbacks (a CDN URL / `ext_asset_url`).

Below: **ipymolstar** (PDBe Mol\*) — a real molecular viewer, hosted unchanged. First run installs it (a few
seconds); after that it's cached. Needs network for the Mol\* plugin + stylesheet it pulls from a CDN.
"""

#%% code id=molstar
@bind pmol pypi_afm("ipymolstar"; class = "PDBeMolstar",
    css = "https://cdn.jsdelivr.net/npm/pdbe-molstar@3.3.2/build/pdbe-molstar.css",
    molecule_id = "1cbs", hide_water = true, height = "340px")

#%% md id=h_drive
@md"""
## Julia in the driver's seat — building a molecule *in the real Mol\* engine*

Now Julia **builds** a molecule and drives the real PDBe Mol\* viewer with it. `build_dna_pdb` computes a
B-DNA double helix (phosphate backbone + colour-coded base rungs) and emits it as a PDB; the button ships
that PDB to the viewer over the binary `msg:custom` channel (`afm_emit`), and a thin wrapper
(`molstar_live.js`) loads it into the actual Mol\* engine — no sticky-bind trait round-trip. The viewer
(below the code) re-renders whatever Julia sends.
"""

#%% code id=dna_build
# Build a coarse B-DNA double helix in Julia and emit it as a PDB the real Mol* engine renders: a phosphate
# backbone (P) on each strand + colour-coded base atoms (N/O/C) on the rungs, with CONECT bonds.
import Printf
function _pdb_atom(ser, el, x, y, z)
    name = " " * rpad(el, 3)                                   # cols 13-16
    string("HETATM", lpad(ser, 5), " ", name, " ", "DNA", " ", "A", lpad(1, 4), " ", "   ",
           Printf.@sprintf("%8.3f%8.3f%8.3f", x, y, z), "  1.00  0.00", " "^10, lpad(el, 2))
end
function build_dna_pdb(nbp::Int; R = 9.0, rise = 3.4, turn = 10.5, groovefrac = 0.42)
    twist = 2π / turn; goff = 2π * groovefrac
    lines = String[]; ser = 0
    pA = Int[]; pB = Int[]; bA = Int[]; bB = Int[]
    atom!(el, x, y, z) = (ser += 1; push!(lines, _pdb_atom(ser, el, x, y, z)); ser)
    for i in 0:nbp-1
        a = i * twist; y = (i - (nbp - 1) / 2) * rise
        Ax, Az = R * cos(a), R * sin(a); Bx, Bz = R * cos(a + goff), R * sin(a + goff)
        push!(pA, atom!("P", Ax, y, Az)); push!(pB, atom!("P", Bx, y, Bz))
        e1, e2 = ("N", "O", "C", "N")[mod1(i + 1, 4)], ("O", "N", "N", "C")[mod1(i + 1, 4)]
        push!(bA, atom!(e1, Ax + (Bx - Ax) * 0.34, y, Az + (Bz - Az) * 0.34))
        push!(bB, atom!(e2, Ax + (Bx - Ax) * 0.66, y, Az + (Bz - Az) * 0.66))
    end
    conect(i, j) = push!(lines, Printf.@sprintf("CONECT%5d%5d", i, j))
    for i in 1:nbp-1; conect(pA[i], pA[i+1]); conect(pB[i], pB[i+1]); end
    for i in 1:nbp; conect(pA[i], bA[i]); conect(bA[i], bB[i]); conect(bB[i], pB[i]); end
    push!(lines, "END")
    return join(lines, "\n") * "\n"
end

#%% code id=drive_btn
@bind buildmol Button("⚛ Build a DNA helix in Mol*")

#%% code id=drive_driver
# Manipulating code: on click, build the molecule and push it to the viewer below over the binary channel.
@onclick buildmol afm_emit("mol", Dict("op" => "load", "pdb" => build_dna_pdb(24)))

#%% code id=molstar_live
@bind mol afm(ext_asset_url(SlateAFM, "examples/molstar_live.js"); id = "mol",
    css = "https://cdn.jsdelivr.net/npm/pdbe-molstar@3.3.2/build/pdbe-molstar.css", height = 440)

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = a1f0c2d4-5e6b-47a8-9c1d-3b2e4f6a7c88
# ╚═╡
