# Tool calls as cell values — `slate_tool` / `@tool` / `slate_tools`.
#
# A tool cell calls a Kaimon MCP tool, any tool the Kaimon server has: its own (`ping`,
# `qdrant_list_collections`) and every extension's (`fusionkb.search`, named `<namespace>.<tool>`).
# The call goes through the server's service endpoint, the same registry an agent reaches over
# MCP, so a tool call becomes an ordinary cell value with a rich rendering: an action an agent took
# is a durable, inspectable, re-runnable part of the document instead of something that happened
# off-page. Tools registered in this worker's own gate (`KaimonGate.serve(tools=…)`) are the
# fallback, for names the server does not know.
#
# What the rendering shows is deliberately more than the call: every parameter the tool DECLARES,
# its type, whether it is required, and whether this call supplied it. A tool's schema is the part
# a caller usually cannot see, and it is what makes a wrong call obvious.
#
# Dependency-free on KaimonGate, like animation.jl is on Colors: only the WORKER process loads the
# gate, while this file is shared with the in-process engine, so the module is resolved at CALL
# time out of `Base.loaded_modules` and every access is guarded.

const _GATE_PKGID = Base.PkgId(Base.UUID("5ee84a8c-75bd-412f-a7b8-4e6463aa635f"), "KaimonGate")

_gate_module() = get(Base.loaded_modules, _GATE_PKGID, nothing)

"""Every gate tool registered in this session, or an empty vector when no gate is loaded."""
function _session_tools()
    g = _gate_module()
    g === nothing && return Any[]
    try
        # The registry sits behind an accessor; `_SESSION_TOOLS` is the older gate's global.
        isdefined(g, :_session_tools) && return collect(Base.invokelatest(getfield(g, :_session_tools)))
        isdefined(g, :_SESSION_TOOLS) && return collect(getfield(g, :_SESSION_TOOLS)[])
    catch
    end
    return Any[]
end

_find_tool(name::AbstractString) =
    (i = findfirst(t -> getfield(t, :name) == name, _session_tools());
     i === nothing ? nothing : _session_tools()[i])

# ── Tools on the Kaimon server ───────────────────────────────────────────────────────────────────

"""A tool the Kaimon server serves: registry name, description and JSON-schema parameters."""
struct ServerTool
    name::String
    description::String
    parameters::Dict{String,Any}
end

"""Every tool the Kaimon server serves, or an empty vector when there is no gate or no server."""
function _server_tools()
    g = _gate_module()
    (g === nothing || !isdefined(g, :list_tools)) && return ServerTool[]
    try
        return [ServerTool(string(t.name), string(t.description), Dict{String,Any}(t.parameters))
                for t in Base.invokelatest(getfield(g, :list_tools))]
    catch
        return ServerTool[]
    end
end

_find_server_tool(name::AbstractString, tools = _server_tools()) =
    (i = findfirst(t -> t.name == name, tools); i === nothing ? nothing : tools[i])

"""
The panel's parameter rows for a server tool, in the shape the gate's own reflection produces, read
off its JSON schema. The schema carries JSON types only, so `kind` is what the controls get.
"""
function _server_tool_meta(t::ServerTool)
    props = get(t.parameters, "properties", Dict{String,Any}())
    required = Set(String.(get(t.parameters, "required", String[])))
    args = Dict{String,Any}[]
    for (k, v) in props
        kind = v isa AbstractDict ? String(get(v, "type", "any")) : "any"
        push!(args, Dict{String,Any}("name" => String(k), "required" => k in required,
            "is_kwarg" => !(k in required), "type_meta" => Dict{String,Any}("kind" => kind)))
    end
    sort!(args; by = a -> (!a["required"], a["name"]))
    return Dict{String,Any}("name" => t.name, "description" => t.description, "arguments" => args)
end

"""
A follow-up a reply names is usually bare (`job_status`) even when the tool that replied is an
extension's (`fusionkb.ingest`), because the tool does not know the namespace it is served under.
Resolve a bare name the server does not know to the replying tool's namespace.
"""
function _qualify_followup(called::AbstractString, caller::AbstractString, tools = _server_tools())
    (occursin('.', called) || _find_server_tool(called, tools) !== nothing) && return String(called)
    dot = findlast('.', caller)
    dot === nothing && return String(called)
    qualified = caller[1:dot] * called
    return _find_server_tool(qualified, tools) === nothing ? String(called) : qualified
end

"Reflected metadata for one tool: its description and full declared parameter list."
function _tool_meta(tool)
    g = _gate_module()
    (g === nothing || !isdefined(g, :_reflect_tool)) &&
        return Dict{String,Any}("name" => getfield(tool, :name), "description" => "", "arguments" => [])
    try
        return Base.invokelatest(getfield(g, :_reflect_tool), tool)
    catch
        return Dict{String,Any}("name" => getfield(tool, :name), "description" => "", "arguments" => [])
    end
end

