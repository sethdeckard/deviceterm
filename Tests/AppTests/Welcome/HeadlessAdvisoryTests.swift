// SPDX-License-Identifier: GPL-3.0-or-later
//
// HeadlessAdvisoryTests: exercise the gates behind the Simulator.app
// coexistence advisory. The presenter's NSAlert runModal path needs an
// AppKit display session, so the tests drive `HeadlessAdvisoryDecision`
// and the VM directly via injected closures, asserting on the decision,
// the `markPresented` latch, and the suppression write-back through
// `recordDismiss`.
//
// The hazard table matters as much as the skip gates: naming a route
// the user already closed is what turns the alert from a warning into
// noise.

@testable import App
import DaemonProtocol
import Testing

@MainActor
struct HeadlessAdvisoryTests {
    /// Neither preference set: the observed Simulator.app default,
    /// where both routes shut a booted sim down.
    private static let hazardous = SimulatorDetachPolicy(
        detachOnWindowClose: false,
        detachOnAppQuit: false
    )

    private static let safe = SimulatorDetachPolicy(
        detachOnWindowClose: true,
        detachOnAppQuit: true
    )

    private static func makeViewModel(
        isSuppressed: @escaping @MainActor () -> Bool = { false },
        recordSuppressed: @escaping @MainActor (Bool) -> Void = { _ in },
        isSimulatorAppRunning: @escaping @MainActor () -> Bool = { true },
        welcomeShownThisLaunch: @escaping @MainActor () -> Bool = { false },
        detachPolicy: @escaping @MainActor () -> SimulatorDetachPolicy = { hazardous }
    ) -> HeadlessAdvisoryViewModel {
        HeadlessAdvisoryViewModel(
            isSuppressed: isSuppressed,
            recordSuppressed: recordSuppressed,
            isSimulatorAppRunning: isSimulatorAppRunning,
            welcomeShownThisLaunch: welcomeShownThisLaunch,
            detachPolicy: detachPolicy
        )
    }

    @Test
    func warnsWhenRunningAndNotSuppressedAndNotShownYet() {
        // Default case: Simulator.app is up and neither detach
        // preference is set, so both routes can kill the sim.
        let viewModel = Self.makeViewModel()
        #expect(viewModel.decision == .warn(hazard: .both))
    }

    @Test
    func suppressedAfterPersistentFlag() {
        // The user previously checked "Don't show again", so the flag is
        // sticky across launches.
        let viewModel = Self.makeViewModel(isSuppressed: { true })
        #expect(viewModel.decision == .skip)
    }

    @Test
    func suppressedWhenSimulatorAppNotRunning() {
        // No dual-display condition, so the advisory is irrelevant.
        let viewModel = Self.makeViewModel(isSimulatorAppRunning: { false })
        #expect(viewModel.decision == .skip)
    }

    @Test
    func suppressedWhenWelcomeAlreadyRanThisLaunch() {
        // The coexistence welcome already explained this in this
        // session; stacking a modal on top gets both dismissed unread.
        let viewModel = Self.makeViewModel(welcomeShownThisLaunch: { true })
        #expect(viewModel.decision == .skip)
    }

    @Test
    func suppressedWhenSimulatorAlreadyDetaches() {
        // Both preferences set, so Simulator.app going away no longer
        // takes the sim with it and there is no hazard left to name.
        let viewModel = Self.makeViewModel(detachPolicy: { Self.safe })
        #expect(viewModel.decision == .skip)
    }

    @Test("hazard named from the live route", arguments: [
        (false, false, SimulatorShutdownHazard.both),
        (true, false, SimulatorShutdownHazard.windowClose),
        (false, true, SimulatorShutdownHazard.appQuit)
    ])
    func namesOnlyTheLiveHazard(
        detachOnAppQuit: Bool,
        detachOnWindowClose: Bool,
        expected: SimulatorShutdownHazard
    ) {
        // Each preference removes exactly its own arm; warning about a
        // route the user already closed would be misinformation.
        let policy = SimulatorDetachPolicy(
            detachOnWindowClose: detachOnWindowClose,
            detachOnAppQuit: detachOnAppQuit
        )
        #expect(HeadlessAdvisoryDecision.hazard(for: policy) == expected)
    }

