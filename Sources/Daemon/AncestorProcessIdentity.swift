// SPDX-License-Identifier: GPL-3.0-or-later
//
// AncestorProcessIdentity: one verified hop on a UDS caller's parent chain.
//
// The terminal provenance arm asks whether a caller belongs to the session's
// bound terminal. A caller that detached does not, but its parent chain still
// leads back into the tab, and an agent harness that runs each command under
// `setsid` is exactly that shape. So the arm scans the caller's ancestors as
// well as the caller itself, and this type is one entry in that scan.
//
// Deliberately NOT a `PeerProcessIdentity`. An ancestor has no audit token, so
// reusing that type would mean inventing a `pidVersion` for it, and a
// fabricated `0` could equal a session owner that also carries `0` and reach
// the owner arm. An ancestor carries only the terminal triple the match
// compares plus the two facts the walk's own guards need, which leaves it
// structurally incapable of authorizing as an owner.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A process on the caller's parent chain, verified as a hop by the walk that
/// produced it. Its terminal triple has the same meaning and the same source as
/// `PeerProcessIdentity`'s, so `ProvenanceMatcher` compares it against a
/// `TerminalAnchor` with the same test.
public struct AncestorProcessIdentity: Sendable, Equatable {
    public let pid: pid_t
    /// Effective uid, checked against the peer's before this entry was
    /// admitted. The walk stops at a uid boundary, so every entry shares the
    /// peer's uid.
    public let euid: uid_t
    /// Start time in microseconds since the epoch. Used with the linkage check
    /// to reject a recycled parent pid: the walk requires this to be no later
    /// than the child's, which narrows the race the linkage check closes.
    public let startMicros: UInt64
    /// POSIX session id (`getsid`). Its numeric value is the session leader's
    /// pid.
    public let posixSessionId: pid_t
    /// Controlling terminal device, or `NODEV` when this ancestor has none.
    public let controllingTTYDev: dev_t
    /// Start time of the POSIX session leader, in microseconds since the epoch.
    /// `0` when the leader's start time was unavailable; only a nonzero value
    /// provides the reuse guard, and a `0` here matches no real anchor.
    public let posixSessionLeaderStartTime: UInt64

    public init(
        pid: pid_t,
        euid: uid_t,
        startMicros: UInt64,
        posixSessionId: pid_t,
        controllingTTYDev: dev_t,
        posixSessionLeaderStartTime: UInt64
    ) {
        self.pid = pid
        self.euid = euid
        self.startMicros = startMicros
        self.posixSessionId = posixSessionId
        self.controllingTTYDev = controllingTTYDev
        self.posixSessionLeaderStartTime = posixSessionLeaderStartTime
    }
}

public extension AncestorProcessIdentity {
    /// Maximum ancestry depth. A walk normally stops earlier, at pid 1, at a
    /// uid boundary, or at a hop it cannot read; this bounds the case where
    /// none of those arrives.
    static let maxWalkDepth = 32

    /// Whether a hop may be admitted as the parent of an entry that started at
    /// `childStart`, for a peer running as `peerEUID`.
    ///
    /// Split out of the walk because these two guards are the ones a
    /// real-process test cannot stage: recycling a pid and crossing a uid
    /// boundary both need conditions a test can't create. As a pure predicate
    /// they are checkable against synthetic values.
    ///
    /// - A parent cannot have started after its child. A pid isn't free for
    ///   reuse until the real parent dies, and that death reparents the child
    ///   to pid 1, so a process grafted onto a recycled ppid necessarily
    ///   started after the child did. This is a wall-clock comparison at
    ///   microsecond resolution, so it cannot by itself separate a replacement
    ///   created inside the same tick; `linkageHolds` is the exact guard, and
    ///   this one narrows the window it has to cover.
    /// - A uid boundary ends the walk. It costs the arm nothing: the tab's
    ///   shell is user-owned and sits in the anchored session, so it is already
    ///   in the prefix by the time the chain reaches a root-owned ancestor like
    ///   `login`. The boundary hop is read in order to stop at it, never
    ///   traversed and never added.
    ///
    /// The comparison is `<=` rather than `<` because a parent and child can
    /// legitimately record the same start microsecond.
    internal static func admitsHop(
        startMicros: UInt64,
        euid: uid_t,
        childStart: UInt64,
        peerEUID: uid_t
    ) -> Bool {
        startMicros <= childStart && euid == peerEUID
    }

