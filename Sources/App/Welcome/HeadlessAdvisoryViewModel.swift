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
///   - `shownThisLaunch`: in-process latch so a burst of sim-pane
///     attaches doesn't fire the modal more than once per launch.
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

    /// Shared instance the presenter uses by default. The latch in
    /// `shownThisLaunch` is process-global, so all sim-pane attaches
    /// route through the same VM and the modal fires at most once
    /// per launch.
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
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: SimulatorDetachPolicy.simulatorBundleID)
            .isEmpty
    }

    private static let defaultWelcomeShownThisLaunch: @MainActor () -> Bool = {
        WelcomeCoordinator.shared.didShowThisLaunch
    }

    private static let defaultDetachPolicy: @MainActor () -> SimulatorDetachPolicy = {
        SimulatorDetachPolicy.current()
    }

    /// True once the presenter has shown the modal in this launch.
    /// In-process latch; not persisted.
    private(set) var shownThisLaunch: Bool = false

    private let isSuppressedReader: @MainActor () -> Bool
    private let suppressedWriter: @MainActor (Bool) -> Void
    private let isSimulatorAppRunningReader: @MainActor () -> Bool
    private let welcomeShownReader: @MainActor () -> Bool
    private let detachPolicyReader: @MainActor () -> SimulatorDetachPolicy

    /// Whether to present, and which hazard to name. The readers are
    /// passed through as closures rather than called here, so
    /// `HeadlessAdvisoryDecision` keeps the cheap-gates-first order: no
    /// `NSRunningApplication` scan or cross-process preferences read
    /// happens when a latch already says skip.
    var decision: HeadlessAdvisoryDecision {
        HeadlessAdvisoryDecision.resolve(
            shownThisLaunch: shownThisLaunch,
            welcomeShownThisLaunch: welcomeShownReader(),
            isSuppressed: isSuppressedReader,
            isSimulatorAppRunning: isSimulatorAppRunningReader,
            policy: detachPolicyReader
        )
    }

    init(
        isSuppressed: @escaping @MainActor () -> Bool = HeadlessAdvisoryViewModel.defaultIsSuppressed,
        recordSuppressed: @escaping @MainActor (Bool) -> Void = HeadlessAdvisoryViewModel.defaultRecordSuppressed,
        isSimulatorAppRunning: @escaping @MainActor () -> Bool
            = HeadlessAdvisoryViewModel.defaultIsSimulatorAppRunning,
        welcomeShownThisLaunch: @escaping @MainActor () -> Bool
            = HeadlessAdvisoryViewModel.defaultWelcomeShownThisLaunch,
        detachPolicy: @escaping @MainActor () -> SimulatorDetachPolicy
            = HeadlessAdvisoryViewModel.defaultDetachPolicy
    ) {
        self.isSuppressedReader = isSuppressed
        self.suppressedWriter = recordSuppressed
        self.isSimulatorAppRunningReader = isSimulatorAppRunning
        self.welcomeShownReader = welcomeShownThisLaunch
        self.detachPolicyReader = detachPolicy
    }

    /// Latch in-process so a burst of sim attaches doesn't reopen
    /// the modal. Persisted suppression is separate (writes
    /// `simulator-app-advisory = suppress` via
    /// `recordDismiss(suppressForever: true)`).
    func markPresented() {
        shownThisLaunch = true
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
