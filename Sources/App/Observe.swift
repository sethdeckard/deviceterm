// SPDX-License-Identifier: GPL-3.0-or-later
//
// observe(): the re-arming Observation→render bridge for AppKit,
// the keystone of the view-model layer. An AppKit view controller
// binds ONCE (in viewDidLoad) with `observe { [weak self] in
// self?.render() }`; thereafter any change to an `@Observable` property
// the render closure reads schedules `render()` again on the next main-
// actor turn. VC→VM is intent method calls; VM→VC is this automatic
// re-render. The same `@Observable` view model is observed natively by a
// future SwiftUI surface; `observe()` is the AppKit-only adapter.
//
// Contract:
//   • render() must READ every observed property it cares about on every
//     pass. Observation only tracks what was accessed, so an early
//     return stops observing the fields it skipped.
//   • Re-arm happens on the NEXT main-actor turn (Task), never
//     synchronously in onChange: onChange fires mid-mutation and is
//     one-shot, so a synchronous re-render risks reentrancy and tracks
//     only the single change.
//   • Teardown: the owning VC holds the token (stored property). The
//     re-arm weak-captures the token, so dropping it (or calling
//     cancel()) ends the binding: the next queued re-arm no-ops. Pair
//     with `[weak self]` in the render closure so a pending re-arm can't
//     keep the VC alive.

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

/// Bind `apply` to the `@Observable` state it reads, re-running it on the
/// next main-actor turn whenever any read property changes. Call once;
/// keep the returned token alive for as long as the binding should run.
@discardableResult
@MainActor
func observe(_ apply: @escaping @MainActor () -> Void) -> ObservationToken {
    let token = ObservationToken(apply)
    token.arm()
    return token
}
