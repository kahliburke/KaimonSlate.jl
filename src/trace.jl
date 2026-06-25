# `@trace` — value tracing (interactivity Layer 3, sibling of tables.jl). Shared by the engine
# AND the gate worker (both `include` it before `widgets.jl`), so there is exactly one trace
# implementation and both namespaces get an identical `@trace`.
#
# `@trace begin … end` rewrites the block so that every top-level assignment records
# `(line, name, value-repr)` into a hidden buffer, and the cell STILL RETURNS ITS REAL LAST
# VALUE (so a traced cell shows its normal output — a number, a plot, …). The buffer is published
# on a per-notebook sink (`__slate_trace_sink`, injected like `__slate_bind_sink`); `run_capture`
# reads it into the wire `trace` field, and the frontend renders it in the inspector popup. The
# user's own assignments stay at cell scope (NO `let` wrapper) so the dependency model is
# unchanged. Loops/ifs/lets/trys are recursed into, so each iteration of a `for` is captured.
#
# Values are snapshotted to a *string* AT THE RECORDING POINT (`_trace_show`) — a later mutation
# of a binding can't rewrite an earlier row, and the trace holds no live references. Base-only so
# it loads cleanly into the standalone worker, like widgets.jl / tables.jl.

# Augmented-assignment heads (`x += 1` …) — the lhs is read-modify-written, so we record it
# just like a plain `=` when the lhs is a bare symbol.
const _TRACE_AUG_ASSIGN = Set{Symbol}([:(+=), :(-=), :(*=), :(/=), :(//=), :(\=), :(^=), :(%=),
    :(&=), :(|=), :(⊻=), :(>>=), :(<<=), :(>>>=), :(÷=)])

# Structural heads left OPAQUE — we don't peer inside a def/import and never record one as a value.
const _TRACE_OPAQUE = Set{Symbol}([:function, :(->), :struct, :macro, :module, :abstract,
    :primitive, :using, :import, :export, :quote, :toplevel])

# Snapshot a value as a bounded COMPACT string AT the recording point. We use the 2-arg `show`
# (the `repr` form, e.g. `[1, 2]`) rather than `MIME"text/plain"` (which renders arrays multi-line)
# — trace rows want one compact line per value. `invokelatest` so a `show` method a cell just
# defined/imported is honoured (the world-age reason capture.jl documents). Never throws.
function _trace_show(x)
    try
        s = Base.invokelatest(sprint, show, x; context = :limit => true)
        s = replace(s, '\n' => ' ')
        return length(s) > 300 ? first(s, 299) * "…" : s
    catch
        return "?"
    end
end

# Convert the recorded buffer (tuples) to the JSON-safe wire form carried in `run_capture`'s
# `trace` field (a Dict per row, like the `tables` field) — JSON-encoded server-side.
_trace_wire(rows) = Any[Dict{String,Any}("line" => l, "name" => n, "value" => v) for (l, n, v) in rows]

# ── AST transform ─────────────────────────────────────────────────────────────
# `_trace_transform(blk)` → a `begin … end` that allocates a gensym'd buffer, PUBLISHES it on
# `__slate_trace_sink` (so `run_capture` can read the rows), runs the rewritten user code
# recording as it goes, and ENDS IN THE USER'S LAST VALUE (captured into `res`). `_trace_show`
# is spliced as an object; `__slate_trace_sink` resolves in the notebook module (injected const).
function _trace_transform(blk)
    buf = gensym(:slate_trace)
    res = gensym(:slate_result)
    stmts = (blk isa Expr && blk.head === :block) ? blk.args : Any[blk]
    out = Any[:($buf = Tuple{Int,String,String}[]),
              :(__slate_trace_sink[] = $buf),        # the buffer mutates in place — run_capture reads it
              :($res = nothing)]
    _trace_into!(out, stmts, buf, res; toplevel = true)
    push!(out, res)                                  # the traced cell returns its REAL last value
    return Expr(:block, out...)
end

# Record `(line, label, _trace_show(valexpr))` into the buffer.
_trace_push!(out, line::Int, label::AbstractString, valexpr, buf) =
    push!(out, :(push!($buf, ($line, $(String(label)), $(_trace_show)($valexpr)))))

# Walk a statement list, threading the current source line. `toplevel` marks the OUTERMOST block,
# whose LAST meaningful statement's value becomes the cell's return value (`res`) and is recorded
# as the "result" row. Inner-block trailing values (a loop body's last expr) are discarded by Julia.
function _trace_into!(out, stmts, buf, res; toplevel::Bool = false)
    lastmeaningful = findlast(s -> !(s isa LineNumberNode), stmts)
    line = 0
    for (i, s) in enumerate(stmts)
        if s isa LineNumberNode
            line = s.line
            push!(out, s)
        else
            _trace_one!(out, s, line, buf, res, toplevel && i === lastmeaningful)
        end
    end
    return out
end

# Rebuild `ex` with its body block (its last arg) recursively traced; the non-body args
# (loop variable, condition, let bindings) pass through untouched.
function _trace_body(ex::Expr, buf, res)
    body = ex.args[end]
    newbody = Expr(:block)
    _trace_into!(newbody.args, body isa Expr && body.head === :block ? body.args : Any[body], buf, res)
    return Expr(ex.head, ex.args[1:end-1]..., newbody)
end

# Trace each clause of an if/elseif chain: the condition passes through; the then-block (and any
# else/elseif at the tail) is recursed into.
function _trace_if(ex::Expr, buf, res)
    args = Any[ex.args[1]]                                  # condition
    for a in ex.args[2:end]
        if a isa Expr && (a.head === :elseif || a.head === :if)
            push!(args, _trace_if(a, buf, res))
        elseif a isa Expr && a.head === :block
            nb = Expr(:block); _trace_into!(nb.args, a.args, buf, res); push!(args, nb)
        else
            nb = Expr(:block); _trace_into!(nb.args, Any[a], buf, res); push!(args, nb)
        end
    end
    return Expr(ex.head, args...)
end

# Record the bound name(s) of an assignment lhs: a bare symbol, a typed `x::T`, or the symbol
# components of a destructuring `(a, b) = …`. Indexed/field assignments are skipped (no single
# name), but the assignment still runs. Returns the bound symbol if a single bare/typed name (for
# capturing the cell's final value), else `nothing`.
function _trace_record_lhs!(out, lhs, line, buf)
    if lhs isa Symbol
        _trace_push!(out, line, string(lhs), lhs, buf); return lhs
    elseif lhs isa Expr && lhs.head === :(::) && lhs.args[1] isa Symbol
        _trace_push!(out, line, string(lhs.args[1]), lhs.args[1], buf); return lhs.args[1]
    elseif lhs isa Expr && lhs.head === :tuple
        for el in lhs.args
            el isa Symbol && _trace_push!(out, line, string(el), el, buf)
        end
    end
    return nothing
end

# Emit `res = <symbol>` so the OUTERMOST block returns the cell's real final value.
_trace_setres!(out, res, sym) = sym === nothing || push!(out, :($res = $sym))

function _trace_one!(out, s, line::Int, buf, res, isfinal::Bool)
    if s isa Expr && s.head === :(=)
        push!(out, s)
        sym = _trace_record_lhs!(out, s.args[1], line, buf)
        isfinal && _trace_setres!(out, res, sym)
    elseif s isa Expr && s.head in _TRACE_AUG_ASSIGN
        push!(out, s)
        sym = s.args[1] isa Symbol ? s.args[1] : nothing
        sym === nothing || _trace_push!(out, line, string(sym), sym, buf)
        isfinal && _trace_setres!(out, res, sym)
    elseif s isa Expr && (s.head === :local || s.head === :global) &&
           length(s.args) == 1 && s.args[1] isa Expr && s.args[1].head === :(=)
        # `local x = …` / `global x = …` (used in loops to disambiguate soft scope): record the
        # bound name. Bare `local x` / `local a, b` declarations carry no value → emitted as-is below.
        push!(out, s)
        sym = _trace_record_lhs!(out, s.args[1].args[1], line, buf)
        isfinal && _trace_setres!(out, res, sym)
    elseif s isa Expr && (s.head === :for || s.head === :while || s.head === :let)
        push!(out, _trace_body(s, buf, res))                # value is nothing (for/while) — res stays
    elseif s isa Expr && (s.head === :if || s.head === :elseif)
        push!(out, _trace_if(s, buf, res))
    elseif s isa Expr && s.head === :block
        _trace_into!(out, s.args, buf, res)
    elseif s isa Expr && s.head === :try
        push!(out, _trace_try(s, buf, res))
    elseif s isa Expr && s.head in _TRACE_OPAQUE
        push!(out, s)                                       # defs/imports: opaque, never recorded
    elseif isfinal
        push!(out, :($res = $s))                            # bare trailing expression → the cell's value
        _trace_push!(out, line, "result", res, buf)
    else
        push!(out, s)
    end
    return out
end

# try/catch/finally: recurse into the try body, the catch body (keeping the `catch err` var), and
# the finally body. `try` args are `[try-block, catchvar, catch-block, (finally-block)]`.
function _trace_try(ex::Expr, buf, res)
    args = Vector{Any}(undef, length(ex.args))
    for (i, a) in enumerate(ex.args)
        if a isa Expr && a.head === :block
            nb = Expr(:block); _trace_into!(nb.args, a.args, buf, res); args[i] = nb
        else
            args[i] = a                                     # catch-var symbol / `false` slots
        end
    end
    return Expr(:try, args...)
end
