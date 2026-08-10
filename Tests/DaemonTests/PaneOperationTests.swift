// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// `PaneOperation.label` is the text clients read in a pane error, so the
// labels are pinned here rather than left to whatever the enum happens to
// spell. Comparing errors by case would prove the right verb was selected
// while saying nothing about what the user is shown, so these assert the
// strings, and the two boundary tests below assert they survive the
// formatting that carries them out of the daemon.

@Test("non-button operation labels are fixed", arguments: [
    (PaneOperation.tap, "tap"),
    (.touch, "touch"),
    (.edgeTouch, "edgeTouch"),
    (.swipe, "swipe"),
    (.edgeSwipe, "edgeSwipe"),
    (.longPress, "longPress"),
    (.keyDown, "keyDown"),
    (.keyUp, "keyUp"),
    (.pinch, "pinch"),
    (.multitouch, "multitouch"),
    (.text, "text"),
    (.rotate, "rotate"),
    (.crown, "crown"),
    (.axTree, "ax.tree"),
    (.axPoint, "ax.point"),
    (.axSweep, "ax.sweep"),
    (.axAcquire, "ax.acquire"),
    (.locationSet, "location.set"),
    (.locationAcquire, "location.acquire"),
    (.locationEnumerate, "location.enumerate")
])
func operationLabelIsFixed(operation: PaneOperation, expected: String) {
    #expect(operation.label == expected)
}

@Test(
    "every hardware button gets a labelled operation",
    arguments: HardwareButton.allCases
)
func buttonOperationLabelIsFixed(button: HardwareButton) {
    // Driven off `allCases` so a new button can't slip in unlabelled.
    #expect(PaneOperation.button(button).label == "button.\(button.rawValue)")
}

@Test("the key operation follows the press direction")
func keyOperationFollowsDirection() {
    #expect(PaneOperation.key(down: true) == .keyDown)
    #expect(PaneOperation.key(down: false) == .keyUp)
}

// MARK: - Formatting boundaries

// The two places a label leaves the daemon. Both interpolate it, and a bare
// `\(operation)` would emit the *case name* (`locationSet`) instead of the
// label (`location.set`), which no test comparing cases could see.

@Test("the RPC error message carries the label, not the case name")
func mapPaneErrorCarriesTheLabel() {
    let mapped = PaneMethods.mapPaneError(
        .bridgeFailed(paneId: UUID(), operation: .locationSet, message: "devicectl exited 1")
    )
    #expect(mapped.message == "pane.location.set: devicectl exited 1")

    let unsupported = PaneMethods.mapPaneError(
        .unsupportedOperation(paneId: UUID(), operation: .crown)
    )
    #expect(unsupported.message == "operation 'crown' is not supported on this pane's device")
}

@Test("the diagnostic kind carries the label, not the case name")
func diagnosticKindCarriesTheLabel() {
    let failed = PaneError.bridgeFailed(paneId: UUID(), operation: .axSweep, message: "AX server down")
    #expect(failed.diagnosticKind == "bridge-failed:ax.sweep")

    let unsupported = PaneError.unsupportedOperation(paneId: UUID(), operation: .button(.home))
    #expect(unsupported.diagnosticKind == "unsupported-operation:button.home")
}
