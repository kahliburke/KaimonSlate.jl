# Terminal control-sequence replay for captured cell output (companion to capture.jl).
#
# Libraries that redraw in place — ProgressMeter, Pkg, Downloads, anything with a spinner —
# emit carriage returns, backspaces and CSI cursor moves instead of plain lines. Dropped into a
# `<pre>` those become a cascade of redraw frames, one line per update, because HTML treats a
# bare `\r` as a line break. This replays the stream onto a small grid of lines and reports what
# a terminal would be SHOWING, so a progress bar reads as the single line it was meant to be.
#
# It is NOT a terminal emulator: no scrollback, no alternate screen, no line wrapping, no modes,
# no tab stops beyond the default 8. It models a cursor over a grid and the sequences redrawing
# libraries actually use. The grid holds every line the cell produced (it is a transcript, not a
# viewport) — capture.jl's existing character cap is what bounds the size.
#
# Colour is the one thing that survives. SGR (`\e[…m`) sets appearance rather than position, so
# it is recorded per character and re-emitted canonically; every OTHER sequence is consumed and
# dropped once replayed. That gives the renderer a contract worth relying on:
#
#     after cooking, the only escape sequences left in the text are SGR.
#
# So `render.jl` needs one small SGR parser rather than a second escape-code implementation, and
# a sequence this file doesn't model can never leak into the page as visible garbage.
#
# Incremental by construction: `feed!` takes arbitrary byte chunks and carries a split escape
# sequence or a split UTF-8 character over in `pending`, so ONE screen serves both the live
# stream (fed as output arrives) and the final capture. Base-only and self-contained — included
# by the engine AND the gate worker, like capture.jl.

# A cursor move can't grow the grid without bound: `\e[9999B` from a confused library would
# otherwise allocate 9999 lines.
const _TC_MAX_COLS = 10_000     # widest line a cursor move may reach
const _TC_MAX_SCROLL = 500      # most lines one relative cursor-down may create

# The whole grid is bounded too. A `TCell` costs 16 bytes and every line is its own `Vector`, so an
# ungoverned grid is an order of magnitude larger than the string it was built from — and capture.jl's
# `_MAX_OUT_CHARS` can't be that ceiling, because it is applied to the RESULT, after cooking.
#
# What makes a tight budget affordable is that redrawing in place does not grow the grid: a progress
# bar overwrites cells it already owns, so a cell streaming megabytes of bar frames never approaches
# this no matter how long it runs. Only genuinely new content grows it — and 100k characters of that
# is already all the display keeps. Past the budget the replay keeps CONSUMING (so no escape sequence
# can leak into the text as a side effect of giving up) and stops growing; `screen_text` then says so,
# which is visible in the saved full output where the loss would otherwise be silent.
const _TC_MAX_ROWS = 200_000    # lines the grid will hold
const _TC_MAX_CELLS = 4_000_000 # characters the grid will hold, across all lines

# Character appearance. `fg`/`bg`: -1 = terminal default, 0..255 = palette index, and ≥256 packs
# a 24-bit colour as `256 + (r<<16 | g<<8 | b)` so truecolour survives the round trip instead of
# being flattened to the nearest palette entry. `flags` is a bitfield so `TAttr` stays isbits and
# a grid cell costs no allocation.
struct TAttr
    fg::Int32
    bg::Int32
    flags::UInt8
end
const TC_BOLD      = 0x01
const TC_DIM       = 0x02
const TC_ITALIC    = 0x04
const TC_UNDERLINE = 0x08
const TC_REVERSE   = 0x10
const TC_STRIKE    = 0x20
const _TC_PLAIN = TAttr(Int32(-1), Int32(-1), 0x00)

struct TCell
    ch::Char
    attr::TAttr
end
const _TC_BLANK = TCell(' ', _TC_PLAIN)

"""
    TermScreen()

A grid of lines plus a cursor, fed with `feed!` and read back with `screen_text`. Retains the
whole transcript (every line written), not a fixed-height viewport.
"""
mutable struct TermScreen
    rows::Vector{Vector{TCell}}
    row::Int              # 0-based cursor row
    col::Int              # 0-based cursor column
    attr::TAttr           # appearance applied to characters written now
    pending::Vector{UInt8}  # trailing partial escape / UTF-8 char awaiting more bytes
    cells::Int            # cells currently held across all rows (the memory budget, see _TC_MAX_CELLS)
    full::Bool            # budget reached — content has been dropped
