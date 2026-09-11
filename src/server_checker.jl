# ── The checker — a specialist that nobody summons ────────────────────────────────────────────────
#
# Every other specialist is SUMMONED: someone decides it is needed, hands it a subject, supervises
# it, and ends it. This one is triggered by something happening — the notebook agent finished a turn
# — has no supervisor, and reports instead of being asked. That is a second lifecycle on the same
# framework rather than a second role, which is the whole reason it is worth building: if the
# `Specialist` abstraction only fits agents you summon, it is a debugging feature with delusions.
#
# THE RISK IS NOISE, not capability. A reviewer that comments on everything gets muted within an
# hour and is then strictly worse than nothing, because it still costs tokens. So the design leans
# the other way at every point: read-only verbs, a brief that says silence is the normal answer, a
# floor on how often it may speak, and a hard requirement to name a cell and a reason. If it cannot
# say WHICH cell is wrong and WHY, it says nothing.

"What the checker may reach: everything needed to read a notebook, and nothing that changes it."
const CHECKER_VERBS = String["read", "view", "inspect", "api", "search_docs", "check_ok", "check_flag"]

const CHECKER_ROLE = "checker"

const CHECKER_BRIEF = """
You review a Slate notebook's recent changes for correctness problems. You are not the notebook's
author and not its editor: you cannot change anything, and you are not asked to improve style.

SAYING NOTHING IS THE NORMAL ANSWER. Most turns introduce no defect and deserve no comment. A
reviewer that remarks on every change is muted within a day, and then the one real finding it had
goes unread with the rest. Call `check_ok` and stop unless you have found something specific.

Report only what you can point at:
  • a cell whose result contradicts what its code says it computes
  • a change that breaks a cell downstream of it
  • a value, unit, index or boundary that is wrong on the evidence in front of you
  • something asserted in prose that the notebook's own output does not support

Do NOT report: style, naming, structure, missing tests, "you could also…", or anything you would
have to run the notebook differently to know. You have read access only, and a guess dressed as a
finding is worse than silence because it costs the reader the time to check it.

When you do report, `check_flag(cell, what)` — one cell, one sentence on what is wrong, and the
evidence you saw. The person reads this between their own turns; it has to be worth the
interruption on its own.
"""

# ── when it runs ──────────────────────────────────────────────────────────────────────────────────

const CHECKER_ON = Ref(false)
const _CHECKER_PERSIST = Ref{Any}(nothing)
# A floor on how often it may be woken. Without one, a burst of short agent turns wakes it once
# each, and the reviews queue behind work that has already moved on.
const CHECKER_MIN_GAP = Ref(90.0)
const _CHECKER_LAST = Dict{String,Float64}()
# Cells changed since the checker last looked. A turn ending is not the signal — a turn can end
# having changed nothing, and a person editing a cell changes something with no turn at all. What
# means "there is work to review" is a mutation.
const _CHECKER_DIRTY = Dict{String,Set{String}}()
# When the last mutation landed, so a run of edits can settle before anything reads them.
const _CHECKER_TOUCHED = Dict{String,Float64}()
# How long a notebook must sit still before an unsupervised review is worth doing. Reviewing while
# someone is still typing means reviewing half-finished work, which is exactly the case a reviewer
# cannot tell from wrong work.
const CHECKER_QUIET = Ref(20.0)

# What each cell's source was when the checker last looked, so a persist can say WHICH cells moved.
const _CHECKER_SEEN = Dict{String,Dict{String,String}}()

"""
Note that the notebook was saved, and work out what changed.

Hooked to the persist rather than to the agent's cell tools: a persist is where EVERY mutation
ends up, whoever made it. An agent editing a cell, a person typing in the browser and a file
changing on disk are the same event here, and a reviewer that only saw the agent's edits would
miss the ones most worth reviewing — the ones nobody else reviewed either.

Marks only. What wakes the checker is the notebook going quiet, so a burst of edits becomes one
review of the finished state rather than one review per keystroke of a state nobody was looking at.
"""
function note_persist!(nb::LiveNotebook)
    checker_on() || return nothing
    changed = String[]
    lock(_SPEC_LOCK) do
        seen = get!(() -> Dict{String,String}(), _CHECKER_SEEN, nb.id)
        live = Dict{String,String}()
        for c in nb.report.cells
            live[c.id] = String(c.source)
            get(seen, c.id, nothing) == String(c.source) || push!(changed, c.id)
        end
        for id in keys(seen)                      # a cell that is gone is a change too
            haskey(live, id) || push!(changed, id)
        end
        _CHECKER_SEEN[nb.id] = live
        # The FIRST persist after the checker is switched on establishes the baseline rather than
        # reporting the whole notebook as new work.
        isempty(seen) && (changed = String[])
        isempty(changed) && return nothing
        union!(get!(() -> Set{String}(), _CHECKER_DIRTY, nb.id), changed)
        _CHECKER_TOUCHED[nb.id] = time()
        return true
    end === nothing && return nothing
    _schedule_checker!(nb)
    return nothing
end

const _CHECKER_ARMED = Dict{String,Bool}()

