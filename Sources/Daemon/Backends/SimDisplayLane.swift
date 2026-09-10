// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// The simulator display handle and everything whose lifetime is tied to it:
/// the frame run, its pump task, and the orientation observation.
///
/// The lane queue serializes display-handle lifecycle operations so starts,
/// stops, dimension reads, and orientation registration cannot race teardown.
/// Both the synchronous accessors and the async operations use that one queue,
/// which is why it is a bare `DispatchQueue` rather than a `BlockingWorkQueue`:
/// the serialization has to cover both, and that type offers no sync entry.
///
/// `frameGate` stays separate and deliberately small. Publish and fatal
/// callbacks run from the frame pump and check their run token under
/// `frameGate`, so they do not wait behind lane work. Retiring the token is on
/// `frameGate` alone for the same reason: teardown can fence callbacks without
/// first queueing behind whatever the lane is doing.
///
/// `@unchecked Sendable`: `SimDisplayHandle` is not Sendable, and every access
/// to it happens on `queue`. The `Locked` helpers assume they are already on
/// that queue, so none of them may hop back onto it and deadlock.
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

    /// Whether the handle is still held. False once teardown has released it,
    /// which is what makes a post-teardown call answer rather than reach a dead
    /// bridge object.
    var isActive: Bool { queue.sync { handle != nil } }

    init(handle: SimDisplayHandle, pool: LeasedSurfacePool, recoveryThreshold: Int) {
        self.handle = handle
        self.pool = pool
        self.recoveryThreshold = recoveryThreshold
    }

    // MARK: - Bootstrap

    /// Start frames, install orientation observation, and read the seed
    /// orientation and pixel dimensions, in one trip down the queue.
    ///
    /// One operation rather than four calls because each is a CoreSimulator
    /// round trip: batching them gives the caller a single suspension to fence
    /// and a single place to bound. Nothing here is cancellable, so a caller
    /// that gives up needs `DisplayBootstrapSupervisor` to account for the
    /// abandoned attempt.
    ///
    /// Throws only if frames cannot start. A display with no orientation source
    /// reports `observingOrientation: false` and leaves the pane usable.
    func bootstrap(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onOrientation: @escaping @Sendable (Orientation) -> Void
    ) async throws -> DisplayBootstrap {
        try await runOnQueue { [self] in
            try startFramesLocked(onFrame: onFrame, onFatal: onFatal)
            let observing = startOrientationLocked(onChange: onOrientation)
            let dimensions = pixelDimensionsLocked()
            return DisplayBootstrap(
                pixelWidth: dimensions.0,
                pixelHeight: dimensions.1,
                seedOrientation: currentOrientationLocked(),
                observingOrientation: observing
            )
        }
    }

    /// Stop the frame stream and drop the handle, off the caller's executor.
    ///
    /// The run token retires *before* the wait, so a publish already in flight
    /// is fenced immediately rather than only once the queue drains. Retirement
    /// depends on this completing, so it is deliberately not fire-and-forget.
    func shutdownAsync() async {
        invalidateFrameRun()
        await runOnQueue { [self] in shutdownLocked() }
    }

    // MARK: - Frames

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws {
        try queue.sync { try startFramesLocked(onFrame: onFrame, onFatal: onFatal) }
    }

    func stopFrames() {
        invalidateFrameRun()
        queue.sync {
            invalidateFrameRun()
            handle?.stop()
            releaseFrameRunLocked()
        }
    }

    func pixelDimensions() -> (Int?, Int?) { queue.sync { pixelDimensionsLocked() } }

    // MARK: - Display orientation

    func startOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool {
        queue.sync { startOrientationLocked(onChange: onChange) }
    }

    func stopOrientation() { queue.sync { handle?.stopOrientation() } }

    func currentOrientation() -> Orientation? { queue.sync { currentOrientationLocked() } }

    // MARK: - Lifecycle

    func shutdown() {
        invalidateFrameRun()
        queue.sync { shutdownLocked() }
    }

    /// Retire the current frame run so any publish or fatal still in flight from
    /// it is dropped. Serialised with the callbacks on `frameGate`, and
    /// deliberately not on `queue`: fencing must not wait for lane work.
    ///
    /// Teardown calls this twice, and both calls are needed. The first fences
    /// the run that exists now, without waiting for the lane. The second runs
    /// once teardown is ordered on the lane, because a start that won the queue
    /// in between installed a *newer* token that the first bump did not retire.
    /// Cancelling the pump task does not close that gap: cancellation is not a
    /// join, so a publish already in flight still checks the token.
    func invalidateFrameRun() {
        frameGate.sync { frameToken += 1 }
    }

    // MARK: - Queue-local work

    private func runOnQueue<Value: Sendable>(
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

    private func runOnQueue(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private func startFramesLocked(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws {
        guard let handle else { throw DeviceBackendError.notActive }
        let pool = self.pool
        let recoveryThreshold = self.recoveryThreshold
        // Install a fresh run token; teardown bumps it to fence late callbacks.
        // Checked and invoked together under `frameGate`, so teardown and a
        // publish are mutually ordered with no window between them.
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
        // The callback fires on the bridge's own queue and must not block it,
        // so it only hands the surface over. Latest-only: the pump copies at
        // whatever rate the pool allows, and an older frame waiting behind a
        // newer one has no value on a mirror.
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
        // Wrap on the bridge's queue so the retain/use-count pairing happens
        // before the autoreleased source ref escapes.
        do {
            try handle.start { surfaceRef in
                guard let surfaceRef else { return }
                continuation.yield(RetainedSurface(surfaceRef))
            }
        } catch {
            // The continuation and pump task are already installed above, so a
            // throw here would leave them running against a stream nothing
            // feeds. Retire this run before handing the error back.
            frameGate.sync { frameToken += 1 }
            releaseFrameRunLocked()
            throw error
        }
    }

    private func startOrientationLocked(
        onChange: @escaping @Sendable (Orientation) -> Void
    ) -> Bool {
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
            // If orientation observation cannot start, leave the pane on its
            // last known orientation. Frames are unaffected, so the pane
            // remains usable.
            return false
        }
    }

    private func pixelDimensionsLocked() -> (Int?, Int?) {
        guard let handle else { return (nil, nil) }
        let size = handle.displaySize
        guard size.width > 0, size.height > 0 else { return (nil, nil) }
        return (Int(size.width), Int(size.height))
    }

    private func currentOrientationLocked() -> Orientation? {
        guard let handle else { return nil }
        return Orientation(displayValue: handle.currentDisplayOrientation)
    }

    /// Stop the frame stream and drop the handle. The IOSurface use-count must
    /// release so the kernel can reclaim it.
    private func shutdownLocked() {
        invalidateFrameRun()
        // Unregisters orientation observation too: the coordinator fences its
        // pump locally and leaves this bridge call to teardown, which runs off
        // the caller's executor.
        handle?.stopOrientation()
        handle?.stop()
        handle = nil
        releaseFrameRunLocked()
    }

    private func releaseFrameRunLocked() {
        surfaceContinuation?.finish()
        surfaceContinuation = nil
        frameTask?.cancel()
        frameTask = nil
    }
}
