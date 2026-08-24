// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The subset of an on-screen window the chooser reasons about.
struct CandidateWindow: Equatable, Sendable {
    let windowID: UInt32
    /// Window-server layer. Ordinary document windows sit at layer 0;
    /// an app-modal `NSAlert` sits higher (the modal panel level); the
    /// menu-bar status item sits at the status/overlay level.
    let layer: Int
    /// Area in points²; a tiebreaker.
    let area: Double
    let bundleID: String?
    let isOnScreen: Bool
    /// Owning process, when the window server reports an owner. Production
    /// candidates read this and `bundleID` from the same optional
    /// `owningApplication`, so they are present or absent together.
    let pid: pid_t?
}