# A gate tool's docstring conventionally OPENS with a fenced signature block, so "the first line"
# is a ``` fence and the line after it is the signature. The first line worth showing is the first
# non-empty one outside any fence.
function _first_prose_line(doc::AbstractString)
    infence = false
    for ln in split(doc, '\n')
        s = strip(ln)
        if startswith(s, "```")
            infence = !infence
            continue
        end
        (infence || isempty(s)) && continue
        return String(s)
    end
    return ""
end

_param_type(a) = begin
    tm = get(a, "type_meta", nothing)
    tm isa AbstractDict ? String(get(tm, "julia_type", get(tm, "kind", "any"))) : "any"
end

# ── What a reply advertises as its next call ─────────────────────────────────────────────────────
#
# A tool that starts work in the background cannot return its outcome, so it returns a HANDLE and
# names the call that reads it:
#
#     started job a1b2c3d4. Poll `job_status(job_id="a1b2c3d4")`;
#     stop with `job_cancel(job_id="a1b2c3d4")`.
#
# That sentence is already a contract, so the panel reads it rather than being told about any one
# tool: a backticked call inside a result is a FOLLOW-UP, and one the surrounding prose asks you to
# POLL is the call that tracks the work to completion. This is what makes a cell recording such a
# call a live view of the work it started instead of a record of the reply that started it, without
# anything here knowing what kind of work any tool does.

"""One call a tool's reply names as the next step: `poll` marks the one that tracks the work."""
struct FollowUp
    name::String
    args::Vector{Pair{String,String}}
    poll::Bool
end

const _FOLLOWUP_CALL = r"`([A-Za-z_][A-Za-z0-9_!]*)\(([^`()]*)\)`"
const _FOLLOWUP_ARG = r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:\"([^\"]*)\"|([^,\s]+))"

"""Every backticked call a result advertises, in the order stated, deduplicated."""
function _followups(text::AbstractString; limit::Int = 4)
    out = FollowUp[]
    isempty(text) && return out
    for m in eachmatch(_FOLLOWUP_CALL, text)
        args = Pair{String,String}[]
        for a in eachmatch(_FOLLOWUP_ARG, m.captures[2])
            v = a.captures[2] === nothing ? String(a.captures[3]) : String(a.captures[2])
            push!(args, String(a.captures[1]) => v)
        end
        # Only the prose distinguishes "poll this until it finishes" from "here is another thing
        # you may want to do", and it is stated in the CLAUSE introducing the call. Take the text
        # back to the last clause boundary rather than a fixed number of characters: a window wide
        # enough to hold one clause also reaches back into the previous one, so "Poll `a`; stop
        # with `b`" marked both as polls once a tool name grew by a character.
        before = text[1:prevind(text, m.offset)]
        bound = findlast(c -> c in ('.', ';', '\n'), before)
        lead = bound === nothing ? before : before[nextind(before, bound):end]
        fu = FollowUp(String(m.captures[1]), args, occursin(r"poll"i, lead))
        any(f -> f.name == fu.name && f.args == fu.args, out) && continue
        push!(out, fu)
        length(out) >= limit && break
    end
    return out
end

# Where a poll got to. `status` is the conventional field name and `_result_fields` already
# recovers it from either record shape; a reply that does not say is polled ONCE and then left to
# the reader, rather than guessed at on a timer forever.
const _RUNNING_STATES = ("running", "starting", "queued", "pending", "in_progress", "active")

function _poll_state(text::AbstractString)
    for (k, v) in _result_fields(text)
        lowercase(k) == "status" || continue
        return lowercase(strip(v)) in _RUNNING_STATES ? "running" : "done"
    end
    return "unknown"
end

# ── The value a tool call produces ───────────────────────────────────────────────────────────────

"""
    ToolCall

One invocation of a session tool: what was called, with what, what came back, and how long it
took. Returned by [`slate_tool`](@ref) and rendered as a panel rather than a string, so the call
and its schema stay legible in the document after the fact.
"""
struct ToolCall
    name::String
    args::Vector{Pair{String,Any}}      # what THIS call supplied, in the order given
    params::Vector{Dict{String,Any}}    # what the tool DECLARES (reflected schema)
    description::String
    ok::Bool
    result::String
    error::String
    seconds::Float64
    at::String
    channel::String                     # JS→Julia channel for re-invoking from the panel ("" = inert)
    followups::Vector{FollowUp}         # the next calls this reply named (see above)
end

# Positional-light constructors. The follow-ups are READ OFF the result rather than passed in, so
# every way of building a ToolCall gets them; a hand-built one (tests, a caller with no gate) also
# needs no channel and simply renders without the Invoke control.
ToolCall(name, args, params, description, ok, result, error, seconds, at, channel) =
    ToolCall(name, args, params, description, ok, result, error, seconds, at, channel,
             ok ? _followups(result) : FollowUp[])
ToolCall(name, args, params, description, ok, result, error, seconds, at) =
    ToolCall(name, args, params, description, ok, result, error, seconds, at, "")

