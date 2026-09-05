// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// Exercise the gates behind the Simulator.app
/// coexistence advisory. The presenter's NSAlert runModal path needs an
/// AppKit display session, so the tests drive `HeadlessAdvisoryDecision`
/// and the VM directly via injected closures, asserting on the decision,
/// the `markPresented` latch, and the suppression write-back through
/// `recordDismiss`.
///
/// The hazard table matters as much as the skip gates: naming a route
/// the user already closed is what turns the alert from a warning into
/// noise.
@MainActor
struct HeadlessAdvisoryTests {
    /// A boolean a `@Sendable` closure can keep reading as it changes.
    @MainActor
    final class MutableFlag {
        var value: Bool

        init(_ value: Bool) {
            self.value = value
        }
    }

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

    /// A fresh latch per view model, never `.shared`. The latch is
    /// process-global in production, so a test that reaches for the
    /// shared one leaves every later test in the suite latched off and
    /// passing for the wrong reason.
    private static func makeViewModel(
        latch: CoexistenceAdvisoryLatch = CoexistenceAdvisoryLatch(),
        isSuppressed: @escaping @MainActor () -> Bool = { false },
        recordSuppressed: @escaping @MainActor (Bool) -> Void = { _ in },
        isSimulatorAppRunning: @escaping @MainActor () -> Bool = { true },
        welcomeShownThisLaunch: @escaping @MainActor () -> Bool = { false },
        detachPolicy: @escaping @MainActor () -> SimulatorDetachPolicy = { hazardous },
        deviceHubWillWarn: @escaping @MainActor (Bool) -> Bool = { _ in false }
    ) -> HeadlessAdvisoryViewModel {
        HeadlessAdvisoryViewModel(
            latch: latch,
            isSuppressed: isSuppressed,
            recordSuppressed: recordSuppressed,
            isSimulatorAppRunning: isSimulatorAppRunning,
            welcomeShownThisLaunch: welcomeShownThisLaunch,
            detachPolicy: detachPolicy,
            deviceHubWillWarn: deviceHubWillWarn
        )
    }

    @Test
    func warnsWhenRunningAndNotSuppressedAndNotShownYet() {
        // Default case: Simulator.app is up and neither detach
        // preference is set, so both routes can kill the sim.
        let viewModel = Self.makeViewModel()
        #expect(viewModel.decision(isPhysicalDevice: false) == .warn(hazard: .both))
    }

    @Test
    func suppressedAfterPersistentFlag() {
        // The user previously checked "Don't show again", so the flag is
        // sticky across launches.
        let viewModel = Self.makeViewModel(isSuppressed: { true })
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func suppressedWhenSimulatorAppNotRunning() {
        // No dual-display condition, so the advisory is irrelevant.
        let viewModel = Self.makeViewModel(isSimulatorAppRunning: { false })
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func suppressedWhenWelcomeAlreadyRanThisLaunch() {
        // The coexistence welcome already explained this in this
        // session; stacking a modal on top gets both dismissed unread.
        let viewModel = Self.makeViewModel(welcomeShownThisLaunch: { true })
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func skipsPhysicalDevicePanes() {
        // Simulator.app attaches to sims. A mirrored phone can't be
        // opened in it however it's configured, so warning that "this sim
        // is now open in both DeviceTerm and Apple's Simulator.app" is
        // describing something that didn't happen.
        let viewModel = Self.makeViewModel()
        #expect(viewModel.decision(isPhysicalDevice: true) == .skip)
        #expect(viewModel.decision(isPhysicalDevice: false) == .warn(hazard: .both))
    }

    @Test
    func devicePaneSkipsEveryExpensiveQuery() {
        // The pane-kind gate is first, ahead of the latches, because it
        // is a parameter rather than a read. A device pane must not scan
        // running applications or open Simulator.app's preferences.
        var runningCalls = 0
        var policyCalls = 0
        let viewModel = Self.makeViewModel(
            isSimulatorAppRunning: {
                runningCalls += 1
                return true
            },
            detachPolicy: {
                policyCalls += 1
                return Self.hazardous
            }
        )
        _ = viewModel.decision(isPhysicalDevice: true)
        #expect(runningCalls == 0)
        #expect(policyCalls == 0)
    }

    @Test
    func yieldsToDeviceHubWhenBothWouldFire() {
        // Only one coexistence warning appears per launch, so when both
        // apply one has to lose. Device Hub's hazard reaches further: its
        // quit shuts down every booted Simulator, including ones it never
        // opened, where Simulator.app's reach is bounded by the device
        // windows it attached.
        let yielding = Self.makeViewModel(deviceHubWillWarn: { _ in true })
        #expect(yielding.decision(isPhysicalDevice: false) == .skip)

        let firing = Self.makeViewModel(deviceHubWillWarn: { _ in false })
        #expect(firing.decision(isPhysicalDevice: false) == .warn(hazard: .both))
    }

    @Test
    func theYieldIsAGateNotACallOrder() {
        // Regression: sequencing the two presenters would decide this by
        // which statement ran first, and starve the loser in every
        // launch rather than deferring it. Deciding it here means the
        // Simulator.app advisory becomes reachable the moment Device
        // Hub's stops applying, with no ordering change anywhere.
        // A reference box, because the reader is `@Sendable` and a
        // captured `var` can't be mutated after capture. The point of
        // the test is that the answer is read per call rather than
        // captured once, so two view models wouldn't show it.
        let applies = MutableFlag(true)
        let viewModel = Self.makeViewModel(deviceHubWillWarn: { _ in applies.value })

        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
        applies.value = false
        #expect(viewModel.decision(isPhysicalDevice: false) == .warn(hazard: .both))
    }

    @Test
    func deviceHubIsNotConsultedUntilThisAdvisoryWouldFire() {
        // The check costs a second running-application scan, so it sits
        // last: an advisory that is suppressed, or has no hazard left,
        // never asks.
        var calls = 0
        let viewModel = Self.makeViewModel(
            isSuppressed: { true },
            deviceHubWillWarn: { _ in
                calls += 1
                return true
            }
        )
        _ = viewModel.decision(isPhysicalDevice: false)
        #expect(calls == 0)
    }

    @Test
    func aSharedLatchSilencesTheOtherAdvisory() {
        // One coexistence warning per launch, whichever fires first. With
        // both Apple apps running, a single sim attach satisfies both
        // advisories, and two stacked modals get both dismissed unread.
        let latch = CoexistenceAdvisoryLatch()
        let simulator = Self.makeViewModel(latch: latch)
        let deviceHub = DeviceHubAdvisoryViewModel(
            latch: latch,
            isSuppressed: { false },
            recordSuppressed: { _ in },
            isDeviceHubRunning: { true },
            welcomeShownThisLaunch: { false }
        )

        #expect(simulator.decision(isPhysicalDevice: false) == .warn(hazard: .both))
        simulator.markPresented()
        #expect(deviceHub.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func suppressedWhenSimulatorAlreadyDetaches() {
        // Both preferences set, so Simulator.app going away no longer
        // takes the sim with it and there is no hazard left to name.
        let viewModel = Self.makeViewModel(detachPolicy: { Self.safe })
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
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
        #expect(viewModel.decision(isPhysicalDevice: false) == .warn(hazard: .both))
        viewModel.markPresented()
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
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
    func decisionSkipsExpensiveQueriesWhenSuppressed() {
        // Persistent suppression short-circuits before both the
        // NSRunningApplication scan and the cross-process preferences
        // read. Verify by counting calls.
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
        _ = viewModel.decision(isPhysicalDevice: false)
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
        _ = viewModel.decision(isPhysicalDevice: false)
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
