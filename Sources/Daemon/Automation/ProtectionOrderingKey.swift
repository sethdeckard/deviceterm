// SPDX-License-Identifier: GPL-3.0-or-later
//
// ProtectionOrderingKey: the daemon-internal ordering key for tab-protection
// last-write-wins AND for reconnect membership reconciliation. Never crosses
// the wire (only its `revision` half does, in `SessionSetProtectedBatchParams`);
// the `epoch` half is server-derived from the caller's monotonic XPC
// connection id, so a client can neither forge nor rewind it.
//
// Lexicographic `(epoch, tier, revision)`:
//   - `epoch`: a newer connection (higher epoch) always dominates any older
//     one, which is what defeats a GUI restart replaying low revision numbers
//     or a stale request arriving after a reconnect.
//   - `tier`: at ONE epoch, a reconnect restore establishes a `.restoreBaseline`
//     that any live user action on the same connection (`.liveAuthority`)
//     outranks. So a `setProtectedBatch`/`protectionSnapshot` the user issues AFTER a
//     reconnect restore always wins over the restore's inventory value, while two
//     restores on one connection still order by their `revision`, and a live
//     `session.create` membership assertion is never reaped by a same-connection
//     restore that merely raced it. Epoch is compared first, so a strictly-newer
//     connection's restore still dominates any older-connection live action.
//   - `revision`: within one epoch and tier, the client's monotonically
//     increasing `revision` orders successive sends (restore retries against
//     each other; protection writes against each other).
//
// A batch/assertion applies only when its key strictly dominates the stored key
// of every target.
struct ProtectionOrderingKey: Comparable, Sendable, Equatable {
    /// Ordering tier within one epoch. `.restoreBaseline` is a reconnect
    /// restore's inventory assertion; `.liveAuthority` is a live user action (a
    /// `session.create` membership stamp, a `setProtectedBatch`, or a
    /// `protectionSnapshot` fence). Live authority outranks the restore baseline at
    /// the same epoch: see the file header.
    enum Tier: Int, Comparable, Sendable {
        case restoreBaseline = 0
        case liveAuthority = 1

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let epoch: UInt64
    let tier: Tier
    let revision: Int

    /// `tier` defaults to `.liveAuthority` so the protection call sites
    /// (`setProtectedBatch`, `protectionSnapshot`) that build a key from a user
    /// action need not name it; only `restoreBatch` passes `.restoreBaseline`.
    init(epoch: UInt64, revision: Int, tier: Tier = .liveAuthority) {
        self.epoch = epoch
        self.tier = tier
        self.revision = revision
    }

    static func < (lhs: ProtectionOrderingKey, rhs: ProtectionOrderingKey) -> Bool {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        return lhs.revision < rhs.revision
    }
}
