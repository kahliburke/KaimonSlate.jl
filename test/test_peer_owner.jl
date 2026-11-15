# src/peer_owner.jl — which local account opened a loopback connection, from the kernel's sock_diag.
#
# The wire format is checked everywhere; the live lookup only runs on Linux, the one platform with
# sock_diag. A wrong field offset would not fail loudly there: the kernel would find no socket and the
# hub would refuse its own user, or read the uid from the wrong bytes.
using ReTest, Sockets
include(joinpath(@__DIR__, "..", "src", "peer_owner.jl"))
using .PeerOwner

@testset "peer owner" begin
    @testset "loopback addresses" begin
        @test PeerOwner.is_loopback((0x7f, 0x00, 0x00, 0x01))
        @test PeerOwner.is_loopback((0x7f, 0x01, 0x02, 0x03))                 # all of 127/8
        @test !PeerOwner.is_loopback((0x0a, 0x00, 0x00, 0x01))
        @test PeerOwner.is_loopback(UInt8[zeros(UInt8, 15); 0x01])            # ::1
        @test PeerOwner.is_loopback(PeerOwner.v4mapped((0x7f, 0, 0, 1)))       # ::ffff:127.0.0.1
        @test !PeerOwner.is_loopback(PeerOwner.v4mapped((0x0a, 0, 0, 1)))
        @test !PeerOwner.is_loopback(UInt8[0xfe; 0x80; zeros(UInt8, 13); 0x01])
    end

    @testset "request layout" begin
        r = PeerOwner.diag_request(PeerOwner.AF_INET, (0x7f, 0, 0, 1), 0xc1f2, (0x7f, 0, 0, 1), 8765)
        @test length(r) == PeerOwner.DIAG_REQ_LEN == 72
        @test reinterpret(UInt32, r[1:4])[1] == 72                             # nlmsg_len, host order
        @test reinterpret(UInt16, r[5:6])[1] == PeerOwner.SOCK_DIAG_BY_FAMILY
        @test reinterpret(UInt16, r[7:8])[1] == PeerOwner.NLM_F_REQUEST       # a lookup, not a dump
        @test r[17] == PeerOwner.AF_INET && r[18] == PeerOwner.IPPROTO_TCP
        @test r[25:26] == [0xc1, 0xf2]                                         # sport, network order
        @test r[27:28] == [0x22, 0x3d]                                         # dport 8765
        @test r[29:32] == [0x7f, 0, 0, 1] && all(iszero, r[33:44])            # src, padded to 16
        @test r[45:48] == [0x7f, 0, 0, 1] && all(iszero, r[49:60])            # dst
        @test all(==(0xff), r[65:72])                                          # INET_DIAG_NOCOOKIE
    end

    @testset "reply parsing" begin
        hdr(typ, len) = UInt8[reinterpret(UInt8, [UInt32(len)]); reinterpret(UInt8, [UInt16(typ)]);
                              zeros(UInt8, 10)]
        msg = zeros(UInt8, PeerOwner.DIAG_MSG_LEN)
        msg[PeerOwner.UID_OFFSET+1:PeerOwner.UID_OFFSET+4] = reinterpret(UInt8, [UInt32(116015)])
        @test PeerOwner.reply_uid([hdr(PeerOwner.SOCK_DIAG_BY_FAMILY, 88); msg]) == 116015
        # The kernel answers an unknown socket with NLMSG_ERROR (ENOENT), which is "no owner", not uid 0.
        @test PeerOwner.reply_uid([hdr(PeerOwner.NLMSG_ERROR, 36); zeros(UInt8, 20)]) === nothing
        @test PeerOwner.reply_uid(UInt8[]) === nothing
        @test PeerOwner.reply_uid(hdr(PeerOwner.SOCK_DIAG_BY_FAMILY, 16)) === nothing   # truncated
    end

    @testset "who may connect" begin
        @test PeerOwner.accepts(UInt32(501), UInt32(501))
        @test !PeerOwner.accepts(UInt32(502), UInt32(501))
        @test !PeerOwner.accepts(nothing, UInt32(501))
        @test !PeerOwner.accepts(UInt32(0), UInt32(501))
        # WSL: the localhost relay runs as root, and mirrored networking leaves no Linux socket.
        @test PeerOwner.accepts(UInt32(0), UInt32(501); wsl = true)
        @test PeerOwner.accepts(nothing, UInt32(501); wsl = true)
        @test !PeerOwner.accepts(UInt32(502), UInt32(501); wsl = true)
        @test PeerOwner.is_wsl("6.6.87.2-microsoft-standard-WSL2\n")
        @test PeerOwner.is_wsl("4.4.0-19041-Microsoft")
        @test !PeerOwner.is_wsl("6.8.0-48-generic")
        @test !PeerOwner.is_wsl("")
    end

    # The fallback when sock_diag is unavailable (no tcp_diag module, and loading it disabled).
    # /proc prints each address word in host byte order, so these literals are little-endian forms.
    if ENDIAN_BOM == 0x04030201
        @testset "/proc/net/tcp parsing" begin
            @test PeerOwner.proc_addr("0100007F:223D") == (UInt8[0x7f, 0, 0, 1], 8765)
            @test PeerOwner.proc_addr("0000000000000000FFFF00000100007F:223D") ==
                  (PeerOwner.v4mapped((0x7f, 0, 0, 1)), 8765)
            lines = [
                "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode",
                "   0: 0100007F:223D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 116015        0 1 1",
                "   1: 0100007F:93D0 0100007F:223D 01 00000000:00000000 00:00000000 00000000 98679        0 2 1",
                "   2: 0100007F:93D1 0100007F:223D 01 00000000:00000000 00:00000000 00000000 116015       0 3 1",
            ]
            lo = UInt8[0x7f, 0, 0, 1]
            @test PeerOwner.proc_owner(lines, lo, 0x93d0, lo, 8765) == 98679   # another account
            @test PeerOwner.proc_owner(lines, lo, 0x93d1, lo, 8765) == 116015
            @test PeerOwner.proc_owner(lines, lo, 0x93d2, lo, 8765) === nothing
            # The listener's own line has the right local end but no remote end; it is not a peer.
            @test PeerOwner.proc_owner(lines, lo, 8765, UInt8[0, 0, 0, 0], 0) == 116015
            @test PeerOwner.proc_owner(lines, lo, 8765, lo, 0x93d0) === nothing
        end
    end

    if Sys.islinux()
        @testset "live lookup (Linux)" begin
            bytes(ip::IPv4) = reverse(reinterpret(UInt8, [ip.host]))
            srv = listen(ip"127.0.0.1", 0); _, lport = getsockname(srv)
            cli = connect(ip"127.0.0.1", lport); acc = accept(srv)
            try
                pip, pport = getpeername(acc)
                @test PeerOwner.owner_uid(bytes(pip), pport, bytes(ip"127.0.0.1"), lport) == PeerOwner.my_uid()
                @test PeerOwner.owner_uid(bytes(pip), 1, bytes(ip"127.0.0.1"), lport) === nothing
                # Both sources on their own: either may be the one a given machine has.
                @test PeerOwner._proc_lookup(bytes(pip), pport, bytes(ip"127.0.0.1"), lport) == PeerOwner.my_uid()
                d = try; PeerOwner._diag_owner(bytes(pip), pport, bytes(ip"127.0.0.1"), lport); catch; nothing; end
                @test d === nothing || d == PeerOwner.my_uid()
            finally
                close(cli); close(acc); close(srv)
            end
        end
    end
end
