// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The answer to a `PaneSnapshotRequest`, written as `<id>.done.json` once
/// every frame the burst took has been written or skipped, or as soon as the
/// request is refused.
struct PaneSnapshotOutcome: Codable, Equatable {
    /// Whether the request finished without an error. A burst that ran but
    /// could read back no frame is still `ok`, with `frames` at zero.
    let ok: Bool
    /// How many frames were written.
    let frames: Int
    /// The refusal, or the first write failure. After a write failure the
    /// frames written before it are still on disk.
    let error: String?

    static func refused(_ reason: String) -> PaneSnapshotOutcome {
        PaneSnapshotOutcome(ok: false, frames: 0, error: reason)
    }
}
