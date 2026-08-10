// SPDX-License-Identifier: GPL-3.0-or-later
//
// WindowChooser: pure "which window do we screenshot?" logic.
//
// Split out from `CaptureService` so the selection rules are unit-
// testable without ScreenCaptureKit, a GUI, or a TCC grant.

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
}

enum WindowChooser {
    /// Window-server layer at/above which a window is menu-bar / overlay
    /// chrome (status items, tooltips), never document content. This is
    /// `NSStatusWindowLevel` (25), the layer menu-bar extras report.
    static let overlayLayer = 25

    /// Pick the frontmost *content* window owned by `bundleID`: the main
    /// window, or an app-modal alert (close-tab / ⌘Q prompt) on top of it.
    ///
    /// `frontToBack` is the window-server ordering (front first), the only
    /// reliable "what's on top" signal, since the shareable-content list
    /// carries no ordering guarantee. Windows missing from it sort last;
    /// ties break on larger area.
    ///
    /// No layer-0 preference: an app-modal `NSAlert` sits *above* layer 0,
    /// so preferring layer 0 would capture the window behind the prompt
    /// instead of the prompt. Overlay-layer windows (menu-bar items,
    /// tooltips) are excluded so a stray one can never be mistaken for a
    /// document window; those are captured deliberately via the
    /// status-item path.
    static func choose(
        from candidates: [CandidateWindow],
        bundleID: String,
        frontToBack: [UInt32]
    ) -> CandidateWindow? {
        let owned = candidates.filter {
            $0.bundleID == bundleID && $0.isOnScreen && $0.layer < overlayLayer
        }
        guard !owned.isEmpty else { return nil }
        // Frontmost by window-server order; larger area breaks depth ties.
        return owned.min { lhs, rhs in
            let lhsDepth = depth(of: lhs.windowID, in: frontToBack)
            let rhsDepth = depth(of: rhs.windowID, in: frontToBack)
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.area > rhs.area
        }
    }

    /// Pick the app's menu-bar status-item window: an owned, on-screen
    /// window at the overlay layer. Returns nil when the app shows none,
    /// which, for the daemon, is exactly how a hidden `📱 N` reads.
    ///
    /// Selects by *smallest area*, not front-most: the status button is a
    /// tiny window, so if its dropdown menu is also open (a larger overlay
    /// window, and frontmost), the small button still wins and the capture
    /// is the badge rather than the menu.
    static func chooseStatusItem(
        from candidates: [CandidateWindow],
        bundleID: String,
        frontToBack: [UInt32]
    ) -> CandidateWindow? {
        let owned = candidates.filter {
            $0.bundleID == bundleID && $0.isOnScreen && $0.layer >= overlayLayer
        }
        guard !owned.isEmpty else { return nil }
        return owned.min { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return depth(of: lhs.windowID, in: frontToBack) < depth(of: rhs.windowID, in: frontToBack)
        }
    }

    private static func depth(of windowID: UInt32, in frontToBack: [UInt32]) -> Int {
        frontToBack.firstIndex(of: windowID) ?? Int.max
    }
}
