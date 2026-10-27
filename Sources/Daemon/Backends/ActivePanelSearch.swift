// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// What the display lane does after reading which panel a foldable has lit.
///
/// A fold or screen-properties change starts a search, and it can arrive
/// before iOS has decided which panel to light, so a reading that names the bound panel
/// is read again a few times before the search gives up. A reading that names
/// another panel moves the binding at once, without waiting for the old
/// panel's picture to fade. A failed read hands over to the content search,
/// which needs nothing but the framebuffers, and so does a search that runs
/// out of reads with no answer or with a rebind that kept failing, so a slow
/// transition is still followed.
enum ActivePanelSearch {
    enum Step: Equatable {
        case rebind(screenID: UInt32)
        case wait(nanoseconds: UInt64)
        case stop
        case searchByContent
    }

    /// Reads after the latest change before a search that has found no swap
    /// gives up. Each read takes about half a second, so this covers the
    /// couple of seconds a fold takes to settle.
    static let maxReads = 4
    static let retryIntervalNanoseconds: UInt64 = 100_000_000

    /// How often, and for how long, a rebound display is asked for a frame
    /// until its new panel has drawn. The move comes before the panel lights,
    /// and an idle device sends no frame callbacks when it does, so without
    /// asking the pane keeps the black frame it got at the move.
    static let litRefreshIntervalNanoseconds: UInt64 = 100_000_000

    /// When, in seconds after the display first binds, the lane looks for the
    /// lit panel again. A boot moves it with no fold to follow: iOS can light
    /// the inner panel first and the cover a while later, and nothing else
    /// prompts a look once the hinge is still.
    static let settleCheckSeconds: [UInt64] = [3, 8, 15, 30, 60]
    static let litRefreshAttempts = 30

    /// How many reads a speculative move (`orientationMovesPanel`) waits for
    /// `devicectl` to confirm it. `devicectl` can go on naming the previous
    /// panel for several seconds after iOS has moved.
    static let earlyMoveReads = 16

    /// How recently, in seconds, the hinge must have moved for an orientation
    /// change to count as iOS moving panels. iOS moves its scene during a
    /// fold or shortly after the hinge stops.
    static let hingeMoveWindowSeconds: Double = 3

    /// Whether an orientation reported while a fold is followed is likely iOS
    /// moving to the other panel: the hinge moved within
    /// `hingeMoveWindowSeconds` (`hingeMovedSecondsAgo`, nil if it never has),
    /// and the orientation differs from `shown`, the one the pane has.
    ///
    /// A heuristic, not proof. A fold doesn't turn the device, and a
    /// two-panel device's panels present a quarter turn apart however it's
    /// turned, so a changed orientation just after the hinge moved is most
    /// likely a panel switch; a rotation in that window would read the same.
    /// The move it prompts is speculative, and `devicectl` confirms or
    /// corrects it (`next(afterReads:reading:bound:movedEarlyTo:)`).
    static func orientationMovesPanel(
        held: Orientation,
        shown: Orientation?,
        hingeMovedSecondsAgo: Double?
    ) -> Bool {
        guard let shown, let ago = hingeMovedSecondsAgo, ago <= hingeMoveWindowSeconds else { return false }
        return held != shown
    }

    /// The next step after `reads` reads, the last of which said `reading`,
    /// while the display is bound to `bound`. `movedEarlyTo` is the panel an
    /// orientation change moved the display to, until `devicectl` agrees.
    static func next(
        afterReads reads: Int,
        reading: DeviceCtlDisplays.ActivePanel,
        bound: UInt32,
        movedEarlyTo: UInt32? = nil
    ) -> Step {
        // Moved ahead of `devicectl`, which still names the panel left
        // behind: wait for it to catch up, and move back only if it never
        // does, which is a misread orientation rather than a swap.
        if movedEarlyTo == bound, case let .panel(screenID) = reading {
            // Agreed: the move is confirmed, however many reads that took.
            guard screenID != bound else { return .stop }
            if reads < earlyMoveReads { return .wait(nanoseconds: retryIntervalNanoseconds) }
            // One move back; if it fails, the content search takes over, as
            // after any rebind that keeps failing.
            return reads == earlyMoveReads ? .rebind(screenID: screenID) : .searchByContent
        }
        if movedEarlyTo == bound, reading == .undecided {
            // No answer yet either way: wait as long as for a lagging one.
            return reads < earlyMoveReads ? .wait(nanoseconds: retryIntervalNanoseconds) : .searchByContent
        }
        // Only a rebind that failed on the last read gets here.
        guard reads <= maxReads else { return .searchByContent }
        switch reading {
        case .unavailable:
            return .searchByContent

        case let .panel(screenID) where screenID != bound:
            return .rebind(screenID: screenID)

        case .panel:
            // The bound panel is the lit one: no swap, unless iOS hasn't
            // decided yet.
            return reads < maxReads ? .wait(nanoseconds: retryIntervalNanoseconds) : .stop

        case .undecided:
            return reads < maxReads ? .wait(nanoseconds: retryIntervalNanoseconds) : .searchByContent
        }
    }
}
