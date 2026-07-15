# ── Friend-group peer mesh (PEER_TUNNEL_PLAN §5) ───────────────────────────────────────────────────
# Auto-introduction for the SSH-bridged blob pull (`_pull_ssh!`): when B must fetch a boundary blob from
# A but A's blob port is firewalled from B, B tunnels it over an `ssh -N -L` forward (worker.jl
# `__slate_pull_blob_ssh`). That forward needs, on the hosts, exactly what a hand-rolled mesh would:
#   • on B's host: B's OWN ed25519 key `slate-<B>-<uuid8>` (it ssh's OUT with this) + a slate-OWNED
#     `slate_known_hosts` pinning every source host B may reach (StrictHostKeyChecking with no TOFU);
#   • on A's host: B's PUBLIC key in `authorized_keys`, scoped `restrict,port-forwarding,permitopen`
#     to A's ONE blob port — the key can open that single forward and nothing else.
# The HUB installs all of this over its already-authenticated SSH to both hosts (it is the trust anchor
# and broker — the workers stay passive, principle 4). Secrets never touch a command line: private keys
# are generated on-host and never move; public material rides stdin, not argv (§6.1). Every artifact is
# tagged with its region basename(s), so teardown enumerates and proves ownership of exactly ours (§5.5).
#
# This file holds the MECHANISM + a manual `introduce_group!` / `peer_plan`. The consent-gated automatic
# introduction (§5.1) wires this into the notebook layer separately.

# ── ssh with stdin ─────────────────────────────────────────────────────────────────────────────────
# `_ssh_capture` (remote.jl) runs a command and captures stdout; this variant also FEEDS stdin — how we
# hand a host public key material to append to a file without ever putting it on the command line.
function _ssh_feed(host, argv::Cmd, input::AbstractString)
    out = IOBuffer(); err = IOBuffer()
    ok = try
        run(pipeline(_ssh(host, argv); stdin = IOBuffer(String(input)), stdout = out, stderr = err))
        true
    catch
        false
    end
    ok || _rlog("mesh: ssh $host FAILED — $(first(strip(String(take!(err))), 300))")
    return (ok, String(take!(out)))
end

# Run a full shell SCRIPT on `host` by feeding it over STDIN to `sh -s`. NOT `ssh host sh -c '<script>'`:
# ssh re-joins its command args into ONE string that the REMOTE login shell re-splits, so `sh -c` sees
# only the first word and the remaining statements misfire in the login shell (seen live: `rm: missing
# operand`, silently-skipped drops, an `umask` echo leaking into captured stdout). stdin is not re-parsed,
# so a multi-statement script arrives intact. Returns (ok, stdout).
_ssh_script(host, script::AbstractString) = _ssh_feed(host, `sh -s`, script)

# POSIX single-quote a value for safe embedding in a script (close-quote, escape any ', reopen).
_shq(s) = "'" * replace(String(s), "'" => "'\\''") * "'"

# One hub-side lock per host serializes every mesh edit to that host's ~/.ssh files. The hub is the SOLE
# writer of slate-tagged lines, so this fully removes the read-modify-write race without a remote flock
# (dodging macOS flock portability). A concurrent HUMAN edit is still safe: we only ever `grep -vF` our
# OWN tags, and the temp+atomic-mv bounds the window to the mv itself.
const _MESH_HOST_LOCKS = Dict{String,ReentrantLock}()
const _MESH_LOCKS_LOCK = ReentrantLock()
_mesh_host_lock(host) = lock(_MESH_LOCKS_LOCK) do
    get!(() -> ReentrantLock(), _MESH_HOST_LOCKS, String(host))
end

# ── Identity material ──────────────────────────────────────────────────────────────────────────────
# Pull the "<type> <base64>" of an ssh public key out of a command's stdout, ROBUST against a noisy
# channel: a login shell / rc / `umask` echo can prepend junk lines (seen live: `umask 077` printing the
# prior mask), so scanning for the `ssh-…` line beats trusting field positions. Comment field dropped.
function _extract_ssh_key(out)
    for ln in split(String(out), '\n')
        m = match(r"(ssh-[A-Za-z0-9-]+)\s+([A-Za-z0-9+/=]+)", ln)
        m === nothing || return "$(m.captures[1]) $(m.captures[2])"
    end
    error("mesh: no ssh key found in output: $(first(strip(String(out)), 120))")
end

# A region's OWN ed25519 keypair on its host — generated in place, private half never leaves. Returns
# the PUBLIC key as "<type> <base64>" (comment dropped; we re-tag when we install it). Idempotent.
function _mesh_ensure_key!(region)
    r = region_get(region); r === nothing && error("mesh: unknown region '$region'")
    base = _mesh_basename(r.name)   # safe basename (folded name + hex): no shell metacharacters
    script = """
    umask 077; mkdir -p ~/.ssh
    f="\$HOME/.ssh/$base"
    [ -f "\$f" ] || ssh-keygen -q -t ed25519 -N '' -C '$base' -f "\$f"
    cat "\$f.pub"
    """
    ok, out = _ssh_script(r.host, script)
    ok || error("mesh: keygen for '$(r.name)' on $(r.host) failed")
    return _extract_ssh_key(out)
