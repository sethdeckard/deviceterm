// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Observable state behind the Device Hub coexistence advisory. The
/// presenter (`DeviceHubAdvisory.presentIfNeeded`) reads
/// `decision(isPhysicalDevice:)` to gate the NSAlert and pick its copy,
/// then calls `markPresented` / `recordDismiss`.
///
/// Supplies the state `DeviceHubAdvisoryDecision` resolves:
///
///   - the shared once-per-launch latch, so a burst of pane attaches
///     doesn't fire the modal more than once, and the Simulator.app
///     advisory and this one can't both land on a single attach.
///   - whether a welcome already ran this launch. A session where a
///     coexistence welcome already explained this gets no alert stacked
///     on top of it.
///   - persistent suppression: the `device-hub-advisory` key in
///     `~/.config/deviceterm/config`, set to `suppress` if the user ticks
///     "Don't show again". Survives quits. deviceterm keeps every
///     preference in this one file (never `UserDefaults`).
///   - whether Device Hub is running, queried via `NSRunningApplication`
///     at decision time so the answer is fresh per attach.
///
/// No preference of Device Hub's own is read, unlike
/// `HeadlessAdvisoryViewModel`, which consults Simulator.app's detach
/// keys. Device Hub's equivalent has no reachable UI and ⌥ at quit doesn't
/// change it, so the answer would be the same every time.
///
/// Every read/write is injected as a closure so the test target can
/// substitute fakes; the production `init()` wires the real config file,
/// welcome coordinator, shared latch, and running-application lookup.
@MainActor
@Observable
final class DeviceHubAdvisoryViewModel {
    /// The `~/.config/deviceterm/config` key the presenter sets to
    /// `suppress` when the user checks "Don't show again". Pinned
    /// across tests + production so a rename doesn't silently re-prompt
    /// every existing user.
    static let suppressKey = "device-hub-advisory"

    /// Shared instance the presenter uses by default.
    static let shared = DeviceHubAdvisoryViewModel()

    private static let defaultIsSuppressed: @MainActor () -> Bool = {
        ConfigFile().value(forKey: DeviceHubAdvisoryViewModel.suppressKey) == "suppress"
    }

    private static let defaultRecordSuppressed: @MainActor (Bool) -> Void = { suppress in
        guard suppress else { return }
        let config = ConfigFile()
        config.setValue("suppress", forKey: DeviceHubAdvisoryViewModel.suppressKey)
        config.seedDocumentedExamples()
        try? config.save()
    }

    private static let defaultIsDeviceHubRunning: @MainActor () -> Bool = {
        CoexistenceApp.deviceHub.isRunning()
    }

    private static let defaultWelcomeShownThisLaunch: @MainActor () -> Bool = {
        WelcomeCoordinator.shared.didShowThisLaunch
    }

    private let latch: CoexistenceAdvisoryLatch
    private let isSuppressedReader: @MainActor () -> Bool
    private let suppressedWriter: @MainActor (Bool) -> Void
    private let isDeviceHubRunningReader: @MainActor () -> Bool
    private let welcomeShownReader: @MainActor () -> Bool

    init(
        latch: CoexistenceAdvisoryLatch = .shared,
        isSuppressed: @escaping @MainActor () -> Bool = DeviceHubAdvisoryViewModel.defaultIsSuppressed,
        recordSuppressed: @escaping @MainActor (Bool) -> Void
            = DeviceHubAdvisoryViewModel.defaultRecordSuppressed,
        isDeviceHubRunning: @escaping @MainActor () -> Bool
            = DeviceHubAdvisoryViewModel.defaultIsDeviceHubRunning,
        welcomeShownThisLaunch: @escaping @MainActor () -> Bool
            = DeviceHubAdvisoryViewModel.defaultWelcomeShownThisLaunch
    ) {
        self.latch = latch
        self.isSuppressedReader = isSuppressed
        self.suppressedWriter = recordSuppressed
        self.isDeviceHubRunningReader = isDeviceHubRunning
        self.welcomeShownReader = welcomeShownThisLaunch
    }

    /// Whether to present for a pane of this kind, and which hazard to
    /// name. The I/O-backed readers are passed through as closures rather
    /// than called here, so `DeviceHubAdvisoryDecision` keeps the
    /// cheap-gates-first order: no `NSRunningApplication` scan happens
    /// when a latch already says skip. The two in-memory flags are read
    /// eagerly, since a closure would buy nothing.
    ///
    /// A function rather than a property because the answer depends on
    /// the pane, and one shared view model serves every pane.
    func decision(isPhysicalDevice: Bool) -> DeviceHubAdvisoryDecision {
        DeviceHubAdvisoryDecision.resolve(
            isPhysicalDevice: isPhysicalDevice,
            advisoryShownThisLaunch: latch.didShowThisLaunch,
            welcomeShownThisLaunch: welcomeShownReader(),
            isSuppressed: isSuppressedReader,
            isDeviceHubRunning: isDeviceHubRunningReader
        )
    }

    /// Latch in-process so a burst of attaches doesn't reopen the modal,
    /// and so the Simulator.app advisory doesn't fire straight after this
    /// one. Persisted suppression is separate (writes
    /// `device-hub-advisory = suppress` via
    /// `recordDismiss(suppressForever: true)`).
    func markPresented() {
        latch.markPresented()
    }

    /// Called by the presenter after the alert dismisses. If the user
    /// ticked "Don't show again", persist `suppress` so the next launch
    /// doesn't re-prompt.
    func recordDismiss(suppressForever: Bool) {
        if suppressForever {
            suppressedWriter(true)
        }
    }
}
