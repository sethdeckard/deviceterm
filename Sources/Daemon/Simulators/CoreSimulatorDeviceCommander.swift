// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The daemon's off-executor runner for CoreSimulator device commands.
///
/// Boot and shutdown are synchronous bridge calls that wait on the service the
/// same way enumeration does. Run inline on `DeviceCoordinator`, one of them
/// holds the actor, and with it every `device.list` and status-item poll, for
/// as long as CoreSimulator takes, with no deadline able to apply because the
/// waiting callers never reach the read path. This confines each command to a
/// serial DispatchQueue and lets the actor suspend instead.
///
/// The queue is separate from `CoreSimulatorDeviceReader`'s so a command never
/// waits behind an enumeration that a caller has already abandoned.
///
/// `@unchecked Sendable`: the one stored property is immutable, and the queue
/// serializes every invocation.
final class CoreSimulatorDeviceCommander: @unchecked Sendable {
    private let queue: DispatchQueue

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.deviceterm.daemon.coresimulator-commands",
            qos: .userInitiated
        )
    ) {
        self.queue = queue
    }

    /// Run `work` on the command queue and rethrow whatever it throws. The
    /// bridge handle stays inside `work`: `SimDeviceHandle` is not `Sendable`,
    /// so nothing of it crosses back to the caller.
    func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
