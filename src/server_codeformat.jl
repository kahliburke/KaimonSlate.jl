# ── Code-cell formatting ──────────────────────────────────────────────────────────────────────────
# Two formatters. Runic runs here, in the hub. Fatou runs in the browser from its WASM build, which
# sends its output back. Whichever formatter produced it, the hub accepts output only when the source
# parses and the output parses to the same program; Fatou does not reject code that fails to parse.
#
# Which one a notebook uses: the notebook's own `formatter` setting, else Fatou when a `fatou.toml`
# governs the notebook's directory, else the global default (slate.json `formatter`), else Runic.

const FORMATTERS = ("runic", "fatou")
const FORMATTER_DEFAULT = Ref("runic")
const _FORMATTER_PERSIST = Ref{Any}(nothing)

formatter_default()::String = FORMATTER_DEFAULT[]

function set_formatter_default!(name::AbstractString)
    n = String(name)
    n in FORMATTERS || throw(ArgumentError("unknown formatter $n; expected one of $(join(FORMATTERS, ", "))"))
    FORMATTER_DEFAULT[] = n
    p = _FORMATTER_PERSIST[]
    p === nothing || (try; p(n); catch e; @warn "slate: could not persist the formatter setting" exception = e; end)
    return n
end

# The `fatou.toml` that governs `dir`, found the way Fatou finds it: walking up and stopping at the
# repository root (the directory holding `.git`, inclusive), or at the filesystem root outside one.
function _fatou_toml(dir::AbstractString)
    d = abspath(dir)
    while true
        f = joinpath(d, "fatou.toml")
        isfile(f) && return f
        ispath(joinpath(d, ".git")) && return nothing
        up = dirname(d)
        up == d && return nothing
        d = up
    end
end

# Fatou's own fallbacks when no project file applies: `$FATOU_CONFIG`, then the user config.
function _fatou_user_toml()
    f = get(ENV, "FATOU_CONFIG", "")
    isempty(f) || return isfile(f) ? f : nothing
    xdg = get(ENV, "XDG_CONFIG_HOME", "")
    for f in [(isempty(xdg) ? String[] : [joinpath(xdg, "fatou", "fatou.toml")]);
              joinpath(homedir(), ".config", "fatou", "fatou.toml");
              (Sys.isapple() ? [joinpath(homedir(), "Library", "Application Support", "fatou", "fatou.toml")] : String[])]
        isfile(f) && return f
    end
    return nothing
end

# A `fatou.toml`'s `[format]` settings in the plugin's spelling. Only width and indent apply to a cell.
function _fatou_config(file)
    cfg = Dict{String,Any}()
    file === nothing && return cfg
    fmt = try; get(TOML.parsefile(file), "format", Dict{String,Any}()); catch; Dict{String,Any}(); end
    fmt isa AbstractDict || return cfg
    for (k, key) in (("line-width", "lineWidth"), ("line_width", "lineWidth"),
                     ("indent-width", "indentWidth"), ("indent_width", "indentWidth"))
        v = get(fmt, k, nothing)
        v isa Integer && v > 0 && (cfg[key] = v)
    end
    return cfg
end

"""
    notebook_formatter(nb) -> Dict

The formatter `nb` uses: `name`, `from` (`notebook`, `fatou.toml`, `global` or `default`), and for
Fatou the `config` to hand the plugin.
"""
function notebook_formatter(nb::LiveNotebook)
    pick = String(get(nb.report.meta, "formatter", ""))
    toml = isempty(nb.path) ? nothing : _fatou_toml(dirname(nb.path))
    name, from = pick in FORMATTERS ? (pick, "notebook") :
                 toml !== nothing ? ("fatou", "fatou.toml") :
                 (FORMATTER_DEFAULT[], FORMATTER_DEFAULT[] == "runic" ? "default" : "global")
    d = Dict{String,Any}("name" => name, "from" => from)
    if name == "fatou"
        file = something(toml, _fatou_user_toml(), Some(nothing))
        d["config"] = _fatou_config(file)
        file === nothing || (d["file"] = file)
    end
    return d
