// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The subset of an on-screen window the chooser reasons about.
struct CandidateWindow: Equatable, Sendable {
    let windowID: UInt32
    /// Window-server layer. Ordinary document windows sit at layer 0 and
    /// an app-modal `NSAlert` sits higher (the modal panel level). The
    /// status-item selector does not depend on this value because
    /// ScreenCaptureKit reports menu-extra layers inconsistently.
    let layer: Int
    /// Area in points²; a tiebreaker.
    let area: Double
    let bundleID: String?
    let isOnScreen: Bool
    /// Owning process, when the window server reports an owner. A status
    /// item is selected by this identity because its bundle and layer
    /// metadata are not stable enough to identify the badge.
    let pid: pid_t?
}
