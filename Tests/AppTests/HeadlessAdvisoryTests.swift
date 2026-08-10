// SPDX-License-Identifier: GPL-3.0-or-later
//
// HeadlessAdvisoryTests: exercise the VM gates behind the
// Simulator.app coexistence advisory. The presenter's NSAlert
// runModal path needs an AppKit display session, so the tests
// drive the VM directly via injected closures + assert on the
// `shouldPresent` decision, `markPresented` latch, and the
// suppression write-back through `recordDismiss`.

@testable import App
import DaemonProtocol
import Testing

@MainActor
struct HeadlessAdvisoryTests {
    @Test
    func presentsWhenRunningAndNotSuppressedAndNotShownYet() {
        // Default case: the modal should fire.
        let viewModel = HeadlessAdvisoryViewModel(
            isSuppressed: { false },
            recordSuppressed: { _ in },
            isSimulatorAppRunning: { true }
        )
        #expect(viewModel.shouldPresent)
    }

    @Test
    func suppressedAfterPersistentFlag() {
        // The user previously checked "Don't show again", so the flag is
        // sticky across launches.
        let viewModel = HeadlessAdvisoryViewModel(
            isSuppressed: { true },
            recordSuppressed: { _ in },
            isSimulatorAppRunning: { true }
        )
        #expect(!viewModel.shouldPresent)
    }

    @Test
    func suppressedWhenSimulatorAppNotRunning() {
        // No dual-display condition, so the advisory is irrelevant:
        // skip it even if nothing else gates it.
        let viewModel = HeadlessAdvisoryViewModel(
            isSuppressed: { false },
            recordSuppressed: { _ in },
            isSimulatorAppRunning: { false }
        )
        #expect(!viewModel.shouldPresent)
    }

    @Test
    func markPresentedLatchesOff() {
        // After `markPresented`, subsequent calls in the same launch
        // short-circuit, which protects against a burst of attach events
        // re-firing the modal.
        let viewModel = HeadlessAdvisoryViewModel(
            isSuppressed: { false },
            recordSuppressed: { _ in },
            isSimulatorAppRunning: { true }
        )
        #expect(viewModel.shouldPresent)
        viewModel.markPresented()
        #expect(!viewModel.shouldPresent)
    }

    @Test
    func recordDismissWritesSuppressionFlagWhenChecked() {
        // The user ticked "Don't show again", so the VM persists the flag
        // via the injected writer (production writes the config file).
        var captured: Bool?
        let viewModel = HeadlessAdvisoryViewModel(
            isSuppressed: { false },
            recordSuppressed: { captured = $0 },
            isSimulatorAppRunning: { true }
        )
        viewModel.recordDismiss(suppressForever: true)
        #expect(captured == true)
    }

    @Test
    func recordDismissSkipsWriteWhenUnchecked() {
        // User dismissed without checking the box, so no persistent
        // write; the next launch should re-prompt.
        var captured: Bool?
        let viewModel = HeadlessAdvisoryViewModel(
            isSuppressed: { false },
            recordSuppressed: { captured = $0 },
            isSimulatorAppRunning: { true }
        )
        viewModel.recordDismiss(suppressForever: false)
        #expect(captured == nil)
    }

    @Test
    func shouldPresentSkipsRunningQueryWhenLatched() {
        // Performance latch: if the cheap gates short-circuit, the
        // NSRunningApplication scan never runs. Verify by counting
        // calls to the running-reader.
        var runningCalls = 0
        let viewModel = HeadlessAdvisoryViewModel(
            isSuppressed: { true },
            recordSuppressed: { _ in },
            isSimulatorAppRunning: {
                runningCalls += 1
                return true
            }
        )
        _ = viewModel.shouldPresent
        #expect(runningCalls == 0)
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
