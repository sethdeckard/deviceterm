// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Device-only per-frame lease identity. `acquireHold` reserves a
/// subscription hold for a token on this exact `(epoch, generation)`.
struct LeaseMetadata: Sendable {
    let epoch: UInt64
    let generation: UInt64
    /// Reserve a provisional subscription hold for `token` on this frame.
    /// Returns nil when the token is not `active`/unknown, the generation
    /// is `≤ highestReserved`, or it is `< acceptedLowestHeld` (below the
    /// acked frontier). Release is NOT per-frame metadata: a
    /// `pane.surfaceRelease` watermark routes through its own connection-
    /// checked handler.
    let acquireHold: @Sendable (_ token: UUID) async -> Grant?
}
