# ── Updating a notebook to the current file format ────────────────────────────────────────────────
# A notebook whose file is in an older format (`ReportEngine.FORMAT`) and whose update would change
# something in it is not opened until someone agrees to the update. Agreeing keeps a copy of the
# original beside it, then writes the notebook in the current format. Declining leaves the file
# alone and nothing is opened. Every open reaches `load_notebook`, which refuses with
# `NotebookNeedsUpdate`; each way of opening turns that into its own question.

"A notebook file that must be updated to the current format before it opens."
struct NotebookNeedsUpdate <: Exception
    path::String
    format::Int
    changes::Vector{String}
end
Base.showerror(io::IO, e::NotebookNeedsUpdate) =
    print(io, basename(e.path), " is written in notebook format ", e.format, "; opening it updates it to format ",
          ReportEngine.FORMAT, " (", join(e.changes, "; "), "), keeping a copy of the original beside it. ",
          "Open it again agreeing to the update to go ahead.")

# The refusal as the page and the tools read it: what changes, and where the copy would go.
_needs_update_json(e::NotebookNeedsUpdate) = Dict{String,Any}(
    "needs_update" => true, "path" => e.path, "name" => basename(e.path), "format" => e.format,
    "current" => ReportEngine.FORMAT, "changes" => e.changes,
    "backup" => basename(_format_backup_path(e.path, e.format)))

# Where the original is kept: beside it, named for its format and the time of the update.
function _format_backup_path(path::AbstractString, format::Integer)
    stem = splitext(basename(path))[1]
    return joinpath(dirname(abspath(path)), string(stem, ".format", format, ".", Dates.format(Dates.now(), "yyyymmdd-HHMMSS"), ".jl"))
end

"""
    update_notebook_format!(path) -> (; backup, changes)

Write the notebook at `path` in the current file format, keeping a copy of the original beside it
first. Reading a file parses it in its own format and writing it uses the current one, so the update
is a read and a write: the footers a save carries forward (a bundle, a frozen render) are carried
here too. A file already in the current format is left alone (`backup == ""`).
"""
function update_notebook_format!(path::AbstractString)
    file = abspath(path)
    src = read(file, String)
    r = parse_report(src)
    old = get(r.meta, "format", 1)
    old >= ReportEngine.FORMAT && return (; backup = "", changes = String[])
    changes = ReportEngine.format_changes(r)
    backup = _format_backup_path(file, old)
    cp(file, backup)
    # Findings the file carries are read into `findings_incoming`; written back as they were.
    fi = get(r.meta, "findings_incoming", nothing)
    fi isa AbstractVector && !isempty(fi) && (r.meta["findings"] = fi)
    s = serialize_report(r)
    carry = _carry_env_footers(src)
    isempty(carry) || (s = rstrip(s, '\n') * "\n\n" * carry * "\n")
    tmp = file * ".tmp." * string(getpid())
    write(tmp, s)
    mv(tmp, file; force = true)
    ReportEngine._rlog("format: updated $(basename(file)) from format $old to $(ReportEngine.FORMAT); original kept as $(basename(backup))")
    return (; backup, changes)
end
