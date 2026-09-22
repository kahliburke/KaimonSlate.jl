# Every view the status TUI can show, actually drawn.
#
# This exists because a call to a function that did not exist shipped in a commit. Julia does not
# resolve a global until the call runs, the call only runs when that view is on screen, and nothing
# drew a view — so neither precompilation nor any test noticed, and it surfaced as a stack trace
# under someone pressing `q`.
#
# A view is a pure function of the model onto a buffer, so drawing one costs nothing and needs no
# terminal. What is asserted is mostly that it renders AT ALL: an undefined name, a wrong arity, a
# field that moved. A few strings are checked where the wording carries a decision the user relies
# on — what quitting is about to do, and how to get out of a pane that has taken the keyboard.

using ReTest
using KaimonSlate
import Tachikoma
using Tachikoma: Rect, Frame, TestBackend, row_text

const KS = KaimonSlate

"""
Draw a model's whole view and return it as one string per row.

Uses Tachikoma's own `TestBackend` rather than building a `Buffer` by hand, so this keeps working
if the buffer's internals move — and because a harness that reaches past a package's test API is
the kind of thing that quietly stops testing what it claims to.
"""
function render_rows(m; w = 140, h = 44)
    tb = TestBackend(w, h)
    # A Frame carries graphics regions alongside the buffer; a view may push to them, so they are
    # real containers rather than placeholders.
    f = Frame(tb.buf, Rect(1, 1, w, h), Tachikoma.GraphicsRegion[],
              Tuple{Int,Int,Matrix{Tachikoma.ColorRGBA}}[])
    Tachikoma.view(m, f)
    return [row_text(tb, y) for y in 1:h]
end

@testset "status TUI views render" begin
    @testset "every mode draws" begin
        # The three startup modes reach different branches of the header, and `:waiting` is the one
        # with the spinner and the two different messages.
        for mode in (:owner, :viewer, :waiting)
            m = KS.SlateModel(mode)
            rows = render_rows(m)
            @test any(r -> occursin("slate", r), rows)
        end
    end

    @testset "the quit confirmation draws and says what it will do" begin
        m = KS.SlateModel(:viewer)
        m.quit_confirm = true
        rows = render_rows(m)
        txt = join(rows, "\n")
        @test occursin("quit slate?", txt)
        # The keys have to be on screen: a modal that takes the keyboard without saying how to
        # answer is a trap, and this one is reached by the key people press to leave.
        @test occursin("[y/q]", txt) && occursin("[n/esc]", txt)
        # With no host of ours, quitting is just closing a window — and it should say so rather
        # than warning about stopping something that is not ours.
        @test occursin("hub keeps running", txt)
    end

    @testset "the detail modal draws" begin
        m = KS.SlateModel(:viewer)
        m.notebooks = Any[Dict{String,Any}("id" => "nb1", "cells" => 3, "code" => 2, "md" => 1,
                                           "errors" => 0, "running" => 0, "stale" => 0,
                                           "path" => "/tmp/nb1.jl", "title" => "nb1")]
        m.rows = m.notebooks
        render_rows(m)            # builds the table
        m.detail = true
        @test any(r -> occursin("nb1", r), render_rows(m))
    end

    @testset "the port prompt draws" begin
        m = KS.SlateModel(:owner)
        m.port_edit = "8765"
        @test any(r -> occursin("8765", r), render_rows(m))
    end
end
