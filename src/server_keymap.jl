# ── The user's keymap, on disk ────────────────────────────────────────────────
#
# `~/.config/kaimonslate/keymap.json` (wherever `SlateHome` puts the config home), holding the chosen
# preset and a sparse overlay of the bindings changed by hand:
#
#     {"preset": "vscode",
#      "bindings": {"cell.run": ["Mod-Enter"], "nb.runStale": []}}
#
# Its own file rather than a key in `slate.json`. This one is written by a person in the Keyboard
# panel, on every rebind, while slate.json is written by the hub itself, so keeping them apart stops a
# keymap save racing a port or worker-threads write and clobbering it. It is also the piece of
# configuration most likely to be read, hand-edited and copied between machines, which wants a small
# file with nothing else in it.
#
# Server-side rather than localStorage, which is where every other editor preference lives, because a
# keymap should survive a different browser and a cleared cache. localStorage still mirrors it: that is
# what lets the first keystroke after a reload work without waiting for a round trip, and it is the
# only store a static export or an app-mode page has.
#
# The bindings themselves are NOT interpreted here. Whether `Mod-Shift-k` is a legal chord, which
# command ids exist and which chords the browser refuses to give up are all front-end knowledge
# (keymap.js, commands.js, keymaps.js), and duplicating any of it in Julia would create a second
# opinion to keep in sync. What this validates is the SHAPE, so a malformed body cannot write a file
# that breaks the page on the next load.

_keymap_path() = joinpath(SlateHome.config_home(), "keymap.json")

# Bounds on what we will store. Generous next to any real keymap (about sixty commands, one or two
# chords each) and small enough that a runaway or hostile PUT cannot fill the config directory.
const _KEYMAP_MAX_IDS = 500
const _KEYMAP_MAX_CHORDS = 8       # per command; more than this is a mistake, not a keymap
const _KEYMAP_MAX_LEN = 120        # characters in one chord or id

"""
    keymap_config() -> Dict{String,Any}

The stored keymap, or the empty default (`preset = "slate"`, no overrides). Never throws. An
unreadable file means someone hand-edited it into invalid JSON, and the notebook should still open, on
the default keymap.
"""
function keymap_config()
    f = _keymap_path()
    isfile(f) || return Dict{String,Any}("preset" => "slate", "bindings" => Dict{String,Any}())
    cfg = try
        JSON.parsefile(f)
    catch e
        @warn "slate: keymap.json is unreadable — falling back to the default keymap" path = f exception = e
        return Dict{String,Any}("preset" => "slate", "bindings" => Dict{String,Any}())
    end
    return _keymap_clean(cfg)
end

# Coerce whatever was parsed into the shape the front end expects, dropping anything that isn't it.
# A hand-edited file is the normal way this gets malformed, so a bad entry is skipped and the rest of
# the file is kept.
function _keymap_clean(cfg)::Dict{String,Any}
    cfg isa AbstractDict || return Dict{String,Any}("preset" => "slate", "bindings" => Dict{String,Any}())
    preset = get(cfg, "preset", "slate")
    preset = preset isa AbstractString && length(preset) <= _KEYMAP_MAX_LEN ? String(preset) : "slate"
    raw = get(cfg, "bindings", nothing)
    out = Dict{String,Any}()
    if raw isa AbstractDict
        for (id, chords) in raw
            length(out) >= _KEYMAP_MAX_IDS && break
            (id isa AbstractString && !isempty(id) && length(id) <= _KEYMAP_MAX_LEN) || continue
            # `[]` is MEANINGFUL: the panel writes it to say "this command is unbound", as distinct
            # from an absent key, which means "inherit the preset". So an empty vector is kept, and
            # only a non-list value is dropped.
            chords isa AbstractVector || continue
            keep = String[]
            for c in chords
                length(keep) >= _KEYMAP_MAX_CHORDS && break
                (c isa AbstractString && !isempty(strip(c)) && length(c) <= _KEYMAP_MAX_LEN) || continue
                push!(keep, String(strip(c)))
            end
            out[String(id)] = keep
        end
    end
    return Dict{String,Any}("preset" => preset, "bindings" => out)
end

"""
    keymap_config!(cfg) -> Dict{String,Any}

Validate and persist a keymap, returning what was stored. Written whole rather than merged: the body
IS the user's keymap, and merging would make a removed binding unremovable.
"""
function keymap_config!(cfg)
    clean = _keymap_clean(cfg)
    try
        mkpath(SlateHome.config_home())
        # Write-then-rename, so a save interrupted part way leaves the previous file intact rather
        # than a truncated one.
        tmp = _keymap_path() * ".tmp"
        write(tmp, JSON.json(clean, 2))
        mv(tmp, _keymap_path(); force = true)
    catch e
        @warn "slate: could not persist keymap.json" exception = e
    end
    return clean
end
