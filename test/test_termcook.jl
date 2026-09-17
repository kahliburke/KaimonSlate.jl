# Terminal control-sequence replay (src/termcook.jl).
#
# The ProgressMeter streams below are VERBATIM captures from a notebook worker, not hand-written
# approximations — they're the reason this file exists, and their exact shape (where the `\r`s and
# `\e[A`s fall) is what the replay has to get right.

using ReTest

include(joinpath(@__DIR__, "..", "src", "termcook.jl"))

# One redraw per update: `\r`, the new bar, erase-to-end-of-line. Ends with a real newline.
const PM_SIMPLE = "\rt  50%|████████████████████████▌                        |  ETA: 0:00:00\e[K" *
                  "\rt 100%|█████████████████████████████████████████████████| Time: 0:00:00\e[K\n"

# `showvalues` draws a 3-line block, then rewinds over it with `\e[A` to redraw in place.
const PM_SHOWVALUES = "\rt  67%|████████████████████████████████▋                |  ETA: 0:00:00\e[K" *
                      "\r\n    i: 2\e[K\r\n   sq: 4\e[K\r\e[A\r\e[A\n\n\r\e[K\e[A\r\e[K\e[A" *
                      "\rt 100%|█████████████████████████████████████████████████| Time: 0:00:00\e[K" *
                      "\r\n    i: 3\e[K\r\n   sq: 9\e[K\n"

const PM_UNKNOWN = "\rscan: 2    Time: 0:00:00\e[K\rscan: 3    Time: 0:00:00\e[K\n"

