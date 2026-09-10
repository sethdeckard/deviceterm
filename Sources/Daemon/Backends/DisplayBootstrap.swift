// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// Everything one display bootstrap read, so the caller needs no follow-up
/// round trip to finish building its pane.
struct DisplayBootstrap: Sendable, Equatable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    /// The display's orientation at start, or nil when it has none to give.
    let seedOrientation: Orientation?
    /// False when the display vends no orientation source, which leaves the
    /// pane on its last known orientation rather than failing it.
    let observingOrientation: Bool
}