end

# A parse failure as `line N: reason`, or `nothing` when `src` parses.
function _parse_error(src::AbstractString)
    ex = try; Meta.parseall(src; filename = "cell"); catch e; return _format_error(e); end
    for a in ex.args
        a isa Expr && a.head in (:error, :incomplete) && return _format_error(isempty(a.args) ? "" : a.args[1])
    end
    return nothing
end

# JuliaSyntax puts the location on an `@ file:line:col` line and the reason after the `──` marker.
function _format_error(e)
    msg = e isa Meta.ParseError ? e.msg : e isa AbstractString ? String(e) : sprint(showerror, e)
    loc = match(r"@ [^:\s]+:(\d+):\d+", msg)
    why = match(r"──\s*(.+)$"m, msg)
    reason = why === nothing ? String(strip(first(split(msg, '\n')))) : String(why.captures[1])
    return loc === nothing ? reason : "line $(loc.captures[1]): $reason"
end

# Whether formatting kept the program: both texts parse to the same code once line positions are
# dropped, `return x` is read as `x` (Runic adds `return` to a function's last line), and statements
# joined by `;` count the same as statements on separate lines.
_same_program(a::AbstractString, b::AbstractString) =
    _program_shape(Meta.parseall(a)) == _program_shape(Meta.parseall(b))
_program_shape(x) = x
function _program_shape(e::Expr)
    e.head == :return && length(e.args) == 1 && return _program_shape(e.args[1])
    args = Any[]
    for a in e.args
        a isa LineNumberNode && continue
        a = _program_shape(a)
        e.head == :toplevel && a isa Expr && a.head == :toplevel ? append!(args, a.args) : push!(args, a)
    end
    return Expr(e.head, args...)
end

# Cells are stored without a trailing newline; a formatter that adds one should not.
_keep_trailing_newline(src, out) = endswith(src, '\n') || !endswith(out, '\n') ? out : chomp(out)

# More text than any notebook's code cells add up to; a request over it is refused rather than parsed.
const _FORMAT_MAX_BYTES = 4_000_000

"""
    format_texts(nb, sources; formatted = nothing) -> (; formatted, failed, formatter)

Format code-cell texts without changing the notebook: `sources` maps cell id → text, `formatted` in
the result maps id → its formatted text, and the caller applies it. With `formatted` given (id →
output, from a formatter that ran in the browser) that output is checked instead of running Runic.
A cell whose source does not parse, or whose output does not parse to the same program, is left
out and reported in `failed`.
"""
function format_texts(nb::LiveNotebook, sources::AbstractDict; formatted::Union{Nothing,AbstractDict} = nothing)
    fmt = notebook_formatter(nb)["name"]
    code = lock(nb.lock) do
        Set(c.id for c in nb.report.cells if c.kind == CODE)
    end
    out = Dict{String,String}()
    failed = Dict{String,String}()
    sum(v -> v isa AbstractString ? sizeof(v) : 0, values(sources); init = 0) > _FORMAT_MAX_BYTES &&
        return (; formatted = out, failed = Dict("" => "too much text to format"), formatter = fmt)
    for (k, v) in sources
        id = String(k)
        (id in code && v isa AbstractString) || continue
        src = String(v)
        err = _parse_error(src)
        err === nothing || (failed[id] = err; continue)
        res = if formatted !== nothing
            o = get(formatted, id, nothing)
            o isa AbstractString || continue
            String(o)
        elseif fmt == "runic"
            try
                Runic.format_string(src)
            catch e
                failed[id] = _format_error(e)
                continue
            end
        else
            failed[id] = "$fmt formats in the browser"
            continue
        end
        res = _keep_trailing_newline(src, res)
        bad = _parse_error(res)
        bad === nothing || (failed[id] = "formatted code does not parse, $bad"; continue)
        _same_program(src, res) || (failed[id] = "formatting would change what the code does"; continue)
        out[id] = res
    end
    return (; formatted = out, failed, formatter = fmt)
end
