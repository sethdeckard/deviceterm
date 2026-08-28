// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Foundation

/// The pure accessibility half of `PaneCoordinator`.
///
/// Each `pane.ax.*` op is a backend AX read plus `AXTreeAnnotator` /
/// `AXSweep` post-processing and JSON serialization; none of it mutates
/// `PaneCoordinator`'s pane state. The bridge returns Foundation dicts
/// (not Sendable), so serialization happens here synchronously and only
/// `Data` (Sendable) crosses back. The coordinator resolves the backend
/// (its one stateful step) and hands it here with whatever else the op
/// needs off the record: the pane's immutable `family` for `tree`, a
/// reader for its presentation orientation for `element` and `sweep`.
enum PaneAccessibility {
    /// AXP's callback bridge waits synchronously for each simulator reply.
    /// Keep the whole read and JSON conversion on the pane's serial Dispatch
    /// queue so no non-Sendable Foundation tree crosses the continuation.
    /// Separate panes use separate queues and can make progress independently.

    /// Serialize the frontmost iOS app's accessibility tree to JSON
    /// bytes, annotated for `family`.
    static func tree(
        backend: any DeviceBackend,
        queue: BlockingWorkQueue,
        paneId: UUID,
        family: DeviceFamily
    ) async throws -> Data {
        try await queue.run {
            try treeSynchronously(backend: backend, paneId: paneId, family: family)
        }
    }