    @Test
    func noHazardWhenBothPreferencesSet() {
        #expect(HeadlessAdvisoryDecision.hazard(for: Self.safe) == nil)
    }

    @Test
    func markPresentedLatchesOff() {
        // After `markPresented`, subsequent calls in the same launch
        // short-circuit, which protects against a burst of attach events
        // re-firing the modal.
        let viewModel = Self.makeViewModel()
        #expect(viewModel.decision == .warn(hazard: .both))
        viewModel.markPresented()
        #expect(viewModel.decision == .skip)
    }

    @Test
    func recordDismissWritesSuppressionFlagWhenChecked() {
        // The user ticked "Don't show again", so the VM persists the flag
        // via the injected writer (production writes the config file).
        var captured: Bool?
        let viewModel = Self.makeViewModel(recordSuppressed: { captured = $0 })
        viewModel.recordDismiss(suppressForever: true)
        #expect(captured == true)
    }

    @Test
    func recordDismissSkipsWriteWhenUnchecked() {
        // User dismissed without checking the box, so no persistent
        // write; the next launch should re-prompt.
        var captured: Bool?
        let viewModel = Self.makeViewModel(recordSuppressed: { captured = $0 })
        viewModel.recordDismiss(suppressForever: false)
        #expect(captured == nil)
    }

    @Test
    func decisionSkipsExpensiveQueriesWhenLatched() {
        // Performance latch: when the cheap gates short-circuit, neither
        // the NSRunningApplication scan nor the cross-process
        // preferences read runs. Verify by counting calls.
        var runningCalls = 0
        var policyCalls = 0
        let viewModel = Self.makeViewModel(
            isSuppressed: { true },
            isSimulatorAppRunning: {
                runningCalls += 1
                return true
            },
            detachPolicy: {
                policyCalls += 1
                return Self.hazardous
            }
        )
        _ = viewModel.decision
        #expect(runningCalls == 0)
        #expect(policyCalls == 0)
    }

    @Test
    func decisionSkipsPreferencesReadWhenSimulatorAppAbsent() {
        // Reading another app's domain crosses to `cfprefsd`, so it
        // stays behind the cheaper running-application check.
        var policyCalls = 0
        let viewModel = Self.makeViewModel(
            isSimulatorAppRunning: { false },
            detachPolicy: {
                policyCalls += 1
                return Self.hazardous
            }
        )
        _ = viewModel.decision
        #expect(policyCalls == 0)
    }

    @Test
    func informativeTextNamesEachRoute() {
        // Copy has to track the hazard. The appQuit case must mention
        // the last-window gesture, because closing Simulator.app's last
        // device window quits the app rather than just closing a window.
        let both = HeadlessAdvisory.informativeText(for: .both)
        #expect(both.contains("quitting Simulator.app"))
        #expect(both.contains("device window"))

        let quit = HeadlessAdvisory.informativeText(for: .appQuit)
        #expect(quit.contains("last device window"))

        let window = HeadlessAdvisory.informativeText(for: .windowClose)
        #expect(window.contains("other device windows stay open"))
    }

    @Test
    func suppressKeyIsStable() {
        // The config-file key is part of the user-facing contract.
        // Renaming silently re-prompts everyone who opted out, so pin
        // it, and assert it's a recognized config key so the
        // canonical defaults table and dump-config stay in sync.
        #expect(HeadlessAdvisoryViewModel.suppressKey == "simulator-app-advisory")
        #expect(DeviceTermConfigDefaults.isKnown(HeadlessAdvisoryViewModel.suppressKey))
    }
}
