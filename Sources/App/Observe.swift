// SPDX-License-Identifier: GPL-3.0-or-later

import Observation

/// Bind `apply` to the `@Observable` state it reads, re-running it on the
/// next main-actor turn whenever any read property changes. Call once;
/// keep the returned token alive for as long as the binding should run.
///
/// The re-arming Observation→render bridge for AppKit, and the keystone of
/// the view-model layer. An AppKit view controller
/// binds ONCE (in viewDidLoad) with `observe { [weak self] in
/// self?.render() }`; thereafter any change to an `@Observable` property
/// the render closure reads schedules `render()` again on the next main-
/// actor turn. VC→VM is intent method calls; VM→VC is this automatic
/// re-render. The same `@Observable` view model is observed natively by a
/// SwiftUI surface; `observe()` is the AppKit-only adapter.
///
/// Contract:
///   - render() must READ every observed property it cares about on every
///     pass. Observation only tracks what was accessed, so an early
///     return stops observing the fields it skipped.
///   - Re-arm happens on the NEXT main-actor turn (Task), never
///     synchronously in onChange: onChange fires mid-mutation and is
///     one-shot, so a synchronous re-render risks reentrancy and tracks
///     only the single change.
///   - Teardown: the owning VC holds the token (stored property). The
///     re-arm weak-captures the token, so dropping it (or calling
///     cancel()) ends the binding: the next queued re-arm no-ops. Pair
///     with `[weak self]` in the render closure so a pending re-arm can't
///     keep the VC alive.
@discardableResult
@MainActor
func observe(_ apply: @escaping @MainActor () -> Void) -> ObservationToken {
    let token = ObservationToken(apply)
    token.arm()
    return token
}
