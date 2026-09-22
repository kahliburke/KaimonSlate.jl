# A port nothing else is on, for a test that needs a live hub.
#
# Hardcoded numbers do not survive a suite this size. Two testsets in one file had already landed on
# the same one, a hub left behind by an interrupted run holds its port until that process dies, and
# a developer's own hub is on the same machine as the suite. The failure is not local either: the
# hub that loses the race is the one whose test fails, which may be a file away from the one that
# took the port.
#
# Asking the kernel for port 0 and reading back what it assigned is the ordinary answer. There is a
# window between closing this socket and the hub binding it, which nothing on one machine is racing
# for — and a suite that occasionally has to be re-run beats one where two files must agree on a
# number by hand.
import Sockets

function freeport()
    s = Sockets.listen(Sockets.localhost, 0)
    try
        return Int(Sockets.getsockname(s)[2])
    finally
        close(s)
    end
end

"""
    with_hub(f; kw...)

A hub on a free port, stopped however the block leaves — returning, throwing, or failing an
assertion. Every hub in the suite already sits in a `try`/`finally` that does this by hand; this is
so the next one cannot be written without it. A hub that outlives its test holds its port for as
long as the process runs, and the test that then fails is whichever one asked for that port next,
which is typically in another file.
"""
function with_hub(f; kw...)
    NS = KaimonSlate.NotebookServer
    hub = NS.start_hub(; port = freeport(), kw...)
    try
        return f(hub)
    finally
        try; NS.stop_hub(hub); catch; end   # teardown must not mask the failure that got us here
    end
end
