// SPDX-License-Identifier: GPL-3.0-or-later
//
// HeadlessAdvisoryViewModel: observable state behind the
// Simulator.app coexistence advisory. The presenter
// (`HeadlessAdvisory.presentIfNeeded`) reads `shouldPresent` to gate
// the NSAlert and calls `markPresented` / `recordDismiss` after.
//
// Owns three pieces of state:
//
//   - `shownThisLaunch`: in-process latch so a burst of sim-pane
//     attaches doesn't fire the modal more than once per launch.
//   - persistent suppression: the `simulator-app-advisory` key in
//     `~/.config/deviceterm/config`, set to `suppress` if the user ticks
//     "Don't show again". Survives quits. deviceterm keeps every
//     preference in this one file (never `UserDefaults`).
//   - whether `Simulator.app` is running, queried via
//     `NSRunningApplication` at decision time so the answer is
//     fresh per attach.
//
// All three reads/writes are injected as closures so the test
// target can substitute fakes; the production `init()` wires the
// real defaults / running-application lookup.

import AppKit
import Foundation
import Observation

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
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .isEmpty
    }

    /// True once the presenter has shown the modal in this launch.
    /// In-process latch; not persisted.
    private(set) var shownThisLaunch: Bool = false

    private let isSuppressedReader: @MainActor () -> Bool
    private let suppressedWriter: @MainActor (Bool) -> Void
    private let isSimulatorAppRunningReader: @MainActor () -> Bool

    /// Compose all three gates: not-yet-shown-this-launch, not
    /// persistently suppressed, and Simulator.app is running now.
    /// `isSimulatorAppRunningReader` is queried last so we don't pay
    /// the NSRunningApplication scan when the cheaper latches
    /// already say "skip".
    var shouldPresent: Bool {
        guard !shownThisLaunch else { return false }
        guard !isSuppressedReader() else { return false }
        return isSimulatorAppRunningReader()
    }

    init(
        isSuppressed: @escaping @MainActor () -> Bool = HeadlessAdvisoryViewModel.defaultIsSuppressed,
        recordSuppressed: @escaping @MainActor (Bool) -> Void = HeadlessAdvisoryViewModel.defaultRecordSuppressed,
        isSimulatorAppRunning: @escaping @MainActor () -> Bool = HeadlessAdvisoryViewModel.defaultIsSimulatorAppRunning
    ) {
        self.isSuppressedReader = isSuppressed
        self.suppressedWriter = recordSuppressed
        self.isSimulatorAppRunningReader = isSimulatorAppRunning
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
