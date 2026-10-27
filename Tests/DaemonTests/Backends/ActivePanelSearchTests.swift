// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Testing

private let retry = ActivePanelSearch.Step.wait(nanoseconds: ActivePanelSearch.retryIntervalNanoseconds)
private let last = ActivePanelSearch.maxReads

@Test("active panel search", arguments: [
    // Another panel lit: move there at once, on any read up to the last.
    (1, DeviceCtlDisplays.ActivePanel.panel(3), UInt32(1), ActivePanelSearch.Step.rebind(screenID: 3)),
    (last, .panel(1), 3, .rebind(screenID: 1)),
    // The bound panel still lit, or no single panel lit: iOS may not have
    // decided yet, so read again until the last read.
    (1, .panel(1), 1, retry),
    (1, .undecided, 1, retry),
    (last - 1, .panel(3), 3, retry),
    // The bound panel lit on the last read: no swap.
    (last, .panel(3), 3, .stop),
    // Still no answer on the last read: the transition may be slow, so the
    // content search keeps following it.
    (last, .undecided, 3, .searchByContent),
    // A failed read hands over to the content search.
    (1, .unavailable, 1, .searchByContent),
    // A rebind that failed on the last read hands over too, rather than
    // ending the search or looping on it.
    (last + 1, .panel(3), 1, .searchByContent),
    (last + 1, .unavailable, 1, .searchByContent)
])
func pacesTheActivePanelSearch(
    reads: Int,
    reading: DeviceCtlDisplays.ActivePanel,
    bound: UInt32,
    expected: ActivePanelSearch.Step
) {
    #expect(ActivePanelSearch.next(afterReads: reads, reading: reading, bound: bound) == expected)
}

private let early = ActivePanelSearch.earlyMoveReads

/// Moved to the inner panel (3) on iOS's orientation change, ahead of
/// `devicectl`, which goes on naming the cover (1) for a while.
@Test("a move ahead of devicectl", arguments: [
    // Still naming the panel left behind: wait for it to catch up, well past
    // the reads a search would usually give up after.
    (1, DeviceCtlDisplays.ActivePanel.panel(1), retry),
    (early - 1, .panel(1), retry),
    // Never catching up: a misread orientation, so move back, once. A move
    // back that fails hands over to the content search.
    (early, .panel(1), .rebind(screenID: 1)),
    (early + 1, .panel(1), .searchByContent),
    // Agreeing, however many reads it took: the move stands.
    (2, .panel(3), .stop),
    (early - 1, .panel(3), .stop),
    // Undecided: no answer either way, so wait as long, then fall back.
    (ActivePanelSearch.maxReads + 1, .undecided, retry),
    (early, .undecided, .searchByContent),
    // A failed read: the usual search.
    (1, .unavailable, .searchByContent)
])
func waitsForDeviceCtlAfterAnEarlyMove(
    reads: Int,
    reading: DeviceCtlDisplays.ActivePanel,
    expected: ActivePanelSearch.Step
) {
    #expect(ActivePanelSearch.next(afterReads: reads, reading: reading, bound: 3, movedEarlyTo: 3) == expected)
}

@Test("an early move only counts for the panel it moved to")
func anEarlyMoveElsewhereChangesNothing() {
    // Bound back on the cover since: devicectl naming the inner panel is a
    // swap like any other.
    #expect(ActivePanelSearch.next(afterReads: 1, reading: .panel(3), bound: 1, movedEarlyTo: 3)
        == .rebind(screenID: 3))
}

@Test("only a hinge move and an orientation unlike the one shown mean iOS moved panels", arguments: [
    // (held, shown, hinge moved seconds ago, moved panels)
    (Orientation.landscapeRight, Orientation?.some(.portrait), Double?.some(0.5), true),
    (.landscapeRight, .portrait, ActivePanelSearch.hingeMoveWindowSeconds, true),
    // Same orientation: nothing moved.
    (.portrait, .portrait, 0.5, false),
    // No hinge move, or one long past: a rotation, not a fold.
    (.landscapeRight, .portrait, nil, false),
    (.landscapeRight, .portrait, ActivePanelSearch.hingeMoveWindowSeconds + 1, false),
    // Nothing shown yet: nothing to compare with.
    (.portrait, nil, 0.5, false)
])
func orientationMovesPanelOnlyAfterAHingeMove(
    held: Orientation,
    shown: Orientation?,
    hingeMovedSecondsAgo: Double?,
    moved: Bool
) {
    #expect(
        ActivePanelSearch.orientationMovesPanel(held: held, shown: shown, hingeMovedSecondsAgo: hingeMovedSecondsAgo)
            == moved
    )
}
