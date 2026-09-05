// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation

/// Observable state behind the
/// Simulator.app coexistence advisory. The presenter
/// (`HeadlessAdvisory.presentIfNeeded`) reads `decision` to gate the
/// NSAlert and pick its copy, then calls `markPresented` /
/// `recordDismiss`.
///
/// Supplies the state `HeadlessAdvisoryDecision` resolves:
///
///   - the shared once-per-launch latch, so a burst of sim-pane attaches
///     doesn't fire the modal more than once, and this advisory and
///     Device Hub's can't both land on a single attach.
///   - whether a welcome already ran this launch. A session where the
///     coexistence welcome already explained this gets no alert stacked
///     on top of it.
///   - persistent suppression: the `simulator-app-advisory` key in
///     `~/.config/deviceterm/config`, set to `suppress` if the user ticks
///     "Don't show again". Survives quits. deviceterm keeps every
///     preference in this one file (never `UserDefaults`).
///   - whether `Simulator.app` is running, queried via
///     `NSRunningApplication` at decision time so the answer is
///     fresh per attach.
///   - Simulator.app's own detach preferences, which decide whether a
///     hazard remains at all and which one to name.
///
/// Every read/write is injected as a closure so the test target can
/// substitute fakes; the production `init()` wires the real config file,
/// welcome coordinator, running-application lookup, and preferences read.
@MainActor
@Observable
final class HeadlessAdvisoryViewModel {
    /// The `~/.config/deviceterm/config` key the presenter sets to
    /// `suppress` when the user checks "Don't show again". Pinned
    /// across tests + production so a rename doesn't silently
    /// re-prompt every existing user.
    static let suppressKey = "simulator-app-advisory"

    /// Shared instance the presenter uses by default. It carries the
    /// process-wide `CoexistenceAdvisoryLatch`, so every pane attach
    /// routes through the same flag and one coexistence modal fires at
    /// most once per launch.
    static let shared = HeadlessAdvisoryViewModel()

    private static let defaultIsSuppressed: @MainActor () -> Bool = {
        ConfigFile().value(forKey: HeadlessAdvisoryViewModel.suppressKey) == "suppress"
    }

    private static let defaultRecordSuppressed: @MainActor (Bool) -> Void = { suppress in
        guard suppress else { return }
        let config = ConfigFile()
        config.setValue("suppress", forKey: HeadlessAdvisoryViewModel.suppressKey)
        config.seedDocumentedExamples()
        try? config.save()
    }

    private static let defaultIsSimulatorAppRunning: @MainActor () -> Bool = {
        CoexistenceApp.simulator.isRunning()
    }

    private static let defaultWelcomeShownThisLaunch: @MainActor () -> Bool = {
        WelcomeCoordinator.shared.didShowThisLaunch
    }

    private static let defaultDetachPolicy: @MainActor () -> SimulatorDetachPolicy = {
        SimulatorDetachPolicy.current()
    }

    /// Whether Device Hub's advisory would fire for the same pane, in
    /// which case this one yields to it. Asks the shared Device Hub view
    /// model rather than duplicating its gates, so suppression and the
    /// running check stay in one place.
    private static let defaultDeviceHubWillWarn: @MainActor (Bool) -> Bool = { isPhysicalDevice in
        DeviceHubAdvisoryViewModel.shared.decision(isPhysicalDevice: isPhysicalDevice) != .skip
    }

    private let latch: CoexistenceAdvisoryLatch
    private let isSuppressedReader: @MainActor () -> Bool
    private let suppressedWriter: @MainActor (Bool) -> Void
    private let isSimulatorAppRunningReader: @MainActor () -> Bool
    private let welcomeShownReader: @MainActor () -> Bool
    private let detachPolicyReader: @MainActor () -> SimulatorDetachPolicy
    private let deviceHubWillWarnReader: @MainActor (Bool) -> Bool

    init(
        latch: CoexistenceAdvisoryLatch = .shared,
        isSuppressed: @escaping @MainActor () -> Bool = HeadlessAdvisoryViewModel.defaultIsSuppressed,
        recordSuppressed: @escaping @MainActor (Bool) -> Void = HeadlessAdvisoryViewModel.defaultRecordSuppressed,
        isSimulatorAppRunning: @escaping @MainActor () -> Bool
            = HeadlessAdvisoryViewModel.defaultIsSimulatorAppRunning,
        welcomeShownThisLaunch: @escaping @MainActor () -> Bool
            = HeadlessAdvisoryViewModel.defaultWelcomeShownThisLaunch,
        detachPolicy: @escaping @MainActor () -> SimulatorDetachPolicy
            = HeadlessAdvisoryViewModel.defaultDetachPolicy,
        deviceHubWillWarn: @escaping @MainActor (Bool) -> Bool
            = HeadlessAdvisoryViewModel.defaultDeviceHubWillWarn
    ) {
        self.latch = latch
        self.isSuppressedReader = isSuppressed
        self.suppressedWriter = recordSuppressed
        self.isSimulatorAppRunningReader = isSimulatorAppRunning
        self.welcomeShownReader = welcomeShownThisLaunch
        self.detachPolicyReader = detachPolicy
        self.deviceHubWillWarnReader = deviceHubWillWarn
    }

    /// Whether to present for a pane of this kind, and which hazard to
    /// name. The I/O-backed readers are passed through as closures rather
    /// than called here, so `HeadlessAdvisoryDecision` keeps the
    /// cheap-gates-first order: no `NSRunningApplication` scan or
    /// cross-process preferences read happens when a latch already says
    /// skip. The two in-memory flags are read eagerly, since a closure
    /// would buy nothing.
    ///
    /// A function rather than a property because the answer depends on
    /// the pane, and one shared view model serves every pane.
    func decision(isPhysicalDevice: Bool) -> HeadlessAdvisoryDecision {
        HeadlessAdvisoryDecision.resolve(
            isPhysicalDevice: isPhysicalDevice,
            advisoryShownThisLaunch: latch.didShowThisLaunch,
            welcomeShownThisLaunch: welcomeShownReader(),
            isSuppressed: isSuppressedReader,
            isSimulatorAppRunning: isSimulatorAppRunningReader,
            policy: detachPolicyReader,
            deviceHubWillWarn: { self.deviceHubWillWarnReader(isPhysicalDevice) }
        )
    }

    /// Latch in-process so a burst of sim attaches doesn't reopen the
    /// modal, and so Device Hub's advisory doesn't fire straight after
    /// this one on the same attach. Persisted suppression is separate
    /// (writes `simulator-app-advisory = suppress` via
    /// `recordDismiss(suppressForever: true)`).
    func markPresented() {
        latch.markPresented()
    }

    /// Called by the presenter after the alert dismisses. If the
    /// user ticked "Don't show again", persist `suppress` so the
    /// next launch doesn't re-prompt.
    func recordDismiss(suppressForever: Bool) {
        if suppressForever {
            suppressedWriter(true)
        }
    }
}
