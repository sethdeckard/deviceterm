// SPDX-License-Identifier: GPL-3.0-or-later

import Observation

/// Cancellation handle for an `observe()` binding, and the owner of the
/// re-arm loop. A `@MainActor` class is `Sendable`, so it can be
/// weak-captured by `withObservationTracking`'s `@Sendable` onChange,
/// which is what lets the re-arm hop back to the main actor without
/// dragging a non-Sendable closure into the change handler.
@MainActor
final class ObservationToken {
    private var isCancelled = false
    private let apply: () -> Void

    init(_ apply: @escaping @MainActor () -> Void) { self.apply = apply }

    /// End the binding. Optional, since dropping the token does the same via
    /// the weak capture in the re-arm.
    func cancel() { isCancelled = true }

    func arm() {
        guard !isCancelled else { return }
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor in self?.arm() }
        }
    }
}
