// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import ServiceManagement
import Testing

// DaemonStatusSheet wiring: the disabled-helper sheet exposes a
// CTA that deep-links to System Settings → Login Items &
// Extensions. The test captures URLs through an injected
// `DaemonSheetOpener` so the sheet's "Open" action runs without
// actually launching System Settings.

@MainActor
private final class RecordingOpener: DaemonSheetOpener, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []

    nonisolated func open(_ url: URL) {
        Task { @MainActor in
            self.openedURLs.append(url)
        }
    }
}

@Test
@MainActor
func loginItemsURLPointsToTheRightSettingsPane() {
    let expected = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )
    #expect(DaemonStatusSheet.loginItemsURL == expected)
}

@Test
@MainActor
func dismissCallbackFiresWhenInvoked() {
    var dismissed = false
    let sheet = DaemonStatusSheet(
        status: .notRegistered,
        onDismiss: { dismissed = true },
        opener: RecordingOpener()
    )
    sheet.onDismiss()
    #expect(dismissed)
}

@Test
@MainActor
func sheetConstructsForEveryStatusBranch() {
    // Pure construction guard: every status branch resolves
    // without crashing. SwiftUI body evaluation happens through
    // host integration; here we just exercise the constructors.
    let opener = RecordingOpener()
    let statuses: [SMAppService.Status] = [
        .enabled,
        .requiresApproval,
        .notRegistered,
        .notFound
    ]
    for status in statuses {
        let sheet = DaemonStatusSheet(
            status: status,
            onDismiss: {},
            opener: opener
        )
        _ = sheet.body
    }
}