"Wait for the notebook to stop changing, then review it. One waiter per notebook."
function _schedule_checker!(nb::LiveNotebook)
    lock(_SPEC_LOCK) do
        get(_CHECKER_ARMED, nb.id, false) && return nothing
        _CHECKER_ARMED[nb.id] = true
        return true
    end === nothing && return nothing
    @async try
        while true
            sleep(CHECKER_QUIET[] / 2)
            quiet, busy = lock(_SPEC_LOCK) do
                (time() - get(_CHECKER_TOUCHED, nb.id, 0.0), nb.agent_busy)
            end
            # Still being edited, or the agent is mid-turn: its work is not finished, and half of
            # it reads as broken.
            (quiet < CHECKER_QUIET[] || busy) && continue
            break
        end
        nudge_checker!(nb)
    catch e
        @debug "slate: checker schedule failed" exception = e
    finally
        lock(_SPEC_LOCK) do; _CHECKER_ARMED[nb.id] = false; end
    end
    return nothing
end

checker_on()::Bool = CHECKER_ON[]

function set_checker_on!(on::Bool)
    CHECKER_ON[] = on
    p = _CHECKER_PERSIST[]
    p === nothing || (try; p(on); catch e; @warn "slate: could not persist the checker setting" exception = e; end)
    return on
end

"""
Wake the checker, if it is on and enough time has passed.

Called when the notebook agent finishes a turn. Detached and swallowed: a reviewer is an optional
extra, and nothing about the agent's turn may wait on it or fail because of it.
"""
function nudge_checker!(nb::LiveNotebook)
    checker_on() || return nothing
    now = time()
    changed = lock(_SPEC_LOCK) do
        d = get(_CHECKER_DIRTY, nb.id, Set{String}())
        isempty(d) && return nothing                       # nothing changed: nothing to review
        get(_CHECKER_LAST, nb.id, 0.0) + CHECKER_MIN_GAP[] > now && return nothing
        _CHECKER_LAST[nb.id] = now
        c = sort!(collect(d)); empty!(d); c
    end
    changed === nothing && return nothing
    @async try
        specialist_here(nb, CHECKER_ROLE) == "" ?
            summon!(nb, CHECKER_ROLE; subject = "", task = _checker_task(nb, changed)) :
            tell!(nb, CHECKER_ROLE, _checker_task(nb, changed))
    catch e
        @debug "slate: checker nudge failed" exception = e
    end
    return nothing
end

"What changed since it last looked — the whole of what it is asked to review."
function _checker_task(nb::LiveNotebook, changed::Vector{String})
    io = IOBuffer()
    println(io, "These cells changed since you last looked: ", join(changed, ", "), ".")
    println(io, "Review them, and anything downstream they could have broken.")
    println(io)
    cells = nb.report.cells
    println(io, "Cells, newest state: ", length(cells), " total.")
    for c in cells
        c.kind == CODE || continue
        err = c.output !== nothing && c.output.exception !== nothing
        println(io, "  ", c.id, err ? "  [ERRORED]" : "", "  ", first(replace(strip(c.source), '\n' => " ⏎ "), 90))
    end
    println(io)
    println(io, "Read what you need with `read`. If nothing is wrong, call `check_ok` and stop.")
    return String(take!(io))
end

# ── how it reports ────────────────────────────────────────────────────────────────────────────────
#
# Two verbs, because a reviewer needs to be able to say NOTHING IS WRONG as a positive act. Without
# `check_ok` the only way to finish is silence, and silence is indistinguishable from a crash, a
# stall, or a model that lost the thread — so the person learns to ignore the whole thing.

"The last thing the checker said about a notebook, newest first."
const _CHECKS = Dict{String,Vector{Dict{String,Any}}}()
const CHECKS_MAX = 50

checks_json(nb::LiveNotebook) = lock(_SPEC_LOCK) do
    copy(get(_CHECKS, nb.id, Dict{String,Any}[]))
end

function _record_check!(nb::LiveNotebook, rec::Dict{String,Any})
    rec["at"] = time() * 1000
    lock(_SPEC_LOCK) do
        v = get!(() -> Dict{String,Any}[], _CHECKS, nb.id)
        pushfirst!(v, rec)
        length(v) > CHECKS_MAX && resize!(v, CHECKS_MAX)
    end
    broadcast_specialist(nb, CHECKER_ROLE, Dict{String,Any}("check" => rec))
    return rec
end

"""
    checker_ok!(nb, note) -> Dict

The checker looked and found nothing. Recorded rather than discarded: "reviewed, clean" is
information, and it is the only thing that distinguishes a working reviewer from a dead one.
"""
checker_ok!(nb::LiveNotebook, note::AbstractString = "") =
    _record_check!(nb, Dict{String,Any}("kind" => "ok", "note" => String(strip(note))))

"""
    checker_flag!(nb, cell, what) -> Dict

The checker found something. `cell` is required — a finding that cannot point at a cell is an
opinion, and the reader has no way to act on it.
"""
function checker_flag!(nb::LiveNotebook, cell::AbstractString, what::AbstractString)
    isempty(strip(cell)) && return Dict{String,Any}("ok" => false, "error" => "a finding has to name a cell")
    isempty(strip(what)) && return Dict{String,Any}("ok" => false, "error" => "a finding has to say what is wrong")
    return _record_check!(nb, Dict{String,Any}("kind" => "flag", "cell" => String(strip(cell)),
                                               "what" => String(strip(what))))
end

register_specialist!(Specialist(CHECKER_ROLE; brief = CHECKER_BRIEF, verbs = CHECKER_VERBS,
                                briefing = (nb, subject, task) -> task))
