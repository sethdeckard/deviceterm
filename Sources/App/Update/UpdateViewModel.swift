// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdateViewModel: the observable state behind the unobtrusive update
// pill. The custom Sparkle driver (`UpdateUserDriver`) sets `state`; the
// pill renders it. Deliberately Sparkle-free: each state carries plain
// closures the driver wires to Sparkle's callbacks, so this type (and its
// presentation mapping) is unit-testable without the framework.
//
// `permissionRequest` is intentionally omitted: the `auto-update`
// config key drives consent, not a Sparkle prompt.

import Foundation
import Observation

@MainActor
@Observable
final class UpdateViewModel {
    enum State {
        case idle
        case checking(cancel: () -> Void)
        case updateAvailable(
            version: String,
            notes: String?,
            install: () -> Void,
            dismiss: () -> Void
        )
        case downloading(fraction: Double?, cancel: () -> Void)
        case extracting(fraction: Double)
        case readyToInstall(install: () -> Void)
        case notFound(dismiss: () -> Void)
        case error(message: String, dismiss: () -> Void)
    }

    private(set) var state: State = .idle

    var isVisible: Bool {
        if case .idle = state { return false }
        return true
    }

    func set(_ state: State) { self.state = state }
    func reset() { state = .idle }
}

extension UpdateViewModel.State {
    /// Whether the state clears itself after a short delay (the passive,
    /// non-actionable outcomes) vs. persisting until the user acts.
    var autoDismisses: Bool {
        switch self {
        case .notFound, .error:
            return true

        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .idle:
            return ""

        case .checking:
            return "Checking for Updates…"

        case let .updateAvailable(version, _, _, _):
            return "Update Available: \(version)"

        case let .downloading(fraction, _):
            return fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…"

        case let .extracting(fraction):
            return "Preparing \(Int(fraction * 100))%"

        case .readyToInstall:
            return "Restart to Complete Update"

        case .notFound:
            return "No Updates Available"

        case .error:
            return "Update Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            return ""

        case .checking:
            return "arrow.triangle.2.circlepath"

        case .updateAvailable, .downloading:
            return "arrow.down.circle"

        case .extracting:
            return "shippingbox"

        case .readyToInstall:
            return "arrow.clockwise.circle"

        case .notFound:
            return "checkmark.circle"

        case .error:
            return "exclamationmark.triangle"
        }
    }

    var tint: UpdateTint {
        switch self {
        case .idle, .checking:
            return .neutral

        case .updateAvailable, .downloading, .extracting, .readyToInstall:
            return .accent

        case .notFound:
            return .positive

        case .error:
            return .negative
        }
    }

    /// Version + release notes for the update popover, when an update is
    /// available. `notes` is the appcast's HTML description (or `nil`).
    var updateDetails: (version: String, notes: String?)? {
        if case let .updateAvailable(version, notes, _, _) = self {
            return (version, notes)
        }
        return nil
    }

    /// The primary action label + closure, when the state is actionable.
    var primaryAction: (label: String, run: () -> Void)? {
        switch self {
        case let .updateAvailable(_, _, install, _):
            return ("Update", install)

        case let .readyToInstall(install):
            return ("Restart", install)

        default:
            return nil
        }
    }

    /// Closure to dismiss the pill, when the state can be dismissed by the
    /// user (a tap on the pill / a close affordance).
    var dismissAction: (() -> Void)? {
        switch self {
        case let .updateAvailable(_, _, _, dismiss):
            return dismiss

        case let .notFound(dismiss):
            return dismiss

        case let .error(_, dismiss):
            return dismiss

        case let .checking(cancel):
            return cancel

        case let .downloading(_, cancel):
            return cancel

        default:
            return nil
        }
    }
}