end

# A host's SSH host public key, read over the ALREADY-TRUSTED hub↔host channel (no ssh-keyscan, no TOFU).
# Returned as "<type> <base64>" to seed a puller's slate_known_hosts. Cached (an ssh round-trip).
const _MESH_HOSTKEY_CACHE = Dict{String,String}()
const _MESH_HOSTKEY_LOCK  = ReentrantLock()
function _mesh_host_key(host)
    h = String(host)
    hit = lock(_MESH_HOSTKEY_LOCK) do; get(_MESH_HOSTKEY_CACHE, h, ""); end
    isempty(hit) || return hit
    ok, out = _ssh_capture(h, `cat /etc/ssh/ssh_host_ed25519_key.pub`)
    ok || error("mesh: could not read host key on $h")
    key = _extract_ssh_key(out)
    lock(_MESH_HOSTKEY_LOCK) do; _MESH_HOSTKEY_CACHE[h] = key; end
    return key
end

# ── File editors (atomic, idempotent, tag-keyed) ─────────────────────────────────────────────────────
# Replace every line matching fixed-string `tag` in ~/.ssh/<file> with `line` (fed on stdin), atomically.
# `tag` absent ⇒ pure append. `line` empty ⇒ pure delete (drop matching lines). The `{ … ; cat; }` group
# writes kept-lines-minus-tag then appends stdin; a grep that matches nothing still emits its kept lines,
# so an emptied file is fine. Runs under the per-host hub lock.
function _mesh_file_put!(host, file, tag::AbstractString, line::AbstractString; mode = "600")
    lock(_mesh_host_lock(host)) do
        # kept-lines-minus-tag, then the new line via printf (both non-secret; embedded in the script, not
        # on argv). grep matching nothing still emits its kept lines, so an emptied file is fine.
        script = """
        umask 077; mkdir -p ~/.ssh
        f="\$HOME/.ssh/$file"
        t=\$(mktemp "\$HOME/.ssh/.slmesh.XXXXXX") || exit 1
        { [ -f "\$f" ] && grep -vF $(_shq(tag)) "\$f"; printf '%s\\n' $(_shq(line)); } > "\$t"
        mv "\$t" "\$f"; chmod $mode "\$f"
        """
        ok, _ = _ssh_script(host, script)
        ok || error("mesh: edit of ~/.ssh/$file on $host failed")
    end
    return nothing
end
# Drop every line tagged `tag` from ~/.ssh/<file> (teardown). No-op if the file is absent.
function _mesh_file_drop!(host, file, tag::AbstractString)
    lock(_mesh_host_lock(host)) do
        script = """
        f="\$HOME/.ssh/$file"; [ -f "\$f" ] || exit 0
        t=\$(mktemp "\$HOME/.ssh/.slmesh.XXXXXX") || exit 1
        { grep -vF $(_shq(tag)) "\$f" || true; } > "\$t"; mv "\$t" "\$f"
        """
        _ssh_script(host, script)
    end
    return nothing
end

# Hub-side record of the port each installed grant's `permitopen` is currently set to. A tunnel source
# assigns its blob port at spawn, so its grant is installed with an inert placeholder and must be
# rewritten to the LIVE port just before an :ssh pull (§2). Populated by `_mesh_install_grant!`.
const _MESH_GRANT_PORT = Dict{Tuple{String,String},Int}()   # (source, puller) → permitopen port on source
const _MESH_GRANT_LOCK = ReentrantLock()

# Just-in-time permitopen finalize (§2): before an :ssh pull, rewrite the source's grant line's permitopen
# to the LIVE blob `port`. No-op when the pair was never introduced (no consented grant to touch — we do
# NOT auto-create one, that's consent's job) or the port is unchanged (:direct source, or already
# finalized). One ssh edit, only when the port actually moved.
function _mesh_finalize_port!(source, puller, port::Integer)
    p = Int(port); p > 1 || return nothing
    key = (String(source), String(puller))
    cur = lock(_MESH_GRANT_LOCK) do; get(_MESH_GRANT_PORT, key, nothing); end
    (cur === nothing || cur == p) && return nothing
    _mesh_install_grant!(source, puller; port = p)     # rewrites the one line (idempotent) + refreshes the cache
    return nothing
end

