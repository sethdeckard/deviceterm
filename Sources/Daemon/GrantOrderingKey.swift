// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Daemon-internal ordering key for automation grants, mirroring
/// `ProtectionOrderingKey`. Lexicographic `(epoch, revision)`: `epoch` is
/// server-derived from the issuing XPC connection id (monotonic, so a
/// reconnected GUI always dominates an older one and a client can't forge
/// or rewind it); `revision` orders successive requests within one
/// connection. A grant or revoke applies only when its key **strictly
/// dominates** the target session's stored key. So a stale grant that runs
/// after a newer revoke (the non-FIFO XPC task hazard) can never resurrect
/// authority.
struct GrantOrderingKey: Comparable, Sendable, Equatable {
    let epoch: UInt64
    let revision: Int

    static func < (lhs: GrantOrderingKey, rhs: GrantOrderingKey) -> Bool {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
        return lhs.revision < rhs.revision
    }
}
