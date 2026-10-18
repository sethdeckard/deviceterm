// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
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