# Drop cached grant ports naming `region` — called on teardown (the grant's on-host artifacts are gone, so
# the cache entry must go too). NOT called on reap: a respawn keeps the grant, and `_mesh_finalize_port!`
# re-installs to the new port on the next transfer (comparing live port vs cached), so the entry stays.
function _mesh_grant_forget_region!(region)
    n = region_get(region) === nothing ? String(region) : region_get(region).name
    lock(_MESH_GRANT_LOCK) do
        for k in collect(keys(_MESH_GRANT_PORT))
            (k[1] == n || k[2] == n) && delete!(_MESH_GRANT_PORT, k)
        end
    end
    return nothing
end

# ── One directed grant: `puller` may ssh into `source`'s host and forward to `source`'s blob `port` ────
# Installs BOTH ends of that one arrow: puller's pubkey (scoped) into source's authorized_keys, and
# source's host key into puller's slate_known_hosts. The authorized_keys comment carries BOTH region
# basenames so teardown of EITHER endpoint drops the line; the known_hosts pin carries the SOURCE's (a
# host-key pin is shared by every puller on that host, so it's the source's to remove). `port <= 0` ⇒ the
# inert placeholder `127.0.0.1:1` — a visible, reconcilable grant that can forward NOWHERE useful until a
# real port is finalized (the tunnel-source case; §2).
function _mesh_install_grant!(source, puller; port::Integer)
    src = region_get(source); pul = region_get(puller)
    (src === nothing || pul === nothing) && error("mesh: unknown region in grant $puller←$source")
    src.host == pul.host && return nothing            # same host ⇒ loopback direct, no ssh mesh needed
    ppub = _mesh_ensure_key!(pul.name)                # puller's outgoing pubkey (on puller's host)
    ptag = _mesh_basename(pul.name); stag = _mesh_basename(src.name)
    p = port > 0 ? Int(port) : 1
    # `restrict` alone still lets the key RUN COMMANDS (it only kills pty/agent/x11/forwarding, seen live:
    # `true` executed under it) — so also force `command="false"` to deny any session. The bridge dials
    # with `-N` (no session channel), so the forced command never runs and the -L forward is unaffected;
    # a misuse WITHOUT -N just gets /bin/false. Net: this key can open ONE forward to ONE blob port and
    # do nothing else (§5.3 least-privilege).
    line = "restrict,port-forwarding,command=\"false\",permitopen=\"127.0.0.1:$p\" $ppub $ptag from $stag"
    _mesh_file_put!(src.host, "authorized_keys", "$ptag from $stag", line)
    # pin source's host key on the puller's host, keyed by EVERY address the puller might dial it at (the
    # hub-facing/internal IP AND the public `peer` addr — the route resolver picks per vantage, so the pin
    # must cover both; known_hosts takes comma-separated hostnames on one line). Tagged by source.
    hk = _mesh_host_key(src.host)
    hostnames = join(unique(filter(!isempty, [_peer_host_ip(src.host), src.peer])), ",")
    _mesh_file_put!(pul.host, "slate_known_hosts", "slate-mesh-pin $stag", "$hostnames $hk slate-mesh-pin $stag")
    lock(_MESH_GRANT_LOCK) do; _MESH_GRANT_PORT[(src.name, pul.name)] = p; end   # remember the live permitopen port
    _rlog("mesh: grant $(pul.name)←$(src.name) installed (permitopen 127.0.0.1:$p on $(src.host))")
    return (; source = src.name, puller = pul.name, port = p, placeholder = (p == 1))
end

# The source's blob port for a permitopen, when statically knowable: a :direct region pins it at
# base_port+2. A :tunnel region assigns it per-worker at spawn ⇒ unknown here ⇒ 0 (caller uses the
# placeholder and finalizes the real port just-in-time at transfer).
function _region_blob_port(name)
    r = region_get(name); r === nothing && return 0
    (r.transport === :direct && r.base_port > 0) ? r.base_port + 2 : 0
end

# ── Introduce a friend group ─────────────────────────────────────────────────────────────────────────
# Install bidirectional grants across every CROSS-HOST ordered pair in `names` (§5.1: one introduction
# covers both directions, either region may later be source or dest). Same-host pairs are skipped (they
# pull over loopback, no mesh). Idempotent. Returns the list of installed grants. NOTE (Phase 1): this
# installs for all cross-host pairs unconditionally; the consent flow (§5.1, later) restricts it to pairs
# a reachability probe says actually need the bridge.
function introduce_group!(names::AbstractVector)
    for n in names
        region_get(n) === nothing && error("mesh: unknown region '$n'")
    end
    installed = Any[]
    for a in names, b in names
        a == b && continue
        g = _mesh_install_grant!(a, b; port = _region_blob_port(a))   # a = source, b = puller
        g === nothing || push!(installed, g)
    end
    return installed
end

