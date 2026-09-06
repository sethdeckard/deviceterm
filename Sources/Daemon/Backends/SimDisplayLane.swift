// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// The simulator display handle and everything whose lifetime is tied to it:
/// the frame run, its pump task, and the orientation observation.
///
/// The lane queue serializes display-handle lifecycle operations so starts,
/// stops, dimension reads, and orientation registration cannot race teardown.
///
/// `frameGate` stays separate and deliberately small. Publish and fatal
/// callbacks run from the frame pump and check their run token under
/// `frameGate`, so they do not wait behind lane work.
///
/// `@unchecked Sendable`: `SimDisplayHandle` is not Sendable, and every access
/// to it happens on `queue`. Methods here are the queue boundary; the private
/// helpers they call assume they are already on it, so none of them may hop
/// back onto `queue` and deadlock.
final class SimDisplayLane: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.sim.display-lane")
    /// Delivery queue for the bridge's orientation callbacks. Separate from the
    /// lane so an observation callback never lands on the lane's own queue.
    private let orientationQueue = DispatchQueue(label: "com.deviceterm.sim.display-orientation")
    // Fences frame/fatal callback eligibility against teardown. `startFrames`
    // captures the current `frameToken`; teardown bumps it (both under
    // `frameGate`). A callback fires only while its captured token is still
    // current, so no publish or fatal escapes after stop, with no
    // check-then-act window a bare cancellation check would leave.
    private let frameGate = DispatchQueue(label: "com.deviceterm.sim.frame-gate")
    private var frameToken: UInt64 = 0

    private var handle: SimDisplayHandle?
    private var frameTask: Task<Void, Never>?
    /// Hands surfaces from the bridge's callback queue to the copy pump.
    private var surfaceContinuation: AsyncStream<RetainedSurface>.Continuation?

    private let pool: LeasedSurfacePool
    private let recoveryThreshold: Int

    /// Whether the handle is still held. False once `shutdown()` has released
    /// it, which is what makes a post-teardown call answer rather than reach a
    /// dead bridge object.
    var isActive: Bool { queue.sync { handle != nil } }

    init(handle: SimDisplayHandle, pool: LeasedSurfacePool, recoveryThreshold: Int) {
        self.handle = handle
        self.pool = pool
        self.recoveryThreshold = recoveryThreshold
    }

    // MARK: - Frames

    /// Publish leased copies of the display's surface.
    ///
    /// Retires any previous run's token first, so a publish still in flight
    /// from it is dropped rather than reaching a consumer that has moved on.
    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws {
        try queue.sync {
            guard let handle else { throw DeviceBackendError.notActive }
            let pool = self.pool
            let recoveryThreshold = self.recoveryThreshold
            // Install a fresh run token; teardown bumps it to fence late
            // callbacks. Checked and invoked together under `frameGate`, so
            // teardown and a publish are mutually ordered with no window
            // between them.
            let gate = frameGate
            let token = gate.sync {
                frameToken += 1
                return frameToken
            }
            let publish: @Sendable (PublishedSurface) -> Void = { [weak self] published in
                guard let self else { return }
                gate.sync { if token == self.frameToken { onFrame(published) } }
            }
            let fail: @Sendable (String) -> Void = { [weak self] reason in
                guard let self else { return }
                gate.sync { if token == self.frameToken { onFatal(reason) } }
            }
            // The callback fires on the bridge's own queue and must not block
            // it, so it only hands the surface over. Latest-only: the pump
            // copies at whatever rate the pool allows, and an older frame
            // waiting behind a newer one has no value on a mirror.
            let (surfaces, continuation) = AsyncStream.makeStream(
                of: RetainedSurface.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            surfaceContinuation?.finish()
            surfaceContinuation = continuation
            frameTask = Task {
                await SimDeviceBackend.pumpFrames(
                    surfaces: surfaces,
                    pool: pool,
                    recoveryThreshold: recoveryThreshold,
                    publish: publish,
                    fail: fail
                )
            }
            // Wrap on the bridge's queue so the retain/use-count pairing
            // happens before the autoreleased source ref escapes.
            try handle.start { surfaceRef in
                guard let surfaceRef else { return }
                continuation.yield(RetainedSurface(surfaceRef))
            }
        }
    }

    func stopFrames() {
        queue.sync {
            invalidateFrameRunLocked()
            handle?.stop()
            releaseFrameRunLocked()
        }
    }

    func pixelDimensions() -> (Int?, Int?) {
        queue.sync {
            guard let handle else { return (nil, nil) }
            let size = handle.displaySize
            guard size.width > 0, size.height > 0 else { return (nil, nil) }
            return (Int(size.width), Int(size.height))
        }
    }

    // MARK: - Display orientation

    func startOrientation(
        onChange: @escaping @Sendable (Orientation) -> Void
    ) -> Bool {
        queue.sync {
            guard let handle else { return false }
            do {
                try handle.startOrientation(
                    callback: { raw in
                        guard let orientation = Orientation(displayValue: raw) else { return }
                        onChange(orientation)
                    },
                    queue: orientationQueue
                )
                return true
            } catch {
                // If orientation observation cannot start, leave the pane on
                // its last known orientation. Frames are unaffected, so the
                // pane remains usable.
                return false
            }
        }
    }

    func stopOrientation() {
        queue.sync { handle?.stopOrientation() }
    }

    func currentOrientation() -> Orientation? {
        queue.sync {
            guard let handle else { return nil }
            return Orientation(displayValue: handle.currentDisplayOrientation)
        }
    }

    // MARK: - Lifecycle

    /// Stop the frame stream and drop the handle. The IOSurface use-count must
    /// release so the kernel can reclaim it, and the run token retires first so
    /// a publish already in flight from the pump is dropped rather than
    /// reaching a pane that is going away.
    func shutdown() {
        queue.sync {
            invalidateFrameRunLocked()
            handle?.stop()
            handle = nil
            releaseFrameRunLocked()
        }
    }

    // MARK: - Queue-local helpers

    /// Retire the current frame run so any publish or fatal still in flight
    /// from it is dropped. Serialised with the callbacks on `frameGate`.
    private func invalidateFrameRunLocked() {
        frameGate.sync { frameToken += 1 }
    }

    private func releaseFrameRunLocked() {
        surfaceContinuation?.finish()
        surfaceContinuation = nil
        frameTask?.cancel()
        frameTask = nil
    }
}
