// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import os
import Sparkle

/// Narrates the update check so a stalled or silent one can be diagnosed
/// afterwards from `log show`. Sparkle itself logs nothing during a routine
/// check, so without this a check that starts and never finishes leaves no
/// trace at all.
private let updateLog = Logger(subsystem: "com.deviceterm", category: "update")

/// Owns the Sparkle `SPUUpdater` driven by our custom
/// `UpdateUserDriver`, applies the `auto-update` config policy, backs the
/// "Check for Updates…" menu action, and hosts the update pill as a
/// titlebar accessory on the key window.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    let viewModel = UpdateViewModel()

    private let policyProvider: () -> AutoUpdatePolicy
    private let driver: UpdateUserDriver

    /// Lazy so `self` can be the updater's delegate: `SPUUpdater` takes its
    /// delegate at construction and vends no settable property for it, and
    /// `self` isn't available until every stored property is initialized.
    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: driver,
        delegate: self
    )

    private var observation: ObservationToken?
    /// `nonisolated(unsafe)` because the nonisolated deinit needs to read it
    /// for cleanup (`NSObjectProtocol` isn't Sendable, so a plain @MainActor
    /// stored property would be unreachable from the deinit). It is written
    /// once on the main actor during `init`, so the deinit's snapshot is the
    /// only off-isolation read, and NotificationCenter.removeObserver is
    /// thread-safe.
    nonisolated(unsafe) private var windowObservers: [any NSObjectProtocol] = []
    private var accessory: NSTitlebarAccessoryViewController?
    private weak var hostedWindow: NSWindow?
    private var dismissGeneration = 0

    /// Whether "Check for Updates…" can do anything right now. Drives the
    /// menu item's enabled state so a refused check reads as a disabled item
    /// rather than one that responds to nothing.
    ///
    /// False while Sparkle downloads the feed or an update in the background,
    /// and false for good if `start()` threw. In either case it refuses
    /// silently. There is no recovery to offer alongside: `resetUpdateCycle`
    /// does nothing while a session is in progress, which is one of the states
    /// this covers.
    var canPerformCheck: Bool {
        updater.canCheckForUpdates
    }

    init(policyProvider: @escaping () -> AutoUpdatePolicy) {
        self.policyProvider = policyProvider
        driver = UpdateUserDriver(viewModel: viewModel, policyProvider: policyProvider)
        super.init()
        // Sparkle asks the driver to bring the current update into focus; the
        // driver has no window knowledge, so it hands the request back here.
        driver.onRevealRequested = { [weak self] in self?.refreshPresentation() }
        applyPolicy()
        do {
            try updater.start()
        } catch {
            updateLog.error(
                "Sparkle failed to start: \(ErrorText.describing(error), privacy: .public)"
            )
        }
        // `App.observe`, not `observe`: NSObject's KVO `observe` shadows the
        // global helper inside an NSObject subclass.
        observation = App.observe { [weak self] in self?.refreshPresentation() }
        observeWindowChanges()
    }

    /// `NotificationCenter.removeObserver` is thread-safe, so the nonisolated
    /// deinit can drop the window observers directly.
    nonisolated deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Apply the current `auto-update` config policy to Sparkle. Call at
    /// startup and whenever the config reloads.
    func applyPolicy() {
        let policy = policyProvider()
        updater.automaticallyChecksForUpdates = policy.automaticallyChecksForUpdates
        updater.automaticallyDownloadsUpdates = policy.automaticallyDownloadsUpdates
    }

    /// App menu > Check for Updates…, always allowed regardless of policy.
    ///
    /// `AppDelegate.validateMenuItem` disables the item when Sparkle won't
    /// take a check, so the refusal below is only reachable if AppKit
    /// dispatches without validating.
    @objc
    func checkForUpdates(_ sender: Any?) {
        guard canPerformCheck else {
            updateLog.notice("check refused: Sparkle cannot accept a check right now")
            return
        }
        updateLog.notice("check requested from the menu")
        updater.checkForUpdates()
    }

    /// Debug: drive the pill through every state (see `UpdateSimulator`).
    func simulateStates() {
        UpdateSimulator.drive(viewModel)
    }

    // MARK: - SPUUpdaterDelegate

    // Purely observational. Sparkle drives scheduled checks without touching
    // the user driver until it has something to show, so these are the only
    // hooks that can witness a check that starts and never finishes.

    // `throws` is the requirement's shape (an ObjC BOOL/NSError** pair, where
    // not throwing means "allowed"); this override only observes.
    // swiftlint:disable:next unneeded_throws_rethrows
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        updateLog.notice("check starting (kind=\(updateCheck.rawValue, privacy: .public))")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateLog.notice("found \(item.displayVersionString, privacy: .public)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        updateLog.notice("no update available")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // "You're up to date" and a declined install both arrive here as
        // aborts, so this fires on ordinary use; logging them at .error would
        // make a healthy updater look broken.
        if SparkleErrorOutcome.isBenign(error) { return }
        updateLog.error("aborted: \(ErrorText.describing(error), privacy: .public)")
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        let kind = updateCheck.rawValue
        guard let error, !SparkleErrorOutcome.isBenign(error) else {
            updateLog.notice("cycle finished (kind=\(kind, privacy: .public))")
            return
        }
        updateLog.error(
            """
            cycle finished (kind=\(kind, privacy: .public)): \
            \(ErrorText.describing(error), privacy: .public)
            """
        )
    }

    // MARK: - Pill presentation

    /// Re-present on window changes as well as on state changes.
    ///
    /// `refreshPresentation` needs a window to attach to, and the state that
    /// wants presenting can arrive while there is none (the app inactive, or
    /// between windows). Observation only re-fires when the view model
    /// *changes*, so these notifications retry presentation when a visible
    /// state was set while no window was available and remains unchanged.
    private func observeWindowChanges() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification
        ]
        windowObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshPresentation()
                }
            }
        }
    }

    private func refreshPresentation() {
        // Read the observed state so this re-arms on every transition.
        let visible = viewModel.isVisible
        let autoDismisses = viewModel.state.autoDismisses

        if visible {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            if hostedWindow !== window { removeAccessory() }
            if accessory == nil, let window {
                let controller = UpdatePillAccessory.make(viewModel: viewModel)
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