end
TermScreen() = TermScreen([TCell[]], 0, 0, _TC_PLAIN, UInt8[], 0, false)

# ── Grid primitives ──────────────────────────────────────────────────────────

# The line the cursor is on, creating intervening lines as needed. Every caller wants the CURRENT
# row, so the clamp lives here: past the row budget the cursor stays on the last line and further
# output overwrites there rather than growing the grid.
function _tc_cur!(s::TermScreen)
    if s.row >= _TC_MAX_ROWS
        s.full = true
        s.row = _TC_MAX_ROWS - 1
    end
    while length(s.rows) <= s.row
        push!(s.rows, TCell[])
    end
    return s.rows[s.row + 1]
end

function _tc_put!(s::TermScreen, ch::Char)
    s.col >= _TC_MAX_COLS && return nothing
    line = _tc_cur!(s)
    if s.col < length(line)           # overwriting a cell the grid already owns — free, and the
        line[s.col + 1] = TCell(ch, s.attr)   # case a redrawing library spends all its time in
        s.col += 1
        return nothing
    end
    if s.cells >= _TC_MAX_CELLS       # budget spent — keep consuming, stop growing
        s.full = true
        return nothing
    end
    while length(line) < s.col        # pad a gap left by a cursor jump past the line end
        push!(line, _TC_BLANK); s.cells += 1
    end
    push!(line, TCell(ch, s.attr)); s.cells += 1
    s.col += 1
    return nothing
end

_tc_newline!(s::TermScreen) = (s.row += 1; s.col = 0; _tc_cur!(s); nothing)

# ── Escape-sequence parsing ──────────────────────────────────────────────────

# Decode the UTF-8 character starting at `b[i]`; `nothing` if the continuation bytes are invalid.
function _tc_decode(b::Vector{UInt8}, i::Int, len::Int)
    len == 1 && return Char(b[i])
    cp = UInt32(b[i] & (0xff >> (len + 1)))
    for k in 1:(len - 1)
        c = b[i + k]
        (c & 0xc0) == 0x80 || return nothing
        cp = (cp << 6) | UInt32(c & 0x3f)
    end
    return Char(cp)
end

function _tc_charlen(b::UInt8)
    b < 0x80         && return 1
    (b & 0xe0) == 0xc0 && return 2
    (b & 0xf0) == 0xe0 && return 3
    (b & 0xf8) == 0xf0 && return 4
    return 1                       # stray continuation byte — skip it
end

# `par` is a CSI parameter string ("", "2", "1;31"). Numeric field `k`, or `dflt` when absent/empty.
function _tc_param(par::AbstractString, k::Int, dflt::Int)
    isempty(par) && return dflt
    i = 1
    for f in split(par, ';')
        if i == k
            isempty(f) && return dflt
            v = tryparse(Int, f)
            return v === nothing ? dflt : v
        end
        i += 1
    end
    return dflt
end

# Apply one SGR parameter string to `a`. Unknown parameters are ignored rather than reset, so a
# sequence we don't model leaves the rest of the appearance intact.
function _tc_sgr(a::TAttr, par::AbstractString)
    fields = isempty(par) ? [""] : split(par, ';')
    fg, bg, flags = a.fg, a.bg, a.flags
    i = 1
    while i <= length(fields)
        f = fields[i]
        n = isempty(f) ? 0 : something(tryparse(Int, f), -1)
        if n == 0
            fg, bg, flags = Int32(-1), Int32(-1), 0x00
        elseif n == 1;  flags |= TC_BOLD
        elseif n == 2;  flags |= TC_DIM
        elseif n == 3;  flags |= TC_ITALIC
        elseif n == 4;  flags |= TC_UNDERLINE
        elseif n == 7;  flags |= TC_REVERSE
        elseif n == 9;  flags |= TC_STRIKE
        elseif n == 22; flags &= ~(TC_BOLD | TC_DIM)
        elseif n == 23; flags &= ~TC_ITALIC
        elseif n == 24; flags &= ~TC_UNDERLINE
        elseif n == 27; flags &= ~TC_REVERSE
        elseif n == 29; flags &= ~TC_STRIKE
        elseif 30 <= n <= 37;  fg = Int32(n - 30)
        elseif 90 <= n <= 97;  fg = Int32(n - 90 + 8)      # bright foreground
        elseif 40 <= n <= 47;  bg = Int32(n - 40)
        elseif 100 <= n <= 107; bg = Int32(n - 100 + 8)    # bright background
        elseif n == 39; fg = Int32(-1)
        elseif n == 49; bg = Int32(-1)
        elseif n == 38 || n == 48                          # extended colour
            mode = i + 1 <= length(fields) ? something(tryparse(Int, fields[i + 1]), -1) : -1
            if mode == 5 && i + 2 <= length(fields)        # 256-colour palette
                idx = something(tryparse(Int, fields[i + 2]), -1)
                0 <= idx <= 255 && (n == 38 ? (fg = Int32(idx)) : (bg = Int32(idx)))
                i += 2
            elseif mode == 2 && i + 4 <= length(fields)    # 24-bit r;g;b
                r = clamp(something(tryparse(Int, fields[i + 2]), 0), 0, 255)
                g = clamp(something(tryparse(Int, fields[i + 3]), 0), 0, 255)
                bl = clamp(something(tryparse(Int, fields[i + 4]), 0), 0, 255)
                packed = Int32(256 + (r << 16) + (g << 8) + bl)
                n == 38 ? (fg = packed) : (bg = packed)
                i += 4
            end
        end
        i += 1
    end
    return TAttr(fg, bg, flags)
