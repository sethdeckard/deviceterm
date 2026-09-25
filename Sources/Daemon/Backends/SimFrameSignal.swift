// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Keeps the latest surface or invalidation and coalesces wakeups.
/// queue protects pending updates and termination; callbacks never enqueue tasks.
final class SimFrameSignal: @unchecked Sendable {
    enum Update: Sendable {
        case surface(RetainedSurface)
        case invalidated
    }

    let wakes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "com.deviceterm.sim.frame-signal")
    private var pending: Update?
    private var finished = false

    init() {
        (wakes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func notify(_ surface: RetainedSurface? = nil) {
        queue.sync {
            guard !finished else { return }
            let wake = pending == nil
            pending = surface.map(Update.surface) ?? .invalidated
            if wake { continuation.yield(()) }
        }
    }

    func consume() -> Update? {
        queue.sync {
            guard !finished else { return nil }
            defer { pending = nil }
            return pending
        }
    }

    func finish() {
        queue.sync {
            finished = true
            pending = nil
            continuation.finish()
        }
    }
}
