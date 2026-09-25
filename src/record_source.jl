# ── Where a record's field came from, in the cell's own source ─────────────────────────────────
# Clicking a field in a rendered record points back at the text that produced it. What to point at
# depends on what the field IS:
#
#   (; f0, ζ)              shorthand — the field name IS the variable, so point at it
#   (; f0 = measured)      a variable — point at `measured`, the thing that was put in
#   (; f0 = fit(x).freq)   an expression — point at the whole expression
#   (; f0 = 1006.6)        a literal — nothing was "used to assign", so point at the tuple itself
#
# Tokens, not a parse tree: `JuliaSyntax.tokenize` gives byte ranges directly, and finding a field
# inside a tuple literal needs only paren depth. A parse tree would give the same answer and then
# have to be mapped back to bytes anyway. Anything unexpected returns `nothing`, and the caller
# simply does not highlight — a wrong range is worse than none, since it points the reader at code
# that had nothing to do with the value.

# Tokens that carry no structure, skipped when looking for "the next real token".
_rs_skip(ks) = ks in ("Whitespace", "NewlineWs", "Comment")

# Is this token part of a literal value? A number is one token and a string is three (the quotes
# tokenize separately), so counting tokens would call one a literal and the other an expression.
function _rs_literal(JS, t)
    k = JS.kind(t)
    ks = string(k)
    return JS.is_number(k) || occursin("String", ks) || occursin("Char", ks) ||
           ks in ("\"", "`", "true", "false", ":")
end

"""
    record_field_span(source, field) -> (from, to) | nothing

The byte range in `source` to highlight for record field `field` (a dotted path uses its FIRST
segment — a nested record's fields live in their own tuple and the outer one is what this cell
wrote). 1-based and inclusive, so `source[from:to]` is the text.
"""
function record_field_span(source::AbstractString, field::AbstractString)
    name = String(first(split(String(field), '.'; keepempty = false), 1)[1])
    isempty(name) && return nothing
    JS = Base.JuliaSyntax
    toks = try; collect(JS.tokenize(String(source))); catch; return nothing; end
    isempty(toks) && return nothing
    cu = codeunits(String(source))
    txt(t) = String(cu[t.range])
    ks(t) = string(JS.kind(t))
    sig = [i for i in eachindex(toks) if !_rs_skip(ks(toks[i]))]   # indices of significant tokens
    isempty(sig) && return nothing

    # Paren depth per significant token, and the index of the `(` that opened each depth.
    depth = 0
    opener = Int[]                       # stack of significant-token indices of open brackets
    open_at = Dict{Int,Int}()            # significant position -> index of its opening bracket
    depth_at = zeros(Int, length(sig))
    for (p, i) in enumerate(sig)
        k = ks(toks[i])
        if k in ("(", "[", "{")
            depth += 1; push!(opener, i)
        end
        depth_at[p] = depth
        open_at[p] = isempty(opener) ? 0 : last(opener)
        if k in (")", "]", "}")
            depth -= 1; isempty(opener) || pop!(opener)
        end
    end

    for (p, i) in enumerate(sig)
        (ks(toks[i]) == "Identifier" && txt(toks[i]) == name) || continue
        prev = p > 1 ? ks(toks[sig[p-1]]) : ""
        prev in ("(", ";", ",") || continue          # only a FIELD position, not a use of the name
        # `foo(a = 1)` puts `a` in the same position as a field, and highlighting a call's keyword
        # argument would point at code that produced nothing. A bracket opening a CALL or an INDEX
        # follows a name or a closing bracket; a tuple literal's does not.
        # The token IMMEDIATELY before, with no whitespace skipped: a call or an index writes its
        # bracket flush against the name (`foo(`, `v[i](`), so a gap means this is a tuple literal.
        # Skipping whitespace here would read the `)` ending the PREVIOUS statement as a callee.
        let ob = open_at[p]
            ob == 0 && continue
            ob > 1 && ks(toks[ob-1]) in ("Identifier", ")", "]", "}") && continue
        end
        nxt = p < length(sig) ? ks(toks[sig[p+1]]) : ""
        if nxt in (",", ")", ";")                    # `(; f0, ζ)` — the name is the variable
            return (Int(first(toks[i].range)), Int(last(toks[i].range)))
        end
        nxt == "=" || continue                       # not `f0 = …`; keep looking
        # The value runs from the token after `=` to just before the `,`/`)` that closes this field.
        d = depth_at[p]
        vs = p + 2
        vs <= length(sig) || return nothing
        ve = vs
        while ve <= length(sig)
            k, dd = ks(toks[sig[ve]]), depth_at[ve]
            # A closing bracket records the depth of what it CLOSES, so the tuple's own `)` reads at
            # `d` rather than below it. Without it in this set the last field's value runs off the end.
            (dd == d && k in (",", ";", ")", "]", "}")) && break
            (dd < d) && break
            ve += 1
        end
        ve -= 1
        ve >= vs || return nothing
        # A lone identifier is "the variable which was used", so point at it. A literal is not — a
        # number and a quoted string differ only in how many tokens they take, so the test is on
        # KIND, and either way the tuple expression is what gets highlighted.
        if ve == vs && ks(toks[sig[vs]]) == "Identifier"
            return (Int(first(toks[sig[vs]].range)), Int(last(toks[sig[vs]].range)))
        elseif all(q -> _rs_literal(JS, toks[sig[q]]), vs:ve)
            ob = open_at[p]
            ob == 0 && return nothing
            cb = _rs_close(toks, ks, ob)
            cb === nothing && return nothing
            return (Int(first(toks[ob].range)), Int(last(toks[cb].range)))
        end
        return (Int(first(toks[sig[vs]].range)), Int(last(toks[sig[ve]].range)))
    end
    return nothing
end

"""
    record_field_range(source, field) -> (from, to) | nothing

`record_field_span` translated to what the editor indexes by: JS string offsets, `from` inclusive
and `to` exclusive, zero-based. CodeMirror counts UTF-16 units and Julia counts bytes, so a cell
with `ζ` or an emoji above the tuple would otherwise highlight a range sliding left of the text.
"""
function record_field_range(source::AbstractString, field::AbstractString)
    sp = record_field_span(source, field)
    sp === nothing && return nothing
    s = String(source)
    bfrom, bto = sp
    u = 0; jsfrom = -1; jsto = -1
    for (i, c) in pairs(s)
        i == bfrom && (jsfrom = u)
        w = ncodeunits(c) > 3 ? 2 : 1          # astral planes take two UTF-16 units
        i + ncodeunits(c) - 1 >= bto && jsto < 0 && i <= bto && (jsto = u + w)
        u += w
    end
    (jsfrom < 0 || jsto < 0) && return nothing
    return (jsfrom, jsto)
end

# The bracket closing the one at token index `ob`.
function _rs_close(toks, ks, ob::Int)
    d = 0
    for i in ob:length(toks)
        k = ks(toks[i])
        k in ("(", "[", "{") && (d += 1)
        if k in (")", "]", "}")
            d -= 1
            d == 0 && return i
        end
    end
    return nothing
end