    /// Whether the child still names `expectedParent` as its parent and is
    /// still the same process instance, re-read after the parent was read.
    ///
    /// This is the exact form of the graft guard, and it does not depend on
    /// clock resolution the way `admitsHop`'s start-time comparison does. A
    /// parent's death reparents its children to launchd, so a child that still
    /// names `expectedParent` proves that pid was not freed and recycled
    /// between the two reads. `expectedChildStart` catches the other end of the
    /// race, where the child itself was replaced mid-walk.
    ///
    /// A child the kernel will no longer name is not a confirmation, so a nil
    /// snapshot fails.
    internal static func linkageHolds(
        childPPID: pid_t?,
        childStart: UInt64?,
        expectedParent: pid_t,
        expectedChildStart: UInt64
    ) -> Bool {
        childPPID == expectedParent && childStart == expectedChildStart
    }

    /// The verified same-euid ancestor prefix above `peer`, nearest parent
    /// first.
    ///
    /// This is deliberately **anchor-agnostic**: it verifies chain linkage and
    /// returns data, and it never asks whether an entry matches anything. The
    /// matcher owns that decision, which is what keeps the authority policy in
    /// one pure, hermetically-tested place.
    ///
    /// Truncation is not denial. Reaching pid 1, crossing a uid boundary,
    /// exhausting `maxWalkDepth`, or failing to read the next hop all stop the
    /// walk and all preserve the entries already verified. An empty result
    /// means the ancestry arm has nothing to match, never that the peer's own
    /// arms should be denied.
    static func verifiedPrefix(above peer: PeerProcessIdentity) -> [AncestorProcessIdentity] {
        #if canImport(Darwin)
        // Hop zero's own record supplies the ppid to start from and the start
        // time the first monotonic comparison is made against. The peer's
        // terminal facts are already on `PeerProcessIdentity` and the matcher
        // tests those directly, so hop zero never enters this list.
        guard let origin = ProcInfo.snapshot(of: peer.pid) else { return [] }
        var prefix: [AncestorProcessIdentity] = []
        var childPid = origin.pid
        var childStart = origin.startMicros
        var next = origin.ppid
        var depth = 0
        while depth < maxWalkDepth, next > 1 {
            // A hop the kernel won't name (it exited mid-walk) truncates.
            guard let hop = ProcInfo.snapshot(of: next) else { break }
            // The graft and uid-boundary guards; see `admitsHop`.
            guard admitsHop(
                startMicros: hop.startMicros,
                euid: hop.euid,
                childStart: childStart,
                peerEUID: peer.euid
            ) else { break }
            // Re-read the child now that its parent has been read, and confirm
            // the edge between them still exists; see `linkageHolds`. Without
            // this the walk trusts a ppid it read strictly before the parent,
            // which is the window a recycled pid needs.
            let child = ProcInfo.snapshot(of: childPid)
            guard linkageHolds(
                childPPID: child?.ppid,
                childStart: child?.startMicros,
                expectedParent: next,
                expectedChildStart: childStart
            ) else { break }
            let sid = getsid(hop.pid)
            guard sid != -1 else { break }
            prefix.append(
                AncestorProcessIdentity(
                    pid: hop.pid,
                    euid: hop.euid,
                    startMicros: hop.startMicros,
                    posixSessionId: sid,
                    controllingTTYDev: hop.controllingTTYDev,
                    // Same `0` sentinel discipline as `PeerProcessIdentity`: an
                    // unavailable leader start degrades this one entry instead
                    // of truncating the walk, and `0` matches no real anchor.
                    posixSessionLeaderStartTime: ProcInfo.leaderStartMicros(sid) ?? 0
                )
            )
            childPid = hop.pid
            childStart = hop.startMicros
            next = hop.ppid
            depth += 1
        }
        return prefix
        #else
        return []
        #endif
    }
}
