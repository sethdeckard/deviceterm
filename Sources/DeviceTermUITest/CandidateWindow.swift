// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// The subset of an on-screen window the chooser reasons about.
struct CandidateWindow: Equatable, Sendable {
    let windowID: UInt32
    /// Window-server layer. Ordinary document windows sit at layer 0 and
    /// an app-modal `NSAlert` sits higher (the modal panel level).
    ///
    /// Used to keep overlay chrome out of *content* selection, and only in
    /// that direction. ScreenCaptureKit does not report menu-extra layers
    /// consistently, so `WindowChooser.chooseStatusItem` does not consult
    /// this at all: a layer test there would reject the badge window it is
    /// looking for.
    let layer: Int
    /// Screen frame in top-left-origin points, matching the coordinate
    /// space `AXElementReader.frame(of:)` reports. That is what lets a
    /// status item's accessibility frame be matched against a window.
    let frame: CGRect
    let bundleID: String?
    let isOnScreen: Bool
    /// Owning process, when the window server reports an owner.
    ///
    /// This identifies *content* windows, whose owner is the application
    /// itself. It cannot find a status item: macOS hosts every menu-bar
    /// extra in Control Center's process, so the window server attributes
    /// the badge to Control Center and the vending application owns no
    /// on-screen window at all. `WindowChooser.chooseStatusItem` matches
    /// geometry instead.
    let pid: pid_t?

    /// Area in points², a tiebreaker for both selectors.
    var area: Double { Double(frame.width) * Double(frame.height) }
}