end

_tc_drop!(s::TermScreen, line::Vector{TCell}) = (s.cells -= length(line); empty!(line); nothing)

function _tc_erase_line!(s::TermScreen, mode::Int)
    line = _tc_cur!(s)
    if mode == 0                                  # cursor → end of line
        s.col < length(line) && (s.cells -= length(line) - s.col; resize!(line, s.col))
    elseif mode == 1                              # start of line → cursor (inclusive)
        for k in 1:min(s.col + 1, length(line))
            line[k] = _TC_BLANK
        end
    elseif mode == 2
        _tc_drop!(s, line)
    end
    return nothing
end

function _tc_erase_display!(s::TermScreen, mode::Int)
    if mode == 0                                  # cursor → end of screen
        _tc_erase_line!(s, 0)
        if length(s.rows) > s.row + 1
            for r in (s.row + 2):length(s.rows)
                s.cells -= length(s.rows[r])
            end
            resize!(s.rows, s.row + 1)
        end
    elseif mode == 1                              # start of screen → cursor
        for r in 1:s.row
            _tc_drop!(s, s.rows[r])
        end
        _tc_erase_line!(s, 1)
    elseif mode == 2 || mode == 3
        s.rows = [TCell[]]
        s.row = 0
        s.col = 0
        s.cells = 0
    end
    return nothing
end

# Act on a parsed CSI sequence. Private-mode sequences (`\e[?25l`, cursor hide/show) are consumed
# and ignored — they affect a real terminal's chrome, not the text.
function _tc_csi!(s::TermScreen, par::AbstractString, final::Char)
    (!isempty(par) && (par[1] == '?' || par[1] == '>' || par[1] == '<')) && return nothing
    if final == 'm'
        s.attr = _tc_sgr(s.attr, par)
    elseif final == 'A'
        s.row = max(0, s.row - _tc_param(par, 1, 1))
    elseif final == 'B'
        s.row += min(_tc_param(par, 1, 1), _TC_MAX_SCROLL); _tc_cur!(s)
    elseif final == 'C'
        s.col = min(_TC_MAX_COLS, s.col + _tc_param(par, 1, 1))
    elseif final == 'D'
        s.col = max(0, s.col - _tc_param(par, 1, 1))
    elseif final == 'E'
        s.row += min(_tc_param(par, 1, 1), _TC_MAX_SCROLL); s.col = 0; _tc_cur!(s)
    elseif final == 'F'
        s.row = max(0, s.row - _tc_param(par, 1, 1)); s.col = 0
    elseif final == 'G' || final == '`'
        s.col = max(0, _tc_param(par, 1, 1) - 1)
    elseif final == 'H' || final == 'f'
        # Absolute positioning is relative to the START of the capture: there is no viewport to be
        # absolute against, and a cell's output begins at the top of its own transcript.
        s.row = max(0, _tc_param(par, 1, 1) - 1)
        s.col = max(0, _tc_param(par, 2, 1) - 1)
        _tc_cur!(s)
    elseif final == 'K'
        _tc_erase_line!(s, _tc_param(par, 1, 0))
    elseif final == 'J'
        _tc_erase_display!(s, _tc_param(par, 1, 0))
    end
    return nothing
end