    private static func treeSynchronously(
        backend: any DeviceBackend,
        paneId: UUID,
        family: DeviceFamily
    ) throws -> Data {
        let tree: [String: Any]
        do {
            tree = try backend.accessibilityFrontmostTree()
        } catch let error as DeviceBackendError {
            throw PaneError.mapBackendError(error, paneId: paneId, operation: .axTree)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .axTree,
                message: BridgeMessage.unwrap(error)
            )
        }
        let annotated = AXTreeAnnotator.annotate(tree: tree, family: family)
        do {
            return try JSONSerialization.data(
                withJSONObject: annotated,
                options: [.sortedKeys]
            )
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .axTree,
                message: "tree is not JSON-serializable: \(BridgeMessage.unwrap(error))"
            )
        }
    }

    /// Serialize the single AX element at a normalized point. Same
    /// dict shape as `tree` minus the `children` key.
    ///
    /// `(x, y)` is normalized in `[0, 1]` in displayed space, the same
    /// space the coordinate-bearing input verbs take, with the origin at
    /// the top-left of what the device is showing. Mapping it into the
    /// display panel's own frame needs the orientation, because
    /// AXPTranslator's `objectAtPoint:` hit-tests the panel, which never
    /// turns, while the frames in the tree describe the interface, which
    /// does.
    ///
    /// `orientation` is read rather than passed by value, and is read
    /// after the queue wait and after the tree, so it is never an
    /// enqueue-time snapshot: this queue is shared with `sweep`, and a
    /// read can wait on it for as long as a full grid walk takes. The two
    /// reads are not atomic, so a rotation landing between them still
    /// mismatches the tree.
    static func element(
        backend: any DeviceBackend,
        queue: BlockingWorkQueue,
        paneId: UUID,
        orientation: @escaping @Sendable () -> Orientation,
        x: Double,
        y: Double
    ) async throws -> Data {
        try await queue.run {
            try elementSynchronously(
                backend: backend,
                paneId: paneId,
                orientation: orientation,
                x: x,
                y: y
            )
        }
    }

    private static func elementSynchronously(
        backend: any DeviceBackend,
        paneId: UUID,
        orientation: @Sendable () -> Orientation,
        x: Double,
        y: Double
    ) throws -> Data {
        let rootTree: [String: Any]
        do {
            rootTree = try backend.accessibilityFrontmostTree()
        } catch let error as DeviceBackendError {
            throw PaneError.mapBackendError(error, paneId: paneId, operation: .axPoint)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .axPoint,
                message: "AX bridge unavailable (frontmostTree probe failed): "
                    + BridgeMessage.unwrap(error)
            )
        }
        let interface = AXSweep.interfaceSize(fromTree: rootTree)
            ?? CGSize(width: 1, height: 1)
        let pixelPoint = AXSweep.nativePixel(
            displayed: CGPoint(x: x, y: y),
            orientation: orientation(),
            interface: interface
        )
        let element: [String: Any]
        do {
            element = try backend.accessibilityElement(at: pixelPoint)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .axPoint,
                message: BridgeMessage.unwrap(error)
            )
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: element,
                options: [.sortedKeys]
            )
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .axPoint,
                message: "element is not JSON-serializable: \(BridgeMessage.unwrap(error))"
            )
        }
    }

    /// Grid-walk the screen via `elementAtPoint` and aggregate unique
    /// elements. The grid is laid out in displayed space and each point
    /// carried into the panel's frame through the pane's orientation, so
    /// a turned device is swept over its whole screen rather than a
    /// transposed corner of it. The watchOS workaround for the case where
    /// `accessibilityChildren` enumeration returns empty (the limitation
    /// `AXTreeAnnotator` notes on `ax tree`), agents can still discover
    /// the on-screen elements by sweeping with `objectAtPoint:`.
    /// Result shape mirrors `ax tree`: a synthetic root dict with
    /// `role: "AXSweepRoot"`, normalized full-screen frame, and a
    /// `children` list of unique elements seen. Adds four non-tree
    /// fields describing the walk that produced it: `step` (the clamped
    /// step actually used), `budgetMs` (the clamped budget it ran under),
    /// `sweepedPoints` (cells queried), and `truncated`, plus a `note` on
    /// the truncated ones.
    ///
    /// `truncated` is true when an expired deadline stopped the walk before
    /// its next query. That result covers part of the screen, so an element
    /// missing from a truncated sweep is not evidence it isn't there. A grid
    /// that finishes is never truncated, even when its last query ran past
    /// the deadline, because nothing checks after the final cell. A truncated
    /// result also carries one of `AXTreeNote`'s two sweep cases, so a client
    /// that reads only the note vocabulary still learns the coverage is
    /// partial and what it can do about it.
    ///
    /// `budgetMs` is the caller's, clamped by `AXSweepBudget`, defaulted when
    /// they named none. Echoing it back is what makes the clamp visible: a
    /// caller who asked for more than the ceiling can see they didn't get it.
    /// It is a limit, not an elapsed time, and covers the wait for the queue
    /// as well as the walk, so a completed sweep may have used very little of
    /// it. `sweepedPoints` is the measured half of the pair.
    ///
    /// The deadline starts when the request does, so the wait for the
    /// pane's queue spends it, and a request whose deadline went while it
    /// waited answers without touching the bridge at all. It is checked
    /// before the pre-flight and before each cell, which is not the same as
    /// a hard bound: an in-flight bridge call runs to completion, so the
    /// walk can overrun by one.
    ///
    /// Cancellation does not stop it, and not for the reason it looks like.
    /// The walk is dispatched onto a Dispatch queue with no task context,
    /// so `Task.isCancelled` reads false inside it however the request
    /// ended; seeing a cancellation would take a flag raised from
    /// `withTaskCancellationHandler` and polled between cells, and none is
    /// wired. XPC task cancellation therefore doesn't reach this walk, and
    /// a UDS disconnect doesn't cancel its inline handler in the first
    /// place. A client that gives up goes unnoticed until the request ends
    /// on its own. Once the queued closure begins, an expired deadline stops
    /// it starting new bridge calls, but the wait behind earlier queue work
    /// and one in-flight call can still carry the request past `budgetMs`.
    ///
    /// Per-point "no element here" misses are skipped, since sparse AX
    /// coverage (a Canvas + GeometryReader composition with a few
    /// Text nodes scattered across blank pixels) returns the actual
    /// sweep, even if `children` is empty. To preserve the retry
    /// signal for callers when the bridge is genuinely unavailable
    /// (the same `objectAtPointNil` code 78 the bridge raises for
    /// blank pixels), the sweep first probes `frontmostTree()`. A
    /// throw from that probe surfaces as `bridgeFailed` immediately;
    /// a return, even one with `{children: []}` on watchOS where
    /// the recursive walk is limited, proves the bridge is alive
    /// and the per-cell skips are legit. A SYSTEMIC error
    /// mid-sweep (non-code-78) still aborts with `bridgeFailed`
    /// carrying the offending point's coordinates. JSON encoding
    /// failure on the result root also propagates as `bridgeFailed`,
    /// matching how `ax tree` handles the same case.
    static func sweep(
        backend: any DeviceBackend,
        queue: BlockingWorkQueue,
        paneId: UUID,
        orientation: @escaping @Sendable () -> Orientation,
        step: Double?,
        budgetMs: Int?
    ) async throws -> Data {
        let budget = AXSweepBudget.clamp(budgetMs)
        // Started on arrival, not once the walk gets the queue. The queue is
        // serial and shared with every other `ax` read, so waiting for it is
        // most of what a busy pane spends. A deadline taken inside would let
        // a sweep queued behind another run its own full deadline after
        // waiting out that one's, and two fresh deadlines back to back would
        // exceed the CLI's own response wait, which is the failure this
        // bounds.
        let deadline = ContinuousClock.now + .milliseconds(budget)
        return try await queue.run {
            try sweepSynchronously(
                backend: backend,
                paneId: paneId,
                orientation: orientation,
                step: step,
                budgetMs: budget,
                deadline: deadline
            )
        }
    }

    private static func sweepSynchronously(
        backend: any DeviceBackend,
        paneId: UUID,
        orientation: @Sendable () -> Orientation,
        step: Double?,
        budgetMs: Int,
        deadline: ContinuousClock.Instant
    ) throws -> Data {
        // Spent before this reached the queue, so there is nothing left to
        // spend on it. Answered here, ahead of the pre-flight, because that
        // probe is a synchronous bridge call with no bound of its own:
        // making it would hold the pane's queue past the deadline the budget
        // exists to enforce, and the budget is a claim about the whole
        // request, not about the walk alone.
        guard ContinuousClock.now < deadline else {
            return try sweepRoot(
                paneId: paneId,
                step: AXSweep.clampStep(step),
                budgetMs: budgetMs,
                unique: [],
                swept: 0,
                truncated: true
            )
        }
        // Pre-flight: read `frontmostTree()` once to confirm the
        // AX bridge is reachable AND to learn the interface frame
        // the grid maps through. The bridge's
        // `objectAtPointNil` (code 78) wraps two unrelated
        // conditions: "no element at this pixel" (routine on
        // blank canvas) and "AX server unavailable" (systemic).
        // Without this probe, an unavailable bridge would surface
        // as 400 per-cell skips and the sweep would silently
        // return an empty result, losing the retry signal. A
        // successful `frontmostTree` (even one that returns
        // `{children: []}` on watchOS, where the recursive walk
        // is limited) proves the bridge is operational AND
        // exposes the root frame's dimensions.
        let rootTree: [String: Any]
        do {
            rootTree = try backend.accessibilityFrontmostTree()
        } catch let error as DeviceBackendError {
            throw PaneError.mapBackendError(error, paneId: paneId, operation: .axSweep)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .axSweep,
                message: "AX bridge unavailable (frontmostTree probe failed): "
                    + BridgeMessage.unwrap(error)
            )
        }
        let interface = AXSweep.interfaceSize(fromTree: rootTree)
            ?? CGSize(width: 1, height: 1)
        // Read after the tree, not when the request entered the actor, so
        // a rotation while this waited its turn on the queue doesn't map
        // the walk through the previous screen. Two limits remain: the
        // tree and this are separate reads, so a rotation between them
        // still mismatches, and one *during* the walk splits it.
        let orientation = orientation()
        let clampedStep = AXSweep.clampStep(step)
        let points = AXSweep.gridPoints(step: clampedStep)
        var seen = Set<String>()
        var unique: [[String: Any]] = []
        var swept = 0
        var cutShort = false
        for point in points {
            // Before the bridge call rather than after it: a cell started
            // here is a cell the caller waits out. Stopping between cells is
            // safe because a point query holds nothing across the loop,
            // unlike a gesture's contact.
            guard ContinuousClock.now < deadline else {
                cutShort = true
                break
            }
            swept += 1
            // Carry the displayed grid point into the panel frame
            // before the bridge call. AXPTranslator's
            // `objectAtPoint:` works in panel coordinates, so an
            // unscaled point lands in the sub-pixel `(0,0)`
            // neighborhood and every cell returns code 78, and an
            // unrotated one walks the wrong axis in landscape.
            let pixelPoint = AXSweep.nativePixel(
                displayed: point,
                orientation: orientation,
                interface: interface
            )
            let element: [String: Any]
            do {
                element = try backend.accessibilityElement(at: pixelPoint)
            } catch {
                switch AXSweep.classify(error: error) {
                case .skip:
                    // Routine per-cell miss: this pixel sits on a
                    // blank region of the screen (the canvas
                    // between AX nodes, sparse Canvas +
                    // GeometryReader composition, etc). The
                    // pre-flight already proved the bridge is
                    // alive, so this can't be a server-unavailable
                    // throw masquerading as a per-cell outcome.
                    continue

                case .fail:
                    // Systemic bridge failure mid-sweep
                    // (translator went away, device-set lost,
                    // macPlatformElement nil). One bad cell
                    // shouldn't kill the whole sweep silently
                    // Surface the first systemic error so
                    // the caller can retry deliberately.
                    throw PaneError.bridgeFailed(
                        paneId: paneId,
                        operation: .axSweep,
                        message: "bridge error at displayed point "
                            + "(\(point.x), \(point.y)) → panel "
                            + "(\(pixelPoint.x), \(pixelPoint.y)): "
                            + BridgeMessage.unwrap(error)
                    )
                }
            }
            let key = AXSweep.dedupKey(element: element)
            if seen.insert(key).inserted { unique.append(element) }
        }
        return try sweepRoot(
            paneId: paneId,
            step: clampedStep,
            budgetMs: budgetMs,
            unique: unique,
            swept: swept,
            truncated: cutShort
        )
    }

    /// Serializes the same wrapper shape for completed and already-expired
    /// sweeps, so one that never reached the bridge still parses like any
    /// other and differs only in what its fields say.
    private static func sweepRoot(
        paneId: UUID,
        step: Double,
        budgetMs: Int,
        unique: [[String: Any]],
        swept: Int,
        truncated: Bool
    ) throws -> Data {
        var root: [String: Any] = [
            "role": "AXSweepRoot",
            "frame": ["x": 0, "y": 0, "w": 1, "h": 1],
            "children": unique,
            "step": step,
            // The budget this walk ran under, post-clamp, so a caller whose
            // request was held down to the ceiling can tell.
            "budgetMs": budgetMs,
            // Points this walk actually queried, which equals the grid it
            // planned unless `truncated` says it stopped early. Reporting the
            // plan instead would describe coverage the sweep didn't have.
            "sweepedPoints": swept,
            "truncated": truncated
        ]
        // A sweep note follows truncation and the post-clamp budget, not the
        // tree shape and device family `AXTreeAnnotator` reads. The pure
        // selector is what keeps the ceiling case testable without spending
        // the ceiling.
        if truncated {
            root["note"] = AXTreeNote.forTruncatedSweep(budgetMs: budgetMs).rawValue
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys]
            )
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .axSweep,
                message: "sweep root is not JSON-serializable: \(BridgeMessage.unwrap(error))"
            )
        }
    }
}
