// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Bridges synchronous system work into async daemon code without parking a
/// Swift cooperative-executor worker.
///
/// A Dispatch queue for calls whose API offers no asynchronous wait. Serial by
/// default; independent work may opt into a concurrent queue explicitly.
///
/// `@unchecked Sendable`: `queue` is immutable, submitted closures are
/// `Sendable`, and values crossing the continuation are `Sendable`.
final class BlockingWorkQueue: @unchecked Sendable {
    private let queue: DispatchQueue

    init(
        label: String,
        qos: DispatchQoS = .default,
        attributes: DispatchQueue.Attributes = []
    ) {
        self.queue = DispatchQueue(label: label, qos: qos, attributes: attributes)
    }

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Enqueue cleanup that does not need to resume an async caller.
    func submit(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}