# Handle the escape sequence starting at `b[i]`. Returns bytes consumed, or 0 when the sequence is
# truncated and the rest has yet to arrive.
function _tc_escape!(s::TermScreen, b::Vector{UInt8}, i::Int, n::Int)
    i + 1 > n && return 0
    c = b[i + 1]
    if c == UInt8('[')                                   # CSI — parameters, intermediates, final
        j = i + 2
        while j <= n && 0x30 <= b[j] <= 0x3f; j += 1; end
        while j <= n && 0x20 <= b[j] <= 0x2f; j += 1; end
        j > n && return 0
        _tc_csi!(s, String(@view b[(i + 2):(j - 1)]), Char(b[j]))
        return j - i + 1
    elseif c == UInt8(']') || c in (UInt8('P'), UInt8('X'), UInt8('^'), UInt8('_'))
        # OSC/DCS/SOS/PM/APC — a string payload (window title, an OSC-8 hyperlink) terminated by
        # BEL or ST. Consumed whole: the payload is addressed to a terminal, not to the reader.
        j = i + 2
        while j <= n
            b[j] == 0x07 && return j - i + 1
            if b[j] == 0x1b
                j + 1 > n && return 0
                b[j + 1] == UInt8('\\') && return j + 2 - i
            end
            j += 1
        end
        return 0
    end
    return 2                                             # two-byte escape (ESC 7, ESC =, …) — drop
end

# How long an INCOMPLETE sequence may hold the buffer before `feed!` judges it a stray ESC rather
# than a truncation. A CSI is a handful of bytes; OSC and DCS carry a payload — a hyperlink URL, a
# window title — and legitimately run long, so giving up on one at the same threshold would emit
# somebody's URL into the text as if it were output.
function _tc_escape_wait(b::Vector{UInt8}, i::Int, n::Int)
    i + 1 > n && return 128
    c = b[i + 1]
    return (c == UInt8(']') || c in (UInt8('P'), UInt8('X'), UInt8('^'), UInt8('_'))) ? 8192 : 128
end

# ── Feeding and reading back ─────────────────────────────────────────────────

"""
    feed!(screen, chunk) -> screen

Replay `chunk` onto `screen`. Chunks may split anywhere — a partial escape sequence or UTF-8
character is held back until the bytes that complete it arrive.
"""
function feed!(s::TermScreen, chunk::AbstractString)
    b = s.pending
    append!(b, codeunits(String(chunk)))
    n = length(b)
    i = 1
    while i <= n
        c = b[i]
        if c == 0x1b
            adv = _tc_escape!(s, b, i, n)
            if adv == 0
                # Incomplete — wait, unless the "sequence" has grown implausible, in which case it
                # is a stray ESC rather than a truncation and holding the buffer would stall output.
                n - i + 1 <= _tc_escape_wait(b, i, n) && break
                i += 1
            else
                i += adv
            end
        elseif c == 0x0a
            _tc_newline!(s); i += 1
        elseif c == 0x0d
            s.col = 0; i += 1
        elseif c == 0x08
            s.col = max(0, s.col - 1); i += 1
        elseif c == 0x09
            s.col = min(_TC_MAX_COLS, (s.col ÷ 8 + 1) * 8); i += 1
        elseif c < 0x20 || c == 0x7f
            i += 1                                        # other C0 / DEL — not modelled
        else
            len = _tc_charlen(c)
            i + len - 1 > n && break                      # split UTF-8 character — wait
            ch = _tc_decode(b, i, len)
            ch === nothing ? (i += 1) : (_tc_put!(s, ch); i += len)
        end
    end
    deleteat!(b, 1:(i - 1))
    return s
end

# Emit the canonical SGR sequence moving from `from` to `to` (""  when they match).
function _tc_sgr_delta(from::TAttr, to::TAttr)
    from == to && return ""
    to == _TC_PLAIN && return "\e[0m"
    parts = String[]
    # Turning an attribute OFF individually is possible but not worth the states — reset, then
    # restate. Progress output changes appearance rarely, so the extra bytes are noise.
    from == _TC_PLAIN || push!(parts, "0")
    (to.flags & TC_BOLD)      != 0 && push!(parts, "1")
    (to.flags & TC_DIM)       != 0 && push!(parts, "2")
    (to.flags & TC_ITALIC)    != 0 && push!(parts, "3")
    (to.flags & TC_UNDERLINE) != 0 && push!(parts, "4")
    (to.flags & TC_REVERSE)   != 0 && push!(parts, "7")
    (to.flags & TC_STRIKE)    != 0 && push!(parts, "9")
    for (v, base, ext) in ((to.fg, 30, 38), (to.bg, 40, 48))
        v < 0 && continue
        if v < 8
            push!(parts, string(base + v))
        elseif v < 16
            push!(parts, string(base + 60 + (v - 8)))
        elseif v < 256
            push!(parts, string(ext), "5", string(v))
        else
            rgb = v - 256
            push!(parts, string(ext), "2", string((rgb >> 16) & 0xff),
                  string((rgb >> 8) & 0xff), string(rgb & 0xff))
        end
    end
    return isempty(parts) ? "" : string("\e[", join(parts, ';'), "m")
