# The shared "Slate look": the Julia palette that Makie mirrors MUST stay in lockstep with the CSS
# `:root` (Midnight) that the client ECharts theme reads — this golden test pins the two so a colour
# edit on one side without the other fails CI. Also checks the Makie theme attrs are well-formed.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl"))
using .ReportEngine
const RE = ReportEngine

@testset "slate look — shared ECharts/Makie palette" begin
    @testset "series cycle + Makie theme attributes" begin
        cyc = RE.slate_series_cycle()
        @test length(cyc) == 7 && cyc[1] == RE.SLATE_PALETTE.accent
        a = RE.slate_theme_attrs()
        @test a.backgroundcolor === :transparent          # matches ECharts' transparent canvas
        @test a.palette.color == cyc                       # same categorical cycle as ECharts
        @test a.size == (680, 340)                         # figure height aligned with the ECharts cell
        @test a.Axis.titlecolor == RE.SLATE_PALETTE.text
        @test a.Axis.xgridcolor == (RE.SLATE_PALETTE.border, 0.5)

        # Makie's in-figure widgets. Their defaults are light-mode constants rather than anything
        # derived from `textcolor`, so a figure carrying controls needs them named explicitly or it
        # comes out half-themed. Pinned here because a wrong key is SILENT: Makie ignores a theme
        # entry it doesn't recognise, so a typo shows up only as a widget that stayed grey.
        p = RE.SLATE_PALETTE
        @test a.Button.buttoncolor == p.bg2
        @test a.Button.buttoncolor_active == p.accent
        @test a.Button.labelcolor == p.text
        @test a.Slider.color_active == p.accent
        @test a.Slider.color_inactive == p.bg3
        # The label a SliderGrid draws is a `Label`, which follows the top-level textcolor — so that
        # has to be set for the widget block above to be enough.
        @test a.textcolor == p.text
    end

    # Every palette must supply the fields the widget attrs read, or switching theme throws rather
    # than falling back — the widget entries reach for `bg2`/`bg3`/`accent`/`text`, not just the
    # axis-facing ones.
    @testset "widget attrs resolve for every palette" begin
        for name in keys(RE.SLATE_PALETTES)
            a = RE.slate_theme_attrs(RE.SLATE_PALETTES[name])
            @test a.Button.buttoncolor == RE.SLATE_PALETTES[name].bg2
            @test a.Slider.color_active == RE.SLATE_PALETTES[name].accent
        end
    end

    @testset "Julia palette mirrors the CSS :root (Midnight) — golden parity" begin
        css = read(joinpath(@__DIR__, "..", "src", "assets", "notebook.css"), String)
        m = match(r":root\s*\{(.*?)\}"s, css)              # the FIRST :root block is the canonical default
        @test m !== nothing
        vars = Dict{String,String}()
        for vm in eachmatch(r"--([a-z0-9]+)\s*:\s*(#[0-9a-fA-F]{3,8})"i, m.captures[1])
            vars[lowercase(vm.captures[1])] = lowercase(vm.captures[2])
        end
        # every palette field must equal the CSS var of the same name (byte-for-byte, case-insensitive)
        for k in (:bg, :bg2, :bg3, :border, :text, :dim, :accent, :green, :red, :gold, :orange, :purple, :teal)
            @test haskey(vars, String(k))
            @test vars[String(k)] == lowercase(getfield(RE.SLATE_PALETTE, k))
        end
    end
end
