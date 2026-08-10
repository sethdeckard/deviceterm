// SPDX-License-Identifier: GPL-3.0-or-later
//
// HeadlessAdvisory: presenter for the Simulator.app coexistence
// modal. Reads gates from `HeadlessAdvisoryViewModel.shouldPresent`,
// builds the NSAlert with a "Don't show again" checkbox, runs it
// modally, and reports the dismiss result back to the VM so a
// future launch can skip the prompt.
//
// `xcrun simctl boot` does not launch Simulator.app; sims booted
// while Simulator.app is closed run headless. The advisory exists
// because if Apple's app is *already* running for unrelated work,
// it observes the CoreSimulator boot event and attaches a window
// to the new sim, producing a dual-display. There is no public
// per-boot suppression on macOS 26, so the user owns the choice:
// the advisory describes the condition and points at Quit
// Simulator.app as the remedy.
//
// Triggered from `SimulatorPaneViewController.viewDidLoad` after
// the pane finishes layout. The VM's per-launch + persistent
// latches make repeat invocations cheap no-ops.

import AppKit
import Foundation

@MainActor
enum HeadlessAdvisory {
    /// Default entry point: use the shared VM so all sim attaches
    /// share the per-launch latch.
    static func presentIfNeeded() {
        presentIfNeeded(viewModel: HeadlessAdvisoryViewModel.shared)
    }

    /// Show the modal if the VM says we should. Test target uses
    /// this overload to inject a fake VM.
    static func presentIfNeeded(viewModel: HeadlessAdvisoryViewModel) {
        guard viewModel.shouldPresent else { return }
        viewModel.markPresented()

        let alert = NSAlert()
        alert.messageText = "Apple's Simulator.app is running."
        alert.informativeText = """
            Sims you boot from DeviceTerm will appear in both DeviceTerm and \
            Apple's Simulator.app. To keep DeviceTerm-booted sims headless, \
            quit Simulator.app.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        let suppress = NSButton(
            checkboxWithTitle: "Don't show again",
            target: nil,
            action: nil
        )
        // Stack mirrors `SuppressionAccessory` in CloseDecisions.
        // NSAlert sizes its panel from the accessory's frame, so the
        // stack carries its intrinsic size.
        let stack = NSStackView(views: [suppress])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack

        alert.runModal()
        viewModel.recordDismiss(suppressForever: suppress.state == .on)
    }
}
