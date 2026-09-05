// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// Exercise the gates behind the Device Hub coexistence advisory. The
/// presenter's NSAlert runModal path needs an AppKit display session, so
/// these drive `DeviceHubAdvisoryDecision` and the VM directly via
/// injected closures, asserting on the decision, the shared latch, and the
/// suppression write-back through `recordDismiss`.
///
/// Simpler than the Simulator.app table in one way and harder in another.
/// There is no preference to read, so no "configured away" case. But the
/// hazard depends on the pane, and the copy for the two is not
/// interchangeable: a sim reader needs the ⌥ escape, a device reader needs
/// to know the mirror survives.
@MainActor
struct DeviceHubAdvisoryTests {
    /// A fresh latch per view model, never `.shared`. The latch is
    /// process-global in production, so a test that reaches for the
    /// shared one leaves every later test in the suite latched off and
    /// passing for the wrong reason.
    private static func makeViewModel(
        latch: CoexistenceAdvisoryLatch = CoexistenceAdvisoryLatch(),
        isSuppressed: @escaping @MainActor () -> Bool = { false },
        recordSuppressed: @escaping @MainActor (Bool) -> Void = { _ in },
        isDeviceHubRunning: @escaping @MainActor () -> Bool = { true },
        welcomeShownThisLaunch: @escaping @MainActor () -> Bool = { false }
    ) -> DeviceHubAdvisoryViewModel {
        DeviceHubAdvisoryViewModel(
            latch: latch,
            isSuppressed: isSuppressed,
            recordSuppressed: recordSuppressed,
            isDeviceHubRunning: isDeviceHubRunning,
            welcomeShownThisLaunch: welcomeShownThisLaunch
        )
    }

    @Test("each pane kind names its own hazard", arguments: [
        (false, DeviceHubHazard.simulatorShutdownOnQuit),
        (true, DeviceHubHazard.deviceControlContention)
    ])
    func warnsWithTheHazardForThePaneKind(
        isPhysicalDevice: Bool,
        expected: DeviceHubHazard
    ) {
        let viewModel = Self.makeViewModel()
        #expect(viewModel.decision(isPhysicalDevice: isPhysicalDevice) == .warn(hazard: expected))
    }

    @Test
    func bothPaneKindsHaveAHazard() {
        // Unlike Simulator.app, neither hazard can be configured away, so
        // the mapping is total and `hazard` returns no optional.
        #expect(DeviceHubAdvisoryDecision.hazard(isPhysicalDevice: false) == .simulatorShutdownOnQuit)
        #expect(DeviceHubAdvisoryDecision.hazard(isPhysicalDevice: true) == .deviceControlContention)
    }

    @Test
    func suppressedAfterPersistentFlag() {
        // The user previously checked "Don't show again", so the flag is
        // sticky across launches.
        let viewModel = Self.makeViewModel(isSuppressed: { true })
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func suppressedWhenDeviceHubNotRunning() {
        // Nothing to coexist with, so the advisory is irrelevant.
        let viewModel = Self.makeViewModel(isDeviceHubRunning: { false })
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func suppressedWhenWelcomeAlreadyRanThisLaunch() {
        // A coexistence welcome already explained this in this session;
        // stacking a modal on top gets both dismissed unread.
        let viewModel = Self.makeViewModel(welcomeShownThisLaunch: { true })
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func markPresentedLatchesOff() {
        // After `markPresented`, subsequent calls in the same launch
        // short-circuit, which protects against a burst of attach events
        // re-firing the modal.
        let viewModel = Self.makeViewModel()
        #expect(viewModel.decision(isPhysicalDevice: false) == .warn(hazard: .simulatorShutdownOnQuit))
        viewModel.markPresented()
        #expect(viewModel.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func theLatchSilencesTheSimulatorAdvisoryToo() {
        // The mirror of the check in `HeadlessAdvisoryTests`: whichever
        // fires first, the other yields for the rest of the launch.
        let latch = CoexistenceAdvisoryLatch()
        let deviceHub = Self.makeViewModel(latch: latch)
        let simulator = HeadlessAdvisoryViewModel(
            latch: latch,
            isSuppressed: { false },
            recordSuppressed: { _ in },
            isSimulatorAppRunning: { true },
            welcomeShownThisLaunch: { false },
            detachPolicy: { SimulatorDetachPolicy(detachOnWindowClose: false, detachOnAppQuit: false) },
            // Isolate the latch from the priority gate: this asserts what
            // the latch does after a presentation, not which advisory
            // wins when both apply.
            deviceHubWillWarn: { _ in false }
        )

        #expect(deviceHub.decision(isPhysicalDevice: false) == .warn(hazard: .simulatorShutdownOnQuit))
        deviceHub.markPresented()
        #expect(simulator.decision(isPhysicalDevice: false) == .skip)
    }

    @Test
    func recordDismissWritesSuppressionFlagWhenChecked() {
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
    func decisionSkipsTheRunningScanWhenSuppressed() {
        // Persistent suppression short-circuits before the
        // `NSRunningApplication` scan. Verify by counting.
        var runningCalls = 0
        let viewModel = Self.makeViewModel(
            isSuppressed: { true },
            isDeviceHubRunning: {
                runningCalls += 1
                return true
            }
        )
        _ = viewModel.decision(isPhysicalDevice: false)
        #expect(runningCalls == 0)
    }

    @Test
    func informativeTextMatchesTheHazard() {
        // The two cases are not interchangeable copy. The sim case is the
        // only place the ⌥ escape appears in an alert, and has to say it
        // isn't a setting. The device case must not claim the mirror
        // breaks, because it doesn't: only control is exclusive.
        let sim = DeviceHubAdvisory.informativeText(for: .simulatorShutdownOnQuit)
        #expect(sim.contains("every booted Simulator"))
        #expect(sim.contains("⌥⌘Q"))
        #expect(sim.contains("one-time choice"))

        let device = DeviceHubAdvisory.informativeText(for: .deviceControlContention)
        #expect(device.contains("neither mirror drops"))
        #expect(device.contains("Only one of them can control it"))
        #expect(!device.contains("shuts down"))
    }

    @Test
    func suppressKeyIsStable() {
        // The config-file key is part of the user-facing contract.
        // Renaming silently re-prompts everyone who opted out, so pin
        // it, and assert it's a recognized config key so the canonical
        // defaults table and dump-config stay in sync.
        #expect(DeviceHubAdvisoryViewModel.suppressKey == "device-hub-advisory")
        #expect(DeviceTermConfigDefaults.isKnown(DeviceHubAdvisoryViewModel.suppressKey))
    }
}
