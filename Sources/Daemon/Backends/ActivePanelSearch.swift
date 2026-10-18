// SPDX-License-Identifier: GPL-3.0-or-later

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
    static let litRefreshAttempts = 30

    /// The next step after `reads` reads, the last of which said `reading`,
    /// while the display is bound to `bound`.
    static func next(
        afterReads reads: Int,
        reading: DeviceCtlDisplays.ActivePanel,
        bound: UInt32
    ) -> Step {
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
