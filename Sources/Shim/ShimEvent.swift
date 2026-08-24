// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

struct ShimEvent: Sendable {
    let kind: ShimEventType
    /// The user's device spec verbatim (e.g. "iPhone 17 Pro",
    /// "booted", a UDID). Used as the fallback when the snapshot
    /// diff doesn't yield a unique transition.
    let deviceSpec: String
}
