# The shared "Slate look": the Julia palettes that Makie and the deck settings read MUST stay equal to
# the CSS theme blocks (`:root` and each `html[data-slate-theme]`) that the client ECharts theme reads.
# This golden test pins the two, so a colour edit on one side only fails CI. It also checks the Makie
# theme attributes.
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

    @testset "Julia palettes mirror the CSS theme blocks — golden parity" begin
        css = read(joinpath(@__DIR__, "..", "src", "assets", "notebook.css"), String)
        function vars(sel)
            m = match(Regex(sel * "\\s*\\{(.*?)\\}", "s"), css)   # the FIRST block of the selector
            @test m !== nothing
            Dict(lowercase(vm.captures[1]) => lowercase(vm.captures[2])
                 for vm in eachmatch(r"--([a-z0-9]+)\s*:\s*(#[0-9a-fA-F]{3,8})"i, m.captures[1]))
        end
        root = vars(":root")
        for (name, p) in RE.SLATE_PALETTES
            v = name == "midnight" ? root : merge(root, vars("html\\[data-slate-theme=\"$name\"\\]"))
            # every palette field must equal the CSS var of the same name (byte-for-byte, case-insensitive)
            for k in keys(p)
                @test get(v, String(k), nothing) == lowercase(getfield(p, k))
            end
        end
        @test RE.SLATE_PALETTE === RE.SLATE_PALETTES["midnight"]
    end
end
