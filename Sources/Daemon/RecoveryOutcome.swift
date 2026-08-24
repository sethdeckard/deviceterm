// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import IOSurface

/// Outcome of a controlled recovery attempt from sustained exhaustion. At
/// most one retirement is ever attempted per pool.
enum RecoveryOutcome: Sendable, Equatable {
    /// The active epoch was retired; the *next* `acquire` allocates the
    /// replacement epoch (recovery itself doesn't allocate).
    case recovered
    /// Recovery was unavailable: already consumed once, or `retireAll`
    /// failed (the quarantine budget is full). The pane must fail.
    case exhausted
}
