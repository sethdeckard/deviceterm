// SPDX-License-Identifier: GPL-3.0-or-later
//
// WindowChooser: pure "which window do we screenshot?" logic.
//
// Split out from `CaptureService` so the selection rules are unit-
// testable without ScreenCaptureKit, a GUI, or a TCC grant.

import Foundation

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
        let owned = ownedContent(candidates, bundleID: bundleID)
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
    /// which, for the daemon, is exactly how a hidden badge reads.
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
        let owned = ownedStatusItem(candidates, bundleID: bundleID)
        guard !owned.isEmpty else { return nil }
        return owned.min { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return depth(of: lhs.windowID, in: frontToBack) < depth(of: rhs.windowID, in: frontToBack)
        }
    }

    /// Reported pids for processes owning content windows `choose` would
    /// consider. Candidates without a pid do not contribute to the set.
    ///
    /// More than one owner means the bundle id names two live instances,
    /// and no rule here can tell which the caller meant: front-most picks
    /// whichever happens to be on top. Callers refuse rather than choose.
    /// Scoped to the windows the selector sees, so an instance showing only
    /// a status item doesn't make a content capture look ambiguous. This
    /// is one of two inputs to that decision; see `TargetOwners`, since an
    /// instance showing nothing owns no window to be counted here.
    static func contentOwners(from candidates: [CandidateWindow], bundleID: String) -> Set<pid_t> {
        Set(ownedContent(candidates, bundleID: bundleID).compactMap(\.pid))
    }

    /// Reported pids for processes owning overlay windows
    /// `chooseStatusItem` would consider. Two live daemons each showing a
    /// badge is the case this catches.
    static func statusItemOwners(from candidates: [CandidateWindow], bundleID: String) -> Set<pid_t> {
        Set(ownedStatusItem(candidates, bundleID: bundleID).compactMap(\.pid))
    }

    // The two selectors and their ambiguity checks share these filters, so
    // a check can never disagree with the selector it guards about which
    // windows are in scope.
    private static func ownedContent(
        _ candidates: [CandidateWindow],
        bundleID: String
    ) -> [CandidateWindow] {
        candidates.filter {
            $0.bundleID == bundleID && $0.isOnScreen && $0.layer < overlayLayer
        }
    }

    private static func ownedStatusItem(
        _ candidates: [CandidateWindow],
        bundleID: String
    ) -> [CandidateWindow] {
        candidates.filter {
            $0.bundleID == bundleID && $0.isOnScreen && $0.layer >= overlayLayer
        }
    }

    private static func depth(of windowID: UInt32, in frontToBack: [UInt32]) -> Int {
        frontToBack.firstIndex(of: windowID) ?? Int.max
    }
}