# ── Teardown (§5.5) ──────────────────────────────────────────────────────────────────────────────────
# Remove every artifact naming `region`, findable by its one basename tag `slate-<name>-<uuid8>`: on every
# host in the current region set (plus this region's own host) drop the tagged authorized_keys lines (it
# as puller OR source) and slate_known_hosts pins (it as source); then rm its keypair on its own host.
# Best-effort — never throws; logs. LIMITATION: a peer whose region was ALREADY deleted isn't in the set,
# so an artifact on that vanished peer's host can linger; `peer_plan` surfaces such orphans.
function teardown_region_mesh!(region)
    r = region_get(region)
    r === nothing && return nothing
    _mesh_grant_forget_region!(r.name)   # its on-host grants are about to go — drop the port cache too
    tag = _mesh_basename(r.name)
    hosts = unique(String[r.host; [x.host for x in regions()]...])
    for h in hosts
        try; _mesh_file_drop!(h, "authorized_keys", tag); catch e; _rlog("mesh teardown: authkeys on $h — $(first(sprint(showerror, e), 120))"); end
        try; _mesh_file_drop!(h, "slate_known_hosts", tag); catch e; _rlog("mesh teardown: known_hosts on $h — $(first(sprint(showerror, e), 120))"); end
    end
    try
        _ssh_script(r.host, "rm -f \"\$HOME/.ssh/$tag\" \"\$HOME/.ssh/$tag.pub\"\n")
    catch e
        _rlog("mesh teardown: keypair rm on $(r.host) — $(first(sprint(showerror, e), 120))")
    end
    _rlog("mesh: torn down all '$(r.name)' ($tag) artifacts across $(length(hosts)) host(s)")
    return nothing
end

# ── Dry-run diagnostic / audit (§6.2) ────────────────────────────────────────────────────────────────
# Reconstruct and PRINT — without executing — what the mesh looks like for `names`: the last-cached route
# verdict per ordered cross-host pair (the topology map), the slate artifacts actually present on each host,
# and the exact `ssh -N -L` line `_pull_ssh!` would run. Doubles as the ownership-reconciliation view.
# `refresh=true` first FORGETS the cached verdicts for these hosts, so the next transfer re-probes (the DAG
# "recalculate" action) — the fresh verdict lands on that transfer, not here (probing needs live workers).
function peer_plan(names::AbstractVector; refresh::Bool = false)
    io = IOBuffer()
    hosts = unique(String[region_get(n) === nothing ? "?" : region_get(n).host for n in names])
    if refresh
        for h in hosts; h == "?" || _peer_route_forget!(h); end
        println(io, "(route cache cleared for $(join(filter(!=("?"), hosts), ", ")) — next transfer re-probes)")
    end
    println(io, "── cached route verdicts (src → dst : kind @ addr, age) ──")
    for a in names, b in names
        a == b && continue
        ra = region_get(a); rb = region_get(b)
        (ra === nothing || rb === nothing || ra.host == rb.host) && continue
        v = _peer_route_load(ra.host, rb.host)      # b pulls from a ⇒ keyed (a.host, b.host)
        println(io, v === nothing ? "  $b ← $a : (not yet resolved)" :
            "  $b ← $a : $(v[1]) @ $(v[2])  ($(round(Int, time() - v[3]))s ago)")
    end
    println(io, "── mesh artifacts on hosts ──")
    for h in hosts
        h == "?" && continue
        script = """
        echo 'keys:'; ls -1 "\$HOME/.ssh"/slate-* 2>/dev/null | sed 's|.*/|  |'
        echo 'authorized_keys (slate):'; grep -F 'slate-' "\$HOME/.ssh/authorized_keys" 2>/dev/null | sed 's/^/  /'
        echo 'slate_known_hosts:'; cat "\$HOME/.ssh/slate_known_hosts" 2>/dev/null | sed 's/^/  /'
        """
        ok, out = _ssh_script(h, script)
        println(io, "▸ $h"); println(io, ok ? rstrip(out) : "  (ssh failed)")
    end
    println(io, "── peer pull commands (per cross-host pair) ──")
    for a in names, b in names
        a == b && continue
        ra = region_get(a); rb = region_get(b)
        (ra === nothing || rb === nothing || ra.host == rb.host) && continue
        port = _region_blob_port(a); port = port > 0 ? port : 1
        aip = _region_peer_addr(a, ra.host); au = _ssh_user(ra.host)
        tgt = isempty(au) ? aip : "$au@$aip"
        note = _region_blob_port(a) > 0 ? "" : "  (placeholder port — tunnel source, finalized at transfer)"
        println(io, "$b ← $a$note")
        println(io, "  ssh -i $(_mesh_key_path(b)) -o IdentitiesOnly=yes -o UserKnownHostsFile=$(_mesh_known_hosts()) \\")
        println(io, "      -o StrictHostKeyChecking=yes -N -L <lport>:127.0.0.1:$port $tgt")
    end
    return String(take!(io))
end
