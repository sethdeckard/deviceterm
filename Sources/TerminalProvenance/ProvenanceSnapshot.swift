// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Hop zero plus its verified ancestor prefix, resolved together for one
/// request: a UDS caller's kernel provenance as of that request.
///
/// `PeerProcessIdentity` is captured once, at accept. That is enough to name the
/// process on the far end, but not enough to answer "does this caller still
/// reach the session's terminal?" on every request, because authority follows
/// the live parent chain and a chain can be severed while the connection stays
/// open. So the chain is resolved per scoped request rather than cached, and a
/// snapshot is what one resolution returns: hop zero, re-read from the socket's
/// audit token, plus the verified ancestor prefix above it.
///
/// The two travel together but stay separate values. A walk that finds nothing
/// yields an empty prefix, never a nil snapshot, so a failed or truncated walk
/// denies only the ancestry arm and leaves the owner and direct-terminal arms
/// exactly as they were.
public struct ProvenanceSnapshot: Sendable, Equatable {
    /// The connected process, resolved from the socket's audit token.
    public let peer: PeerProcessIdentity
    /// The verified same-euid ancestor prefix above `peer`, nearest parent
    /// first. Empty when the walk found nothing to verify.
    public let ancestors: [AncestorProcessIdentity]

    public init(peer: PeerProcessIdentity, ancestors: [AncestorProcessIdentity]) {
        self.peer = peer
        self.ancestors = ancestors
    }
}

/// Injectable request-time seam. Returns nil when the kernel can't vend hop
/// zero, which callers MUST treat as fail-closed; it never signals a failed
/// walk, which is an empty `ancestors` instead.
public typealias ProvenanceSnapshotResolver = @Sendable (Int32) -> ProvenanceSnapshot?

/// Compose a snapshot resolver over a peer resolver, so hop zero comes from
/// whatever `PeerIdentityResolver` the connection was built with and the walk
/// starts from that.
///
/// Composition rather than a second independent seam is what keeps the existing
/// harnesses honest: a test that injects a synthetic peer keeps governing hop
/// zero at request time too, instead of silently falling through to a real
/// `LOCAL_PEERTOKEN` read on a loopback fd.
///
/// The peer is resolved on both sides of the walk, and the walk's result is
/// discarded unless the same `(pid, pidVersion)` comes back. The first resolve
/// validates the audit token, but the walk then seeds from a bare numeric pid,
/// so a peer that exits mid-walk and has its pid recycled would otherwise let
/// the replacement's parent chain be read as this caller's. Re-resolving closes
/// that: `pidVersion` is monotonic, so a recycled pid can never re-match the
/// token and the second resolve fails instead.
public func composedProvenanceSnapshotResolver(
    peer resolvePeer: @escaping PeerIdentityResolver
) -> ProvenanceSnapshotResolver {
    { fd in
        guard let peer = resolvePeer(fd) else { return nil }
        let ancestors = AncestorProcessIdentity.verifiedPrefix(above: peer)
        guard let confirmed = resolvePeer(fd) else { return nil }
        guard confirmed.pid == peer.pid, confirmed.pidVersion == peer.pidVersion else { return nil }
        return ProvenanceSnapshot(peer: peer, ancestors: ancestors)
    }
}
