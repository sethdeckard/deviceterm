// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// A dead-owner session dir the filesystem scan found, with the UDIDs
/// its `owned-udids.json` manifest named (may be empty).
struct DeadSessionCandidate: Sendable, Equatable {
    let sessionId: String
    let sessionDir: String
    let manifestUDIDs: [String]
}
