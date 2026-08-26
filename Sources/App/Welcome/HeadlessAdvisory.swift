// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Presenter for the Simulator.app coexistence
/// modal. Reads `HeadlessAdvisoryViewModel.decision` to gate the NSAlert
/// and pick its copy, builds it with a "Don't show again" checkbox, runs
/// it modally, and reports the dismiss result back to the VM so a
/// future launch can skip the prompt.
///
/// `xcrun simctl boot` does not launch Simulator.app; sims booted
/// while Simulator.app is closed run headless. The advisory exists
/// because if Apple's app is *already* running for unrelated work,
/// it observes the CoreSimulator boot event and attaches a window
/// to the new sim, producing a dual-display. No preference stops that
/// attach, so the remedy is ordering: quit Simulator.app before booting.
///
/// The alert's job is the hazard, not the explanation. It names what can
/// still take this sim down from outside and offers Learn More…; the
/// coexistence welcome carries the whole model. The skip conditions are:
/// already shown this launch, suppressed by the user, Simulator.app not
/// running, a welcome already ran this session (stacking a modal on an
/// explanation the user is still reading gets both dismissed unread), or
/// Simulator.app is already configured to detach on both routes, leaving
/// no hazard to name.
///
/// Triggered from `SimulatorPaneViewController.viewDidLoad` after
/// the pane finishes layout. The VM's per-launch + persistent
/// latches make repeat invocations cheap no-ops.
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
        guard case let .warn(hazard) = viewModel.decision else { return }
        viewModel.markPresented()

        let alert = NSAlert()
        alert.messageText = "Apple's Simulator.app is running."
        alert.informativeText = informativeText(for: hazard)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Learn More…")

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

        let response = alert.runModal()
        // Record the checkbox before acting on the button, so ticking
        // "Don't show again" and then opening the welcome still
        // suppresses future alerts.
        viewModel.recordDismiss(suppressForever: suppress.state == .on)
        if response == .alertSecondButtonReturn {
            WelcomeCoordinator.shared.present(id: WelcomeCatalog.simulatorCoexistenceID)
        }
    }

    /// Name only the route that is still live. A user who already set
    /// one of the two preferences shouldn't be warned about the hazard
    /// they closed.
    static func informativeText(for hazard: SimulatorShutdownHazard) -> String {
        let cause: String
        switch hazard {
        case .both:
            cause = "Closing Simulator.app's device window, or quitting Simulator.app,"

        case .appQuit:
            // Closing the last device window quits the app outright, so
            // this wording has to cover both gestures.
            cause = "Quitting Simulator.app, which includes closing its last device window,"

        case .windowClose:
            cause = "Closing this sim's Simulator.app window while other device windows stay open"
        }
        return """
            This sim is now open in both DeviceTerm and Apple's Simulator.app. \
            \(cause) will shut it down and end the DeviceTerm pane.

            Quit Simulator.app before booting a sim to keep it in DeviceTerm only.
            """
    }
}
