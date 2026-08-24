// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Applies cohort device effects to `DeviceCoordinator` in emission order.
///
/// Emission is a synchronous enqueue inside `PaneCoordinator`'s commit turn,
/// so the stream order is the actor's commit order; the one consumer task
/// preserves it. Exactly-once is structural too: journal hits and recorded
/// verdicts never re-emit, and each enqueued effect is consumed once.
public struct CohortEffectPump: Sendable {
    enum Element: Sendable {
        case effect(CohortDeviceEffect)
        /// A drain marker: resumed by the consumer after everything enqueued
        /// before it has been applied. Tests use it to assert
        /// `DeviceCoordinator` state deterministically.
        case quiesce(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Element>.Continuation
    private let consumer: Task<Void, Never>

    init(deviceCoordinator: DeviceCoordinator) {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        self.continuation = continuation
        consumer = Task {
            for await element in stream {
                switch element {
                case let .effect(effect):
                    await deviceCoordinator.applyCohortEffect(effect)

                case let .quiesce(waiter):
                    waiter.resume()
                }
            }
        }
    }

    func emit(_ effect: CohortDeviceEffect) {
        continuation.yield(.effect(effect))
    }

    /// Wait until every effect enqueued before this call has been applied.
    func quiesce() async {
        await withCheckedContinuation { waiter in
            continuation.yield(.quiesce(waiter))
        }
    }
}
