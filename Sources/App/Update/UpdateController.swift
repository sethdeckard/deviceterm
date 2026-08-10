// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdateController: owns the Sparkle `SPUUpdater` driven by our custom
// `UpdateUserDriver`, applies the `auto-update` config policy, backs the
// "Check for Updates…" menu action, and hosts the update pill as a
// titlebar accessory on the key window.

import AppKit
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdateController {
    let viewModel = UpdateViewModel()

    private let policyProvider: () -> AutoUpdatePolicy
    private let driver: UpdateUserDriver
    private let updater: SPUUpdater

    private var observation: ObservationToken?
    private var accessory: NSTitlebarAccessoryViewController?
    private weak var hostedWindow: NSWindow?
    private var dismissGeneration = 0

    init(policyProvider: @escaping () -> AutoUpdatePolicy) {
        self.policyProvider = policyProvider
        driver = UpdateUserDriver(viewModel: viewModel, policyProvider: policyProvider)
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        applyPolicy()
        do {
            try updater.start()
        } catch {
            NSLog("UpdateController: Sparkle failed to start: \(error)")
        }
        observation = observe { [weak self] in self?.refreshPresentation() }
    }

    /// Apply the current `auto-update` config policy to Sparkle. Call at
    /// startup and whenever the config reloads.
    func applyPolicy() {
        let policy = policyProvider()
        updater.automaticallyChecksForUpdates = policy.automaticallyChecksForUpdates
        updater.automaticallyDownloadsUpdates = policy.automaticallyDownloadsUpdates
    }

    /// App menu > Check for Updates…, always allowed regardless of policy.
    @objc
    func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    /// Debug: drive the pill through every state (see `UpdateSimulator`).
    func simulateStates() {
        UpdateSimulator.drive(viewModel)
    }

    // MARK: - Pill presentation

    private func refreshPresentation() {
        // Read the observed state so this re-arms on every transition.
        let visible = viewModel.isVisible
        let autoDismisses = viewModel.state.autoDismisses

        if visible {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            if hostedWindow !== window { removeAccessory() }
            if accessory == nil, let window {
                let controller = NSTitlebarAccessoryViewController()
                controller.layoutAttribute = .right
                let host = NSHostingView(rootView: UpdatePillView(viewModel: viewModel))
                host.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
                controller.view = host
                window.addTitlebarAccessoryViewController(controller)
                accessory = controller
                hostedWindow = window
            }
            if autoDismisses { scheduleAutoDismiss() }
        } else {
            removeAccessory()
        }
    }

    private func scheduleAutoDismiss() {
        dismissGeneration += 1
        let generation = dismissGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                generation == self.dismissGeneration,
                self.viewModel.state.autoDismisses
            else { return }
            self.viewModel.reset()
        }
    }

    private func removeAccessory() {
        // Removing from the window's accessory list also detaches the
        // controller from its parent; a removeFromParent() first would
        // empty the list and invalidate the index.
        if let accessory, let hostedWindow,
            let index = hostedWindow.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            hostedWindow.removeTitlebarAccessoryViewController(at: index)
        }
        accessory = nil
        hostedWindow = nil
    }
}
