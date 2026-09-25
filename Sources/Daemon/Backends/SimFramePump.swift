// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOSurface

/// Copies only dirty frames, with a fixed ceiling and no timer while idle.
struct SimFramePump: Sendable {
    struct Timing: Sendable {
        var interval: Duration = .nanoseconds(16_666_667)
        var recoveryDelay: Duration = .seconds(2)
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
        var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        }
    }

    let signal: SimFrameSignal
    let pool: LeasedSurfacePool
    var timing = Timing()
    let read: @Sendable () async -> RetainedSurface?
    let publish: @Sendable (PublishedSurface) -> Void
    let fail: @Sendable (String) -> Void

    func run() async {
        var nextAttempt: ContinuousClock.Instant?
        var unavailableSince: ContinuousClock.Instant?
        for await _ in signal.wakes {
            do {
                if let deadline = nextAttempt, timing.now() < deadline {
                    try await timing.sleep(deadline)
                }
                try Task.checkCancellation()
            } catch { return }
            guard let update = signal.consume() else { continue }
            nextAttempt = timing.now().advanced(by: timing.interval)
            let resolved: RetainedSurface?
            switch update {
            case let .surface(surface):
                resolved = surface

            case .invalidated:
                resolved = await read()
            }
            guard let source = resolved, !Task.isCancelled else { continue }
            let now = timing.now()
            nextAttempt = now.advanced(by: timing.interval)
            let dims = source.withRef { (IOSurfaceGetWidth($0), IOSurfaceGetHeight($0)) }
            guard let published = await pool.acquire(width: dims.0, height: dims.1) else {
                if unavailableSince == nil { unavailableSince = now }
                if let since = unavailableSince, now - since >= timing.recoveryDelay {
                    unavailableSince = nil
                    switch await pool.recoverFromExhaustion() {
                    case .recovered:
                        DiagnosticLog.attach.notice("surface pool unavailable; recovery will retry on the next frame")

                    case .exhausted:
                        fail("surface pool stayed unavailable after recovery; the mirror can't continue")
                        return
                    }
                }
                continue
            }
            unavailableSince = nil
            guard !Task.isCancelled else { return }
            published.surface.withRef { destination in
                source.withRef { origin in
                    _ = SurfaceCopy.copy(from: origin, to: destination)
                }
            }
            guard !Task.isCancelled else { return }
            publish(published)
        }
    }
}
