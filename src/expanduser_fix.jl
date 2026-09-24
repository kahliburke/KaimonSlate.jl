# `Base.expanduser` does nothing on Windows: `~/notebook.jl` comes back unchanged, so the
# leading `~` is then read as a relative path and the file is looked for under the process
# working directory. Opening a notebook by a `~` path fails there with no useful error.
#
# Paths arrive with a `~` from several directions — the tab-complete UI emits them, agent
# tools pass them through, and KAIMONSLATE_HOME / KAIMONSLATE_CACHE_HOME may hold them — so
# resolving one has to work on every platform.
#
# This file is included into each module that handles paths, so the unqualified `expanduser`
# calls throughout resolve here rather than to Base. Generated remote scripts are string
# literals and keep Base's meaning, which is correct: they run on a unix host.

function expanduser(path::AbstractString)
    s = String(path)
    isempty(s) && return s
    s == "~" && return homedir()
    # Only Windows treats a backslash as a separator; on unix it is a legal filename
    # character, so `~\x` there is a file literally named `\x` and must not be split.
    tilde = startswith(s, "~/") || (Sys.iswindows() && startswith(s, "~\\"))
    if tilde
        rest = s[3:end]
        isempty(rest) && return homedir()
        # One `joinpath` argument PER COMPONENT: a whole remainder passed as a single component
        # keeps whatever separators are already inside it, so `~/a/b.jl` comes back from a Windows
        # `joinpath` as `C:\Users\me\a/b.jl`. `splitpath` also settles which separators count,
        # splitting on both on Windows and on `/` alone on unix, where `\` is a filename character.
        return joinpath(homedir(), splitpath(rest)...)
    end
    # `~user` on unix, and every path without a leading tilde.
    return Base.expanduser(s)
end