"""
    tool_handle(tc::ToolCall) -> Union{String, Nothing}

The identifier a tool handed back, recovered from the follow-up call its reply names.

Work that runs in the background returns a handle rather than an outcome, and states the call that
reads it. This picks that handle out, so a cell can thread it onward instead of copying it by eye:

```julia
job = @tool start_job(size = 12)
@tool job_status(job_id = tool_handle(job))
```

`nothing` when the reply names no follow-up carrying an id.
"""
function tool_handle(tc::ToolCall)
    for f in tc.followups, (k, v) in f.args
        (k == "id" || endswith(k, "_id")) && return v
    end
    return nothing
end

"""
    slate_tool(name; kwargs...) -> ToolCall

Call a Kaimon MCP tool by name, and return the call as a value.

`name` is the tool's name on the Kaimon server: a Kaimon tool (`"ping"`) or an extension's,
qualified by its namespace (`"fusionkb.search"`). These are the tools an agent sees over MCP, so a
notebook and an agent act on the same things. A name the server does not know is looked up among
the tools registered in this worker's own gate, whose dispatcher coerces arguments against the
handler's signature.

    slate_tool("fusionkb.search"; query = "bootstrap current", limit = 5)

`@tool` is the same thing in call syntax. `slate_tools()` lists what is available.
"""
slate_tool(name::AbstractString; kwargs...) = slate_tool(name, _kw_pairs(kwargs))

"""Register the panel's call-back path and return its channel (`""` when there is nowhere to
register, which renders an inert panel).

The browser calls back on this channel with the edited parameters, so re-running a tool never needs
the CELL to re-run, which matters because a cell re-run would also re-execute everything downstream
of it. One handler serves the panel's whole surface: Invoke re-fires this tool, and a follow-up
button fires the tool the reply named by passing `__tool`, so a tracked run stays on the channel the
cell already registered."""
function _register_invoke!(handlers, name::AbstractString)
    handlers === nothing && return ""
    channel = "__tool:" * String(name)
    handlers[channel] = function (a)
        called = _qualify_followup(String(_payload_get(a, "__tool", name)), name)
        supplied = Pair{String,Any}[]
        for (k, v) in pairs(a)
            startswith(String(k), "__") && continue          # a panel control key, not an argument
            sv = v isa AbstractString ? String(v) : v
            (sv isa AbstractString && isempty(strip(sv))) && continue
            push!(supplied, String(k) => _parse_arg(sv))
        end
        tc = slate_tool(called, supplied)
        text = tc.ok ? tc.result : tc.error
        return (ok = tc.ok, seconds = tc.seconds, at = tc.at, text = text,
                tool = called, state = tc.ok ? _poll_state(text) : "done")
    end
    return channel
end

function slate_tool(name::AbstractString, args::AbstractVector; handlers = nothing)
    args = Pair{String,Any}[String(first(p)) => last(p) for p in args]
    at = _clock_now()
    server = _server_tools()
    st = _find_server_tool(name, server)
    st === nothing || return _call_server_tool(st, args, at, handlers)
    tool = _find_tool(name)
    if tool === nothing
        _gate_module() === nothing && return ToolCall(String(name), args, Dict{String,Any}[], "", false, "",
            "No Kaimon gate is loaded in this process, so there is no tool to call.", 0.0, at)
        isempty(server) && isempty(_session_tools()) && return ToolCall(String(name), args,
            Dict{String,Any}[], "", false, "",
            "No tools reachable: the Kaimon server did not answer and this session registers none.", 0.0, at)
        near = sort!(filter(n -> occursin(lowercase(split(name, '.')[end]), lowercase(n)),
                            [[t.name for t in server]; [getfield(t, :name) for t in _session_tools()]]))
        return ToolCall(String(name), args, Dict{String,Any}[], "", false, "",
                        "No tool named `$name` on the Kaimon server or in this session." *
                        (isempty(near) ? "" : " Similar: " * join(first(near, 12), ", ")), 0.0, at)
    end

    channel = _register_invoke!(handlers, name)
    meta = _tool_meta(tool)
    params = Vector{Dict{String,Any}}(get(meta, "arguments", Dict{String,Any}[]))
    desc = String(get(meta, "description", ""))

    g = _gate_module()
    argdict = Dict{String,Any}(k => v for (k, v) in args)
    t0 = time()
    # Suppress the agent-call recorder for the duration of this dispatch. `slate_tool` goes through
    # the SAME handler an agent's call does, so without this a `@tool` cell would append a second
    # cell recording itself on every run.
    try
        res = task_local_storage(_IN_CELL_TOOLCALL, true) do
            Base.invokelatest(getfield(g, :_dispatch_tool_call), getfield(tool, :handler),
                              argdict; tool_name = String(name))
        end
        return ToolCall(String(name), args, params, desc, true, _as_text(res), "",
                        round(time() - t0, digits = 3), at, channel)
    catch e
        return ToolCall(String(name), args, params, desc, false, "",
                        sprint(showerror, e), round(time() - t0, digits = 3), at, channel)
    end
end

