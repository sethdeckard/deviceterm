// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// Pure "which window do we screenshot?" logic.
///
/// Split out from `CaptureService` so the selection rules are unit-
/// testable without ScreenCaptureKit, a GUI, or a TCC grant.
enum WindowChooser {
    /// Window-server layer at/above which a window is menu-bar / overlay
    /// chrome (status items, tooltips), never document content. This is
    /// `NSStatusWindowLevel` (25), the layer menu-bar extras report.
    static let overlayLayer = 25

    /// How much taller than the item it draws a status item's hosting
    /// window may be. Generous, because the bound only has to separate a
    /// menu-bar-height window from a document-height one.
    static let hostHeightTolerance: Double = 2

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

    /// Pick the window hosting a status item, given that item's
    /// accessibility frame.
    ///
    /// Selection is by *geometry*, not ownership. macOS hosts every
    /// menu-bar extra in Control Center's process, so the window server
    /// attributes the badge to Control Center and the vending application
    /// owns no on-screen window: neither its bundle id nor its pid can
    /// reach the window, because both describe the same wrong process.
    /// The accessibility frame (`StatusItemLocator`) is the one identifier
    /// that still names the item as the daemon's.
    ///
    /// Matches on the AX frame's *centre* rather than rect equality: the
    /// hosting window need not share the item's bounds. Roughly ten
    /// menu-bar extras sit on screen at once at distinct offsets, so the
    /// centre separates them.
    ///
    /// A content window under the menu bar contains the item's centre too,
    /// so eligibility is bounded by *height*: a hosting window is about as
    /// tall as the item it draws, while a document window is taller by
    /// orders of magnitude. Height rather than window layer, because
    /// ScreenCaptureKit does not report menu-extra layers consistently and
    /// a layer test can reject the very window it should pick.
    ///
    /// Ties break on *smallest area*, so an open dropdown never wins over
    /// the button that raised it.
    ///
    /// Deliberately does not filter on `isOnScreen`: ScreenCaptureKit is
    /// already restricted to on-screen windows, and menu-bar extras do not
    /// reliably report the flag either.
    static func chooseStatusItem(
        from candidates: [CandidateWindow],
        axFrame: CGRect
    ) -> CandidateWindow? {
        let centre = CGPoint(x: axFrame.midX, y: axFrame.midY)
        let tallestHost = Double(axFrame.height) * hostHeightTolerance
        return candidates
            .filter {
                $0.area > 0
                    && $0.frame.contains(centre)
                    && Double($0.frame.height) <= tallestHost
            }
            .min { $0.area < $1.area }
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

    // `choose` and its ambiguity check share this filter, so the check can
    // never disagree with the selector it guards about which windows are in
    // scope. `chooseStatusItem` needs no such pairing: it selects on
    // geometry, and its ambiguity is settled upstream by
    // `StatusItemLocator`, before any window is considered.
    private static func ownedContent(
        _ candidates: [CandidateWindow],
        bundleID: String
    ) -> [CandidateWindow] {
        candidates.filter {
            $0.bundleID == bundleID && $0.isOnScreen && $0.layer < overlayLayer
        }
    }

    private static func depth(of windowID: UInt32, in frontToBack: [UInt32]) -> Int {
        frontToBack.firstIndex(of: windowID) ?? Int.max
    }
}
