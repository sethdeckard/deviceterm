// SPDX-License-Identifier: GPL-3.0-or-later
//
// AxElementSummaryTests: pin the chrome-side decoder for
// `pane.ax.point`. The daemon returns `{"element": {...}}` for a hit
// and either `{"element": null}` or a missing `element` for a miss;
// the chrome's AX inspector inline label calls `parse` so a small
// fixture set covers the field-priority + empty cases without spinning
// up a daemon.

@testable import App
import Foundation
import Testing

@MainActor
struct AxElementSummaryTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test
    func parsesRoleLabelIdentifierJoinedWithMiddot() {
        let summary = AxElementSummary.parse(
            data(
                """
                {"element":{"role":"Button","label":"Sign in",\
                "identifier":"signInButton"}}
                """
            )
        )
        #expect(summary == "Button · Sign in · signInButton")
    }

    @Test
    func parsesOnlyAvailableFields() {
        // Common case: a button with a label but no identifier.
        let summary = AxElementSummary.parse(
            data(#"{"element":{"role":"Button","label":"Sign in"}}"#)
        )
        #expect(summary == "Button · Sign in")
    }

    @Test
    func returnsNilWhenElementIsAbsent() {
        // Cursor over chrome / off-screen: the daemon emits a payload
        // without an `element` key. parse returns nil so the chrome
        // clears its label.
        #expect(AxElementSummary.parse(data("{}")) == nil)
    }

    @Test
    func returnsNilWhenEveryFieldIsEmpty() {
        // Hit with no inspectable fields: same outcome as a miss
        // from the user's perspective. Don't render the `·` separators
        // around empties.
        let summary = AxElementSummary.parse(
            data(#"{"element":{"role":"","label":"   ","identifier":""}}"#)
        )
        #expect(summary == nil)
    }

    @Test
    func returnsNilOnMalformedJSON() {
        // Bad daemon reply / corrupted wire payload. Don't crash; the
        // chrome simply stays empty until the next hit.
        #expect(AxElementSummary.parse(data("not json")) == nil)
    }
}