"""
Call a tool on the Kaimon server through its service endpoint. The server resolves the name against
its full registry and runs the handler (an extension's in that extension's process), coercing the
arguments as it does for an agent's call.
"""
function _call_server_tool(st::ServerTool, args, at, handlers)
    channel = _register_invoke!(handlers, st.name)
    meta = _server_tool_meta(st)
    params = Vector{Dict{String,Any}}(meta["arguments"])
    argdict = Dict{String,Any}(k => v for (k, v) in args)
    t0 = time()
    try
        res = Base.invokelatest(getfield(_gate_module(), :call_tool), Symbol(st.name), argdict)
        return ToolCall(st.name, args, params, st.description, true, _as_text(res), "",
                        round(time() - t0, digits = 3), at, channel)
    catch e
        return ToolCall(st.name, args, params, st.description, false, "",
                        sprint(showerror, e), round(time() - t0, digits = 3), at, channel)
    end
end

# Values arrive from the browser as strings. A gate tool's own dispatcher coerces against the
# handler signature, so the only job here is to recover the literals a text input cannot carry —
# numbers and booleans — and leave everything else as the string it is.
function _parse_arg(v)
    v isa AbstractString || return v
    s = strip(String(v))
    s == "true" && return true
    s == "false" && return false
    n = tryparse(Int, s)
    n === nothing || return n
    f = tryparse(Float64, s)
    f === nothing || return f
    return String(v)
end

# The browser's payload arrives as a Dict or a NamedTuple depending on the bridge, so read it by
# iteration rather than assuming either one's `get`.
function _payload_get(a, key::AbstractString, default)
    for (k, v) in pairs(a)
        String(k) == key && return v
    end
    return default
end

_kw_pairs(kwargs) = Pair{String,Any}[String(k) => v for (k, v) in kwargs]
_as_text(x) = x isa AbstractString ? String(x) : sprint(show, MIME("text/plain"), x)

# Wall clock as HH:MM:SS without pulling in Dates (which the worker env need not have loaded).
function _clock_now()
    s = floor(Int, time()) % 86400
    return string(lpad(s ÷ 3600, 2, '0'), ":", lpad((s ÷ 60) % 60, 2, '0'), ":", lpad(s % 60, 2, '0'))
end

"""
    _tool_expand(ex) -> Expr

Rewrite `@tool name(arg = value, …)` into `slate_tool("name"; arg = value, …)`.

A plain function rather than the macro itself, because the macro is built INSIDE each notebook
namespace by `_populate_notebook_ns!` (the same shape `@trace` uses), so the transform has to be
callable from there.

It emits STRING-keyed pairs rather than keyword syntax. The macro is built inside each notebook
module, so Julia's hygiene pass qualifies every un-escaped symbol it returns to that module, and a
keyword NAME cannot survive that: `run_id = x` comes out as `(thismodule).run_id = x`, which does
not parse. A name cannot be `esc`aped either, since that asks for its value. Passing the arguments
as `["run_id" => x]` sidesteps hygiene entirely, because a string is not a symbol.
"""
function _tool_expand(ex)
    (ex isa Expr && ex.head === :call) ||
        error("@tool expects a call, e.g. `@tool list_jobs()` or `@tool start_job(size = 4)`")
    name = _tool_name(ex.args[1])
    pairs = Any[]
    for a in ex.args[2:end]
        if a isa Expr && (a.head === :kw || a.head === :(=))
            push!(pairs, Expr(:call, :(=>), String(a.args[1]), esc(a.args[2])))
        elseif a isa Expr && a.head === :parameters
            for p in a.args
                push!(pairs, Expr(:call, :(=>), String(p.args[1]), esc(p.args[2])))
            end
        else
            error("@tool takes keyword arguments only (`name = value`), got `$(a)`")
        end
    end
    return Expr(:call, :slate_tool, name, Expr(:vect, pairs...))
end

# An extension's tool is `namespace.tool`, which parses as field access: `fusionkb.search`.
_tool_name(x::Symbol) = String(x)
_tool_name(x::QuoteNode) = _tool_name(x.value)
function _tool_name(x::Expr)
    x.head === :. && length(x.args) == 2 && return _tool_name(x.args[1]) * "." * _tool_name(x.args[2])
    error("@tool expects a tool name like `ping` or `fusionkb.search`, got `$x`")
end

"""
    slate_tools(; filter = "") -> table

Every tool a `@tool` cell can call: the Kaimon server's (its own and every extension's), then any
registered in this worker's gate that the server does not also list. Each with its parameter
count and first documentation line; `filter` keeps only names containing that substring.
"""
function slate_tools(; filter::AbstractString = "")
    rows = NamedTuple[]
    function add!(nm, meta, where)
        (isempty(filter) || occursin(filter, nm)) || return
        ps = get(meta, "arguments", [])
        req = count(a -> get(a, "required", false) === true, ps)
        summary = _short(_first_prose_line(String(get(meta, "description", ""))), 110)
        push!(rows, (tool = nm, params = length(ps), required = req, where = where, summary = summary))
    end
    server = _server_tools()
    for t in server
        add!(t.name, _server_tool_meta(t), "server")
    end
    for t in _session_tools()
        nm = getfield(t, :name)
        startswith(nm, "__") && continue                       # the worker's own plumbing
        _find_server_tool(nm, server) === nothing && add!(nm, _tool_meta(t), "session")
    end
    sort!(rows; by = r -> r.tool)
    return isempty(rows) ? "no tools reachable (no Kaimon gate or server)" : slate_table(rows)
