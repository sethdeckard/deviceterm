// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol

struct OrphanRecord: Sendable, Equatable {
    let sessionId: String
    let sessionDir: String
    let liveSims: [OrphanLiveSim]
}
