// SPDX-License-Identifier: GPL-3.0-or-later
//
// PendingPaneReducer: the placeholder pane's phase machine as a pure
// function. No view, no daemon: the two transitions a pending pane can
// take (its attach threw, or the user retried) are pinned here.

@testable import App
import Testing

struct PendingPaneReducerTests {
    @Test
    func attachFailedMovesToFailedWithMessage() {
        #expect(
            PendingPaneReducer.reduce(.attaching, .attachFailed("device is locked"))
                == .failed("device is locked")
        )
    }

    @Test
    func retriedReturnsToAttaching() {
        #expect(PendingPaneReducer.reduce(.failed("boom"), .retried) == .attaching)
    }

    @Test
    func attachFailedOverwritesAnEarlierMessage() {
        #expect(
            PendingPaneReducer.reduce(.failed("old"), .attachFailed("new"))
                == .failed("new")
        )
    }
}