end

# ── Rendering ────────────────────────────────────────────────────────────────────────────────────
# Themed entirely from the page's CSS variables. Hardcoding colours here would fight whatever Slate
# palette is active, which is the same mistake as pinning a chart's colormap.

_h(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

_short(s, n = 120) = (t = string(s); length(t) <= n ? t : first(t, n - 1) * "…")

# JSON for a follow-up's arguments, carried in a data- attribute (which `_h` then escapes).
_jesc(s) = replace(string(s), "\\" => "\\\\", "\"" => "\\\"")
_json_args(args) = "{" * join([string("\"", _jesc(k), "\":\"", _jesc(v), "\"") for (k, v) in args], ",") * "}"

# ── Controls, chosen by the parameter's declared type ────────────────────────────────────────────
# The schema is right there, so a Bool has no business being a free-text box you can type "ture"
# into and an enum's values should not have to be remembered. Everything a type does not pin down
# stays a text input, and the gate's dispatcher still coerces whatever comes back.

const _CTL_STYLE = "width:100%;box-sizing:border-box;background:transparent;color:var(--fg);" *
    "border:1px solid var(--border);border-radius:4px;padding:2px 6px;" *
    "font-family:ui-monospace,monospace;font-size:12px"

function _param_kind(p)
    tm = get(p, "type_meta", nothing)
    tm isa AbstractDict || return "string"
    k = get(tm, "kind", nothing)
    k === nothing || return String(k)
    # A hand-built parameter, or an older gate, carries only the Julia type name.
    jt = String(get(tm, "julia_type", ""))
    return startswith(jt, "Bool") ? "boolean" :
        (startswith(jt, "Int") || startswith(jt, "UInt")) ? "integer" :
        startswith(jt, "Float") ? "number" : "string"
end

function _param_values(p)
    tm = get(p, "type_meta", nothing)
    tm isa AbstractDict || return String[]
    return String[String(v) for v in get(tm, "enum_values", String[])]
end

"""The control for one parameter: a select where the type enumerates its values, a number field
where it is numeric, a text input otherwise. An empty selection means "not supplied", which is how
a call omits an optional parameter and lets the tool's own default stand."""
function _arg_control(nm::AbstractString, p, val)
    kind = _param_kind(p)
    ph = get(p, "required", false) === true ? "required" : "default"
    cur = val === nothing ? "" : _argtext(val)
    opts = kind == "boolean" ? ["true", "false"] : kind == "enum" ? _param_values(p) : String[]
    if !isempty(opts)
        io = IOBuffer()
        print(io, """<select data-arg="$(_h(nm))" style="$(_CTL_STYLE)">""")
        print(io, """<option value=""$(isempty(cur) ? " selected" : "")>$(ph)</option>""")
        for o in opts
            print(io, """<option value="$(_h(o))"$(o == cur ? " selected" : "")>$(_h(o))</option>""")
        end
        print(io, "</select>")
        return String(take!(io))
    end
    num = kind == "integer" ? " type=\"number\" step=\"1\"" :
        kind == "number" ? " type=\"number\" step=\"any\"" : ""
    return """<input data-arg="$(_h(nm))"$(num) value="$(_h(cur))" placeholder="$(ph)" style="$(_CTL_STYLE)">"""
end

# A gate tool returns text, and much of it is `key=value` or `key: value` records (a run listing, a
# status report). Rendering those as fields rather than a wall of text is most of what makes the
# result readable; anything else falls back to preformatted text unchanged.
function _result_fields(text::AbstractString)
    fields = Pair{String,String}[]
    for ln in split(text, '\n')
        s = strip(ln)
        isempty(s) && continue
        m = match(r"^([A-Za-z_][A-Za-z0-9_ ]{0,30}):\s+(.*)$", s)
        if m !== nothing
            push!(fields, String(m.captures[1]) => String(m.captures[2]))
            continue
        end
        kvs = collect(eachmatch(r"(\w+)=([^\s]+)", s))
        length(kvs) >= 2 || return Pair{String,String}[]   # not a record line — give up on the whole thing
        # Prose can contain `key=value` fragments too ("started job a1b2… (kind=build, …). Poll
        # `job_status(job_id="…")`"), and shredding a sentence into fields loses the sentence.
        # A real record line is MOSTLY its fields, so require the matches to cover most of it.
        covered = sum(length(kv.match) for kv in kvs)
        covered >= 0.6 * length(replace(s, r"\s+" => "")) || return Pair{String,String}[]
        for kv in kvs
            push!(fields, String(kv.captures[1]) => String(kv.captures[2]))
        end
    end
    return fields
end

function Base.show(io::IO, ::MIME"text/html", tc::ToolCall)
    supplied = Dict(k => v for (k, v) in tc.args)
    pill_bg = tc.ok ? "color-mix(in srgb, var(--accent) 22%, transparent)" :
                      "color-mix(in srgb, crimson 25%, transparent)"
    pill_txt = tc.ok ? "ok" : "error"

    print(io, """<div class="slate-toolcall" style="border:1px solid var(--border);border-radius:8px;
        overflow:hidden;font-size:13px;margin:2px 0">""")

    # Header: what was called, whether it worked, and what it cost.
    print(io, """<div style="display:flex;align-items:center;gap:10px;padding:8px 12px;
        background:color-mix(in srgb, var(--fg) 4%, transparent);border-bottom:1px solid var(--border)">
        <span style="font-weight:600;font-family:ui-monospace,monospace">$(_h(tc.name))</span>
        <span style="padding:1px 8px;border-radius:10px;font-size:11px;background:$(pill_bg)">$(pill_txt)</span>""")
    # The handle a background call returned, held where it can be read rather than left buried in
    # the reply text: it is the one thing about such a call you actually need afterwards.
    handle = tool_handle(tc)
    handle === nothing ||
        print(io, """<span style="font-family:ui-monospace,monospace;font-size:11px;
            color:var(--muted)">$(_h(handle))</span>""")
    print(io, """<span style="flex:1"></span>
        <span style="color:var(--muted);font-size:11px">$(tc.seconds)s &middot; $(_h(tc.at))</span></div>""")

    blurb = _first_prose_line(tc.description)
    isempty(blurb) ||
        print(io, """<div style="padding:6px 12px;color:var(--muted);border-bottom:1px solid var(--border)">
            $(_h(_short(blurb, 160)))</div>""")

    # Parameters: the tool's whole declared surface, not just what this call sent. An omitted
    # required parameter is the single most common reason a tool call is wrong, so it is marked.
    # Each row's value is an INPUT when the panel can call back, so the call can be adjusted and
    # re-fired in place — a tool call is a thing you tune, and re-running the cell to change one
    # argument would also re-run everything downstream of it.
    live = !isempty(tc.channel)
    if !isempty(tc.params)
        print(io, """<table style="width:100%;border-collapse:collapse">
            <thead><tr style="color:var(--muted);font-size:11px;text-align:left">
            <th style="padding:4px 12px;font-weight:500">parameter</th>
            <th style="padding:4px 8px;font-weight:500">type</th>
            <th style="padding:4px 8px;font-weight:500">required</th>
            <th style="padding:4px 12px;font-weight:500">value</th></tr></thead><tbody>""")
        for p in tc.params
            nm = String(get(p, "name", "?"))
            req = get(p, "required", false) === true
            has = haskey(supplied, nm)
            dim = has ? "" : "opacity:.62;"
            cell = if live
                _arg_control(nm, p, has ? supplied[nm] : nothing)
            elseif has
                _h(_short(repr(supplied[nm])))
            elseif req
                "<span style=\"color:crimson\">missing</span>"
            else
                "<span style=\"color:var(--muted)\">—</span>"
            end
            print(io, """<tr style="border-top:1px solid var(--border);$(dim)">
                <td style="padding:4px 12px;font-family:ui-monospace,monospace;white-space:nowrap">$(_h(nm))</td>
                <td style="padding:4px 8px;color:var(--muted);white-space:nowrap">$(_h(_param_type(p)))</td>
                <td style="padding:4px 8px;color:var(--muted)">$(req ? "yes" : "")</td>
                <td style="padding:4px 12px;font-family:ui-monospace,monospace;width:55%">$(cell)</td></tr>""")
        end
        print(io, "</tbody></table>")
    end

    if live
        print(io, """<div style="display:flex;align-items:center;gap:10px;padding:8px 12px;
            border-top:1px solid var(--border)">
            <button data-invoke style="background:color-mix(in srgb, var(--accent) 25%, transparent);
                color:var(--fg);border:1px solid var(--border);border-radius:5px;padding:3px 14px;
                cursor:pointer;font-size:12px">Invoke</button>
            <span data-status style="color:var(--muted);font-size:11px"></span></div>""")
    end

    # What the reply said to do next, as buttons. The polled one is a toggle: it starts (or stops)
    # tracking the work, so a run that takes minutes reports into the cell that started it.
    if live && !isempty(tc.followups)
        print(io, """<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;
            padding:8px 12px;border-top:1px solid var(--border)">
            <span style="color:var(--muted);font-size:11px;text-transform:uppercase;
                letter-spacing:.04em">next</span>""")
        for f in tc.followups
            print(io, """<button data-follow="$(_h(f.name))" data-args="$(_h(_json_args(f.args)))"\
                $(f.poll ? " data-poll" : "") style="background:transparent;color:var(--fg);
                border:1px solid var(--border);border-radius:5px;padding:2px 10px;cursor:pointer;
                font-size:12px;font-family:ui-monospace,monospace">$(_h(f.name))</button>""")
        end
        print(io, """<span data-follow-status style="color:var(--muted);font-size:11px"></span></div>""")
    end

    # Result: as fields when the text is a record, otherwise verbatim.
    body = tc.ok ? tc.result : tc.error
    label = tc.ok ? "result" : "error"
    print(io, """<div style="padding:6px 12px;border-top:1px solid var(--border);
        color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.04em">$(label)</div>""")
    fields = tc.ok ? _result_fields(body) : Pair{String,String}[]
    if !isempty(fields)
        print(io, """<div data-fields style="display:flex;flex-wrap:wrap;gap:6px 18px;padding:0 12px 10px">""")
        for (k, v) in fields
            print(io, """<div><div style="color:var(--muted);font-size:11px">$(_h(k))</div>
                <div style="font-family:ui-monospace,monospace">$(_h(_short(v, 60)))</div></div>""")
        end
        print(io, "</div>")
    else
        print(io, """<pre data-result style="margin:0;padding:0 12px 10px;white-space:pre-wrap;
            font-family:ui-monospace,monospace">$(_h(_short(body, 4000)))</pre>""")
    end

    # The Invoke and follow-up paths. `window.slateCall` is Slate's JS→Julia bridge; the handler
    # registered above runs the tool and returns the new outcome, which is written back into this
    # panel. The `__wired` guard matters because a cell's output HTML is revived on every render,
    # and its absence in a static export is why `slateCall` is checked for at all.
    if live
        print(io, """<script>(function(){
          var root = document.currentScript.closest('.slate-toolcall'); if(!root||root.__wired) return;
          if(!window.slateCall) return;
          root.__wired = true;
          var CH  = $(repr(tc.channel)),
              btn = root.querySelector('[data-invoke]'),
              st  = root.querySelector('[data-status]'),
              fst = root.querySelector('[data-follow-status]');

          function setResult(text){
            var f = root.querySelector('[data-fields]'); if(f) f.style.display = 'none';
            var out = root.querySelector('[data-result]');
            if(!out){ out = document.createElement('pre');
                      out.setAttribute('data-result',''); root.appendChild(out); }
            out.style.cssText = 'margin:0;padding:0 12px 10px;white-space:pre-wrap;font-family:ui-monospace,monospace';
            out.textContent = text;
          }
          async function call(tool, args){
            var payload = Object.assign({__tool: tool}, args);
            var r = await window.slateCall(CH, payload);
            setResult(r.text);
            return r;
          }

          if(btn) btn.addEventListener('click', async function(){
            var args = {};
            root.querySelectorAll('[data-arg]').forEach(function(i){
              if(i.value !== '') args[i.getAttribute('data-arg')] = i.value; });
            btn.disabled = true; st.textContent = 'calling…';
            try {
              var r = await call($(repr(tc.name)), args);
              st.textContent = (r.ok ? 'ok' : 'error') + ' · ' + r.seconds + 's · ' + r.at;
            } catch(e) { st.textContent = 'call failed: ' + e; }
            btn.disabled = false;
          });

          // Tracking. A polled follow-up keeps calling until the run reports a status that is not
          // a running one, so the panel follows the work instead of freezing on the reply that
          // started it. A reply that never says `status` is polled once and then left alone.
          var timer = null;
          function stop(){ if(timer){ clearInterval(timer); timer = null; } }
          root.querySelectorAll('[data-follow]').forEach(function(b){
            var tool  = b.getAttribute('data-follow'),
                args  = JSON.parse(b.getAttribute('data-args') || '{}'),
                polls = b.hasAttribute('data-poll');
            async function once(){
              try {
                var r = await call(tool, args);
                if(fst) fst.textContent = tool + ' · ' + (r.ok ? r.state : 'error') + ' · ' + r.at;
                if(!r.ok || r.state !== 'running') stop();
                return r.ok ? r.state : 'done';
              } catch(e){ if(fst) fst.textContent = tool + ' failed: ' + e; stop(); return 'done'; }
            }
            b.addEventListener('click', function(){
              if(!polls) return once();
              if(timer){ stop(); if(fst) fst.textContent = 'stopped tracking ' + tool; return; }
              once().then(function(s){ if(s === 'running' && !timer) timer = setInterval(once, 2000); });
            });
            // Opening the notebook picks a live run back up, and settles a finished one to its
            // final status in one call.
            if(polls && !root.__polled){
              root.__polled = true;
              once().then(function(s){ if(s === 'running' && !timer) timer = setInterval(once, 2000); });
            }
          });
        })();</script>""")
    end
    print(io, "</div>")
    return nothing
end

# How a supplied value is shown INSIDE an input: a string without its quotes (you are editing the
# text, not a Julia literal), anything else as it prints.
_argtext(v) = v isa AbstractString ? String(v) : string(v)

# ── Recording an agent's calls ───────────────────────────────────────────────────────────────────
#
# The tools an agent reaches over MCP are dispatched IN THIS PROCESS, by the gate's message loop.
# Wrapping their handlers is therefore enough to notice a call and record it as a cell — which is
# the point: an action taken from outside the notebook otherwise leaves no trace in the document,
# only in a transcript nobody keeps.
#
# A call made BY a cell (`@tool …`) is skipped: it already has a cell, and recording it would
# append a duplicate on every run. The two paths are told apart by a task-local flag rather than by
# inspecting the call, because `slate_tool` invokes the very same handler.

const _IN_CELL_TOOLCALL = :__slate_in_cell_toolcall
const _TOOLS_WATCHED = Ref(false)

_recording_suppressed() = get(task_local_storage(), _IN_CELL_TOOLCALL, false) === true

"""Render one recorded call as the source of a TOOL cell: the `@tool` form an author would have
written, so the cell is re-runnable rather than a transcript of something that happened."""
function toolcall_source(name::AbstractString, args)
    isempty(args) && return "@tool $(name)()"
    parts = String[]
    for (k, v) in args
        push!(parts, string(k, " = ", v isa AbstractString ? repr(String(v)) : repr(v)))
    end
    body = join(parts, ",\n" * " "^(length(name) + 7))
    return "@tool $(name)($(body))"
end

"""
    recorded_toolcall(name, args, ok, text, seconds, at; handlers) -> ToolCall

The panel for a call that ALREADY happened, without dispatching it again.

An agent's call is observed after the fact, so there is nothing left to run: the outcome is handed
in and only the tool's declared schema is looked up. What this buys is that a recorded call renders
as the same panel a `@tool` cell does, rather than as a transcript of its reply, so it carries the
handle, the parameter surface, and the follow-up the reply named. That is what lets a recorded call
that started background work track it, instead of freezing on the sentence that started it.
"""
function recorded_toolcall(name::AbstractString, args, ok::Bool, text::AbstractString,
                           seconds::Real, at::AbstractString; handlers = nothing)
    args = Pair{String,Any}[String(first(p)) => last(p) for p in args]
    tool = _find_tool(name)
    meta = tool === nothing ? Dict{String,Any}() : _tool_meta(tool)
    params = Vector{Dict{String,Any}}(get(meta, "arguments", Dict{String,Any}[]))
    desc = String(get(meta, "description", ""))
    return ToolCall(String(name), args, params, desc, ok, ok ? String(text) : "",
                    ok ? "" : String(text), round(Float64(seconds), digits = 3), String(at),
                    _register_invoke!(handlers, name))
end

"""Start publishing every session tool call an agent makes, for the hub to record as a cell.

Registers a gate OBSERVER rather than wrapping handlers. Wrapping was the obvious approach and is
wrong: a handler's signature IS its MCP schema (`_reflect_tool` reads it), so a wrapper with
`(args...; kwargs...)` silently strips a tool's parameters and the agent can no longer call it.
Observing leaves the tool untouched.

Idempotent — safe to call after every cell, which is what catches the tools a package registers
when a cell first loads it.

`handlers` is a thunk returning the notebook's JS→Julia handler registry (the namespace is replaced
on reset, so it cannot be captured once), used to make the recorded panel callable."""
function watch_session_tools!(publish; handlers = () -> nothing)
    _TOOLS_WATCHED[] && return false
    g = _gate_module()
    (g === nothing || !isdefined(g, :observe_tools!)) && return false
    Base.invokelatest(getfield(g, :observe_tools!), function (name, args, ok, result, seconds)
        # A call made BY a cell (`@tool …`) already has a cell; recording it would append a
        # duplicate on every run. The two paths share this handler, so they are told apart by a
        # task-local flag rather than by inspecting the call.
        _recording_suppressed() && return nothing
        startswith(String(name), "__slate_") && return nothing   # Slate's own plumbing, not an action
        pairs_ = Pair{String,Any}[String(k) => v for (k, v) in args]
        text = result isa AbstractString ? String(result) : sprint(show, MIME("text/plain"), result)
        at = _clock_now()
        # The panel is built HERE, in the worker, because that is where the tool registry and the
        # notebook's JS→Julia handlers both live; the hub has neither and could only render the
        # reply as text. `handlers()` is the notebook's registry, so a recorded call arrives in the
        # document already able to call back.
        html = try
            hs = handlers()
            tc = recorded_toolcall(String(name), pairs_, ok === true, text, seconds, at;
                                   handlers = hs isa AbstractDict ? hs : nothing)
            sprint(show, MIME("text/html"), tc)
        catch
            ""      # the hub falls back to rendering the reply text
        end
        publish((; name = String(name), args = pairs_, ok = ok === true,
                   seconds = round(Float64(seconds), digits = 3), at, text, html))
        return nothing
    end)
    _TOOLS_WATCHED[] = true
    return true
end

function Base.show(io::IO, tc::ToolCall)
    print(io, "ToolCall(", tc.name, ", ", tc.ok ? "ok" : "error", ", ", tc.seconds, "s)")
    return nothing
end
