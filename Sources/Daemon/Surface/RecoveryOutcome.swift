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
    /// Recovery unavailable; capacity is already free or consumer releases
    /// can unblock acquisition. A slow consumer frees its slots as it catches
    /// up, so the producer keeps dropping frames rather than failing the pane.
    /// Nothing is allocated, so memory stays bounded.
    case consumerBehind
    /// Recovery unavailable; consumer releases cannot unblock acquisition.
    /// The pane must fail.
    case exhausted
}