end

"""
    screen_text(screen; last_rows = 0) -> String

What the screen is showing: lines joined with `\\n`, trailing blank cells and trailing blank
lines dropped, and SGR re-emitted around runs that share an appearance. The only escape
sequences in the result are SGR.

`last_rows` renders only that many lines from the bottom, marking the elision with a leading `…`.
`feed!` is incremental, but this is not — it walks the whole grid — so a caller that samples a
screen repeatedly while it grows (the live stream) would otherwise pay for the entire transcript on
every sample. It only ever displays the tail, so that is all it should ask for.
"""
function screen_text(s::TermScreen; last_rows::Int = 0)
    last_row = length(s.rows)
    while last_row > 0 && isempty(s.rows[last_row])
        last_row -= 1
    end
    first_row = (last_rows > 0 && last_row > last_rows) ? last_row - last_rows + 1 : 1
    io = IOBuffer()
    first_row > 1 && print(io, "…\n")
    for r in first_row:last_row
        line = s.rows[r]
        stop = length(line)
        while stop > 0 && line[stop] == _TC_BLANK       # trailing padding a terminal wouldn't show
            stop -= 1
        end
        cur = _TC_PLAIN
        for k in 1:stop
            cell = line[k]
            cell.attr == cur || (print(io, _tc_sgr_delta(cur, cell.attr)); cur = cell.attr)
            print(io, cell.ch)
        end
        cur == _TC_PLAIN || print(io, "\e[0m")
        r < last_row && print(io, '\n')
    end
    s.full && print(io, "\n\n… ⚠ too much output to replay — the rest was dropped.")
    return String(take!(io))
end

# Nothing to replay unless the text carries a control character that MOVES or ERASES. The common
# case — ordinary `println` output — takes this path and is returned byte-identical, so cooking
# every stream costs one scan and changes nothing for cells that never redraw.
_tc_needs_cook(s::AbstractString) = any(c -> c == '\r' || c == '\b' || c == '\e' || c == '\f', s)

"""
    cook_terminal(text) -> String

Replay `text`'s cursor movement and erasure and return what a terminal would be showing. Text
with nothing to replay is returned unchanged. SGR is preserved; every other escape sequence is
consumed.
"""
function cook_terminal(text::AbstractString)
    s = String(text)
    _tc_needs_cook(s) || return s
    return screen_text(feed!(TermScreen(), s))
end

"""
    strip_sgr(text) -> String

Drop SGR sequences, for consumers that render no colour (Typst/PDF export, plain-text tooling).
"""
strip_sgr(text::AbstractString) = replace(String(text), r"\e\[[0-9;:]*m" => "")

# Every escape sequence, in the three shapes that occur: a string payload (OSC/DCS/SOS/PM/APC)
# terminated by BEL or ST, a CSI, and a bare two-byte escape. Mirrored by `ANY_ESC` in ansi.js.
const _ANY_ESC = r"\e[\]P^_X][^\a\e]*(?:\a|\e\\)?|\e\[[0-9;:?<>=!]*[\x40-\x7e]|\e[\x40-\x5f]"
_is_sgr(m::AbstractString) = length(m) > 2 && m[2] == '[' && last(m) == 'm'

"""
    keep_sgr_only(text) -> String

Drop every escape sequence that is not SGR. Cooked text already satisfies this, so it is a defence
for text that reached a renderer WITHOUT being cooked — output stored before cooking existed, or a
remote worker on an older build — where a raw escape byte would otherwise land in the page.
"""
keep_sgr_only(text::AbstractString) =
    replace(String(text), _ANY_ESC => m -> _is_sgr(m) ? m : "")

"""
    strip_ansi(text) -> String

Drop every escape sequence, colour included. For a renderer that applies its OWN styling to the
text — the error message is syntax-coloured and the backtrace dimmed — where incoming colour is
redundant at best and interleaves with that markup at worst.
"""
strip_ansi(text::AbstractString) = replace(String(text), _ANY_ESC => "")
