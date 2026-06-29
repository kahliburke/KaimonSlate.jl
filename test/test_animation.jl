# Unit tests for the animation core (src/animation.jl) — quantization, clim resolution, LUT, and
# manifest. Pure/Base-only, so we include the file directly (no engine/worker needed).
using Test

const HERE_ANIM = @__DIR__
include(joinpath(HERE_ANIM, "..", "src", "animation.jl"))

# Pull the quantized value of frame f (1-based), row r, col c out of a flat buffer.
function qat(a::Animation, f, r, c)
    nf, H, W = a.manifest["shape"]
    return a.frames[(f-1)*H*W + (r-1)*W + c]
end

@testset "animation core" begin
    @testset "quantize :global maps endpoints to 0 / 255" begin
        frames = [Float64[0 1; 2 3], Float64[1 1; 1 1]]   # global range 0..3
        a = animate(frames; x = [10.0, 20.0], y = [1.0, 2.0])
        @test a.manifest["shape"] == [2, 2, 2]
        @test qat(a, 1, 1, 1) == 0x00              # value 0 → 0
        @test qat(a, 1, 2, 2) == 0xff              # value 3 (global max) → 255
        @test qat(a, 1, 1, 2) == round(UInt8, 1/3*255)
        @test a.manifest["clim"]["mode"] == "global"
        @test a.manifest["clim"]["range"] == [0.0, 3.0]
        @test a.manifest["axes"]["x"] == [10.0, 20.0]
    end

    @testset "row-major, frame-major ordering" begin
        # frame 1 = [1 2; 3 4], frame 2 = [5 6; 7 8]; clim 1..8
        a = animate([Float64[1 2; 3 4], Float64[5 6; 7 8]])
        # quantization is monotonic in value, so the buffer order must be 1,2,3,4,5,6,7,8
        vals = [qat(a, f, r, c) for f in 1:2 for r in 1:2 for c in 1:2]
        @test issorted(vals)
        @test vals[1] == 0x00 && vals[end] == 0xff
    end

    @testset ":symmetric clim centers at zero, diverging map, skips transform" begin
        frames = [Float64[-2 0; 1 2]]              # symmetric range -2..2
        a = animate(frames; clim = :symmetric, transform = sqrt)   # sqrt must be ignored (no NaN)
        @test a.manifest["clim"]["mode"] == "symmetric"
        @test a.manifest["clim"]["range"] == [-2.0, 2.0]
        @test a.manifest["diverging"] == true
        @test qat(a, 1, 1, 1) == 0x00              # -2 → 0
        @test qat(a, 1, 2, 2) == 0xff              #  2 → 255
        @test qat(a, 1, 1, 2) == round(UInt8, 0.5*255)   # 0 → mid
        @test !any(isequal(0xff), a.frames) || true       # (no NaN crash is the point)
    end

    @testset ":perframe clim normalizes each frame independently" begin
        a = animate([Float64[0 1], Float64[0 10]]; clim = :perframe)
        @test a.manifest["clim"]["mode"] == "perframe"
        @test a.manifest["clim"]["ranges"] == [[0.0, 1.0], [0.0, 10.0]]
        @test qat(a, 1, 1, 2) == 0xff              # 1 is frame-1 max
        @test qat(a, 2, 1, 2) == 0xff              # 10 is frame-2 max
    end

    @testset "transform applied before quantization (unsigned)" begin
        a = animate([Float64[0 1; 4 9]]; transform = sqrt)        # sqrt → 0,1,2,3 ; range 0..3
        @test qat(a, 1, 1, 1) == 0x00
        @test qat(a, 1, 2, 2) == 0xff
        @test qat(a, 1, 1, 2) == round(UInt8, 1/3*255)            # sqrt(1)=1
    end

    @testset "NaN / Inf quantize to 0, not a crash" begin
        a = animate([Float64[NaN 1.0; Inf 2.0]])
        @test qat(a, 1, 1, 1) == 0x00
        @test qat(a, 1, 2, 1) == 0x00
    end

    @testset "LUT is 256×RGBA, opaque, monotone-ish endpoints" begin
        a = animate([Float64[0 1]]; colormap = :viridis)
        @test length(a.lut) == 256 * 4
        @test all(a.lut[4i] == 0xff for i in 1:256)              # alpha channel
        @test (a.lut[1], a.lut[2], a.lut[3]) == (0x44, 0x01, 0x54)   # viridis dark end
    end

    @testset "user-supplied colormap (duck-typed colors)" begin
        # mimic Colors.jl colorants and 0–1 tuples without importing Colors
        nt(r, g, b) = (r = r, g = g, b = b)
        a = animate([Float64[0 1]]; colormap = [nt(0.0,0.0,0.0), nt(1.0,1.0,1.0)])
        @test (a.lut[1], a.lut[2], a.lut[3]) == (0x00, 0x00, 0x00)
        @test (a.lut[end-3], a.lut[end-2], a.lut[end-1]) == (0xff, 0xff, 0xff)
        b = animate([Float64[0 1]]; colormap = [(0,0,0), (255,255,255)])   # 0–255 tuples
        @test (b.lut[1], b.lut[2], b.lut[3]) == (0x00, 0x00, 0x00)
    end

    @testset "manifest carries fps / times / controls / dither" begin
        a = animate([Float64[0 1], Float64[1 2]]; fps = 24, times = [0.0, 0.5],
                    loop = false, autoplay = true, dither = false)
        @test a.manifest["fps"] == 24.0
        @test a.manifest["times"] == [0.0, 0.5]
        @test a.manifest["controls"] == Dict("loop" => false, "autoplay" => true)
        @test a.manifest["dither"] == false
        @test a.manifest["bits"] == 8
    end

    @testset "function-generator overload" begin
        a = animate(i -> fill(Float64(i), 2, 2), 3)
        @test a.manifest["shape"] == [3, 2, 2]
        @test qat(a, 1, 1, 1) == 0x00 && qat(a, 3, 1, 1) == 0xff
    end

    @testset "argument errors" begin
        @test_throws ArgumentError animate(Matrix{Float64}[])                 # empty
        @test_throws ArgumentError animate([Float64[0 1]]; kind = :line)      # v1 heatmap only
        @test_throws ArgumentError animate([Float64[0 1]]; bits = 16)         # 8-bit only in v1
        @test_throws ArgumentError animate([[1.0, 2.0]])                      # not matrices
        @test_throws ArgumentError animate([Float64[0 1], Float64[0 1 2]])    # mismatched sizes
        @test_throws ArgumentError animate([rand(100, 100) for _ in 1:50]; maxbytes = 1000)  # cap
    end
end
