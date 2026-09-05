// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation

/// A non-presenting `HeadlessAdvisoryViewModel` for the hermetic gate.
///
/// The production readers answer from the developer's machine: whether
/// Simulator.app is running, and what `~/.config/deviceterm/config` says
/// about suppression. The wrong pair raises a modal NSAlert that nothing
/// in a test process can dismiss, so the suite blocks until it is
/// killed. Panes built by tests take this instead.
///
/// A factory rather than a conformance, so it lives in an extension.
extension HeadlessAdvisoryViewModel {
    /// A machine where nothing is suppressed and Simulator.app is not
    /// running, so there is no advisory to show.
    ///
    /// Every reader is pinned, not just the one that decides the
    /// outcome: the suppression read is an earlier gate, so leaving it on
    /// the default would open the user's config file on every pane a test
    /// builds, and the welcome read is eager, so it would reach the
    /// process-wide `WelcomeCoordinator`. Pinning the detach policy
    /// matters less, since the false running-state gate sits ahead of it,
    /// but a gate-order change shouldn't be able to turn a test into a
    /// `cfprefsd` round trip. `recordDismiss` stays callable either way;
    /// the no-op writer is what keeps it from rewriting that file.
    ///
    /// The latch is a fresh instance rather than the shared one, so a
    /// pane built by one test can't silence an advisory another test is
    /// asserting on.
    @MainActor
    static func silent() -> HeadlessAdvisoryViewModel {
        HeadlessAdvisoryViewModel(
            latch: CoexistenceAdvisoryLatch(),
            isSuppressed: { false },
            recordSuppressed: { _ in },
            isSimulatorAppRunning: { false },
            welcomeShownThisLaunch: { false },
            detachPolicy: { SimulatorDetachPolicy(detachOnWindowClose: true, detachOnAppQuit: true) },
            deviceHubWillWarn: { _ in false }
        )
    }
}
