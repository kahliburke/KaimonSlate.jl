#!/usr/bin/env julia
#
# Standalone KaimonSlate launcher (Tier 0 — no Kaimon needed).
#
#   julia --project=/path/to/KaimonSlate bin/kaimonslate.jl [notebook.jl] [--port N] [--no-open]
#
# Boots the Slate hub, opens the notebook (if given) in your browser, runs cells on the
# in-process kernel, and serves the live UI until Ctrl-C. With no path, serves the index.
# For the full agent/worker experience, run inside Kaimon.

using KaimonSlate

function main(args)
    path = ""; port = 8765; browser = true
    i = firstindex(args)
    while i <= lastindex(args)
        a = args[i]
        if a in ("--port", "-p")
            i < lastindex(args) || error("--port needs a value")
            port = parse(Int, args[i + 1]); i += 2
        elseif a in ("--no-open", "--no-browser")
            browser = false; i += 1
        elseif a in ("--help", "-h")
            println("usage: kaimonslate [notebook.jl] [--port N] [--no-open]")
            return
        elseif startswith(a, "-")
            @warn "ignoring unknown flag" flag = a; i += 1
        else
            path = a; i += 1
        end
    end
    KaimonSlate.serve(path; port = port, browser = browser)
end

main(ARGS)