@testset "termcook" begin

    @testset "plain output is untouched" begin
        # The fast path: no cursor movement, so cooking must be byte-identical — including the
        # trailing newline, which the screen model would otherwise drop.
        for s in ("", "hello\n", "a\nb\nc\n", "trailing spaces   \n", "unicode ∑ ∫ 🎉\n",
                  "blank\n\n\ninterior\n")
            @test cook_terminal(s) == s
        end
    end

    @testset "ProgressMeter — single line" begin
        out = cook_terminal(PM_SIMPLE)
        @test !occursin('\r', out)
        @test !occursin('\e', out)
        @test count(==('\n'), out) == 0          # ONE line, not one per redraw
        @test startswith(out, "t 100%|")         # the last frame won
        @test endswith(out, "Time: 0:00:00")
        @test !occursin("50%", out)              # earlier frames overwritten, not stacked
    end

    @testset "ProgressMeter — showvalues block" begin
        out = cook_terminal(PM_SHOWVALUES)
        lines = split(out, '\n')
        @test length(lines) == 3                 # bar + two value lines, redrawn in place
        @test startswith(lines[1], "t 100%|")
        @test lines[2] == "    i: 3"
        @test lines[3] == "   sq: 9"
        @test !occursin("i: 2", out)
        @test !occursin('\e', out)
    end

    @testset "ProgressMeter — indeterminate" begin
        out = cook_terminal(PM_UNKNOWN)
        @test out == "scan: 3    Time: 0:00:00"
    end

    @testset "carriage return and backspace" begin
        @test cook_terminal("abc\rX") == "Xbc"            # overwrite from column 0
        @test cook_terminal("abc\rXYZ\n") == "XYZ"
        @test cook_terminal("abc\b\bX") == "aXc"          # character-level overwrite
        @test cook_terminal("abc\b\b\b\b\bX") == "Xbc"    # backspace clamps at column 0
        @test cook_terminal("long\rab\e[K") == "ab"       # erase-to-EOL drops the leftover
        @test cook_terminal("long\rab") == "abng"         # ...without it, the tail survives
    end

    @testset "cursor movement" begin
        @test cook_terminal("one\ntwo\n\e[Ax") == "one\nxwo"      # up
        # Vertical moves keep the COLUMN: after `\n` that's 0, so the write lands on top of "a".
        @test cook_terminal("a\n\e[Ab") == "b"
        @test cook_terminal("abc\e[2Dx") == "axc"                 # left 2 from col 3 → over "b"
        @test cook_terminal("a\e[3Cb") == "a   b"                 # right N pads with blanks
        @test cook_terminal("abcdef\e[3Gx") == "abxdef"           # absolute column (1-based)
        @test cook_terminal("x\e[2;3Hy") == "x\n  y"              # absolute position
        @test cook_terminal("a\e[Bb") == "a\n b"                  # down keeps the column
    end

    @testset "erase" begin
        @test cook_terminal("abcdef\e[3G\e[K") == "ab"            # to end of line
        @test cook_terminal("abcdef\e[3G\e[1K") == "   def"       # to start of line
        @test cook_terminal("abcdef\e[2K") == ""                  # whole line
        @test cook_terminal("a\nb\nc\e[A\e[J") == "a\nb"          # to end of screen
        @test cook_terminal("a\nb\nc\e[2Jz") == "z"               # whole screen
    end

    @testset "SGR survives, everything else is consumed" begin
        # Colour is appearance, not position: it has to reach the renderer.
        @test cook_terminal("\e[31mred\e[0m\n") == "\e[31mred\e[0m"
        @test cook_terminal("\e[1;32mbold green\e[0m\n") == "\e[1;32mbold green\e[0m"
        @test cook_terminal("\e[38;5;208m256\e[0m\n") == "\e[38;5;208m256\e[0m"
        @test cook_terminal("\e[38;2;10;20;30mtrue\e[0m\n") == "\e[38;2;10;20;30mtrue\e[0m"

        # Colour follows the CHARACTER, so a redraw carries the winning frame's colour.
        @test cook_terminal("\e[31mold\r\e[32mnew\e[0m") == "\e[32mnew\e[0m"

        # Sequences that aren't SGR never reach the page, even unmodelled ones.
        for noise in ("\e[?25l", "\e[?25h", "\e]0;a title\a", "\e]8;;http://x\e\\", "\e7", "\e=")
            @test cook_terminal(string(noise, "text")) == "text"
        end
        @test !occursin('\e', cook_terminal("\e[?25labc\e[?25h"))
    end

    @testset "incremental feeding matches one-shot" begin
        # The live stream arrives in arbitrary chunks; a split escape sequence or UTF-8 character
        # must not corrupt the screen. Split at EVERY byte offset and compare.
        for src in (PM_SIMPLE, PM_SHOWVALUES, PM_UNKNOWN, "\e[31mred\e[0m\nplain\n", "∑∫🎉\rx")
            want = cook_terminal(src)
            b = collect(codeunits(src))
            for cut in 1:(length(b) - 1)
                s = TermScreen()
                feed!(s, String(b[1:cut]))
                feed!(s, String(b[(cut + 1):end]))
                @test screen_text(s) == want
            end
        end
    end

    @testset "byte-at-a-time feeding matches one-shot" begin
        for src in (PM_SHOWVALUES, "\e[38;2;1;2;3mx\e[0m∑\n")
            s = TermScreen()
            for byte in codeunits(src)
                feed!(s, String([byte]))
            end
            @test screen_text(s) == cook_terminal(src)
        end
    end

    @testset "bounded against runaway cursor moves" begin
        # A confused library asking for 10^6 lines must not allocate 10^6 lines.
        s = cook_terminal(string("x", "\e[999999B", "y"))
        @test count(==('\n'), s) <= _TC_MAX_SCROLL
        w = cook_terminal(string("x", "\e[999999C", "y"))
        @test length(w) <= _TC_MAX_COLS + 8
        # An escape sequence that never terminates must not buffer forever waiting for a final byte —
        # past a sane length it's abandoned as a stray ESC so later output still gets through.
        scr = TermScreen()
        feed!(scr, string("\e[", "9"^500))
        @test length(scr.pending) <= 128
        feed!(scr, "\ntail")
        @test occursin("tail", screen_text(scr))
        # ...whereas a WELL-FORMED sequence is consumed whole, however long its parameters: `t` is a
        # real CSI final byte, so this is one sequence and nothing but the text survives.
        @test cook_terminal(string("\e[", "9"^200, "ttail")) == "tail"
    end

    @testset "a long OSC payload is not abandoned as a stray ESC" begin
        # OSC carries a payload — a hyperlink URL, a window title — and can easily outrun the length
        # at which an unterminated CSI is written off. Judged at the same threshold, a hyperlink
        # split across two chunks would have its ESC dropped and its URL printed as output.
        url = "http://example.com/" * "p"^900
        src = string("\e]8;;", url, "\e\\shown\e]8;;\e\\ after")
        @test cook_terminal(src) == "shown after"
        b = collect(codeunits(src))                       # ...and the same when it arrives split
        for cut in (4, 40, 500, length(b) - 3)
            s = TermScreen()
            feed!(s, String(b[1:cut])); feed!(s, String(b[(cut + 1):end]))
            @test screen_text(s) == "shown after"
        end
    end

    @testset "the grid is bounded, and says so" begin
        # Redrawing in place is what the cooker is FOR, and it must stay free however long it runs:
        # the bar overwrites cells it already owns, so the grid never grows past one line.
        s = TermScreen()
        for i in 1:20_000
            feed!(s, string("\rprogress ", i, "/20000"))
        end
        @test s.cells <= _TC_MAX_COLS
        @test !s.full
        @test screen_text(s) == "progress 20000/20000"

        # Genuinely new content DOES grow it, and past the budget the replay keeps consuming rather
        # than allocating. Asserted on the counters (filling 4M cells for real is a slow test).
        g = TermScreen()
        g.cells = _TC_MAX_CELLS
        feed!(g, "overrun\n\e[31mand this\e[0m")
        @test g.full
        @test occursin("too much output", screen_text(g))
        @test !occursin("overrun", screen_text(g)) && !occursin("and this", screen_text(g))
        @test !occursin('\e', screen_text(g))      # the colour was consumed, not left in the text

        # A row runaway is capped the same way, and the cursor stays on the last line rather than
        # running off the end of the grid.
        r = TermScreen()
        feed!(r, "\n"^(_TC_MAX_ROWS + 50) * "tail")
        @test length(r.rows) <= _TC_MAX_ROWS
        @test r.full && occursin("tail", screen_text(r))

        # Erasure gives the budget back — a screen cleared and rewritten must not leak toward the cap.
        e = TermScreen()
        feed!(e, "a"^500)
        used = e.cells
        feed!(e, "\e[2J")
        @test e.cells == 0
        feed!(e, "b"^500)
        @test e.cells == used && !e.full
    end

    @testset "screen_text renders only the tail when asked" begin
        # What the live stream samples ten times a second. Rendering the whole transcript each time
        # would grow with the output; the view only ever shows the end of it.
        s = TermScreen()
        feed!(s, join(["line $i" for i in 1:500], "\n"))
        whole = screen_text(s)
        tail = screen_text(s; last_rows = 10)
        @test count(==('\n'), tail) == 10                  # 10 lines + the elision marker
        @test startswith(tail, "…\n") && endswith(tail, "line 500")
        @test !occursin("line 489", tail) && occursin("line 491", tail)
        @test screen_text(s; last_rows = 10_000) == whole  # more rows than exist → no marker
        # Colour is re-established per line, so a tail never inherits a run it cut away from.
        c = TermScreen()
        feed!(c, "\e[31mred one\nred two")
        @test screen_text(c; last_rows = 1) == "…\n\e[31mred two\e[0m"
    end

    @testset "strip_sgr and keep_sgr_only" begin
        @test strip_sgr("\e[31mred\e[0m") == "red"
        @test strip_sgr("plain") == "plain"
        @test strip_sgr("\e[1;38;5;9mx\e[0m") == "x"
        # keep_sgr_only is the complement: colour stays, everything else goes. It is what protects a
        # renderer handed text that never went through the cooker.
        @test keep_sgr_only("\e[31mred\e[0m") == "\e[31mred\e[0m"
        @test keep_sgr_only("a\e[2Jb\e[1;3Hc") == "abc"
        @test keep_sgr_only("x\e]0;title\ay") == "xy"
        @test keep_sgr_only("\e[31ma\e[Kb\e[0m") == "\e[31mab\e[0m"
        @test keep_sgr_only("plain") == "plain"
        # strip_ansi is the pair to it: nothing survives, for a renderer that styles the text itself.
        @test strip_ansi("\e[31mred\e[0m") == "red"
        @test strip_ansi("a\e[2Jb\e]0;t\ac") == "abc"
        @test strip_ansi("plain") == "plain"
    end
end
