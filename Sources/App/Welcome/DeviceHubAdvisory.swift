// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Presenter for the Device Hub coexistence modal. Reads
/// `DeviceHubAdvisoryViewModel.decision(isPhysicalDevice:)` to gate the
/// NSAlert and pick its copy, builds it with a "Don't show again"
/// checkbox, runs it modally, and reports the dismiss result back to the
/// VM so a future launch can skip the prompt.
///
/// The warning is preemptive, and has to be. DeviceTerm cannot observe
/// either hazard: nothing reports that Device Hub is about to be quit, and
/// nothing reports losing control of a physical device, because
/// `InteractionRelay.sendTouch` returns once the report reaches the wire
/// and `InteractionOutcome` carries no failure case. So this says what
/// *may* happen, and must not imply it has observed anything.
///
/// The alert's job is the hazard, not the explanation. It names what this
/// pane is exposed to and offers Learn More…; the coexistence welcome
/// carries the whole model. The skip conditions are: any coexistence
/// advisory already shown this launch, suppressed by the user, Device Hub
/// not running, or a welcome already ran this session.
///
/// Triggered from `SimulatorPaneViewController.viewDidLoad` after the pane
/// finishes layout, for both pane kinds.
@MainActor
enum DeviceHubAdvisory {
    /// Show the modal if the VM says we should.
    /// - Parameters:
    ///   - viewModel: injected so a test can supply a silent one.
    ///   - isPhysicalDevice: which hazard this pane is exposed to.
    static func presentIfNeeded(
        viewModel: DeviceHubAdvisoryViewModel,
        isPhysicalDevice: Bool
    ) {
        guard case let .warn(hazard) = viewModel.decision(isPhysicalDevice: isPhysicalDevice) else {
            return
        }
        viewModel.markPresented()

        let alert = NSAlert()
        alert.messageText = "Apple's Device Hub is running."
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
            WelcomeCoordinator.shared.present(id: WelcomeCatalog.deviceHubCoexistenceID)
        }
    }

    /// Copy for each hazard.
    ///
    /// The sim case names ⌥ because a reader with sims booted right now
    /// has no other way out, and says it is one-time so nobody treats it
    /// as a setting. The device case describes contention without
    /// claiming the mirror breaks: both apps keep streaming video.
    static func informativeText(for hazard: DeviceHubHazard) -> String {
        switch hazard {
        case .simulatorShutdownOnQuit:
            return """
                Quitting Device Hub shuts down every booted Simulator, including this one, \
                and its DeviceTerm pane closes with it. That happens whether or not you \
                ever opened this sim in Device Hub.

                Holding ⌥ at quit keeps them running (⌥⌘Q), but that is a one-time choice \
                rather than a setting. Quit Device Hub before booting a sim to keep it in \
                DeviceTerm only.
                """

        case .deviceControlContention:
            return """
                Device Hub can show this device's screen at the same time as DeviceTerm, \
                and neither mirror drops. Only one of them can control it: interact from \
                the other app and nothing happens for a while, then control moves there \
                and the first app goes dead.

                Drive the device from one app. You don't have to close the other.
                """
        }
    }
}
