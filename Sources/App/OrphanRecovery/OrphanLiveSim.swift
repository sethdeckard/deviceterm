// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol

/// One sim that's currently Booted *and* attributable to a dead
/// session (by GUI manifest or by daemon `ownedBySession`).
struct OrphanLiveSim: Sendable, Equatable {
    let udid: String
    let displayName: String
}
