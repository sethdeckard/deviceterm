// SPDX-License-Identifier: GPL-3.0-or-later
//
// A non-presenting HeadlessAdvisoryViewModel for the hermetic gate.
//
// The production readers answer from the developer's machine: whether
// Simulator.app is running, and what `~/.config/deviceterm/config` says
// about suppression. The wrong pair raises a modal NSAlert that nothing
// in a test process can dismiss, so the suite blocks until it is
// killed. Panes built by tests take this instead.
//
// A factory rather than a conformance, so it lives in an extension.

@testable import App
import Foundation

extension HeadlessAdvisoryViewModel {
    /// A machine where nothing is suppressed and Simulator.app is not
    /// running, so there is no advisory to show.
    ///
    /// Every reader is pinned, not just the one that decides the
    /// outcome: the suppression read is the earlier gate, so leaving it
    /// on the default would open the user's config file on every pane a
    /// test builds. `recordDismiss` stays callable either way; the
    /// no-op writer is what keeps it from rewriting that file.
    @MainActor
    static func silent() -> HeadlessAdvisoryViewModel {
        HeadlessAdvisoryViewModel(
            isSuppressed: { false },
            recordSuppressed: { _ in },
            isSimulatorAppRunning: { false }
        )
    }
}
