// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Runs a closure at most once across every caller. A subscription's
/// producer cleanup is referenced by three independent paths (the local
/// pre-result `defer`, `SubscriptionResult.onCancel`, and
/// `SubscriptionLifecycle`) and must run exactly once no matter how many
/// of them fire. The serial queue gates the flag without an ad-hoc lock.
final class FireOnce: @unchecked Sendable {
    // Invariant: `fired` is read/written only inside `queue.sync`.
    private let queue = DispatchQueue(label: "deviceterm.daemon.fire-once")
    private var fired = false
    private let body: @Sendable () -> Void

    init(_ body: @escaping @Sendable () -> Void) {
        self.body = body
    }

    func callAsFunction() {
        let shouldRun: Bool = queue.sync {
            if fired { return false }
            fired = true
            return true
        }
        if shouldRun { body() }
    }
}
