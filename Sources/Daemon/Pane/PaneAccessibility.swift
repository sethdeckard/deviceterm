// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
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
/// needs off the record: the pane's immutable `family` for `tree`.
///
/// Accessibility takes no orientation. It is asked in the tree's own space,
/// which turns with the interface, so the panel rotation the input verbs
/// apply has no place here.
enum PaneAccessibility {
    /// AXP's callback bridge waits synchronously for each simulator reply.
    /// Keep the whole read and JSON conversion on the pane's serial Dispatch
    /// queue so no non-Sendable Foundation tree crosses the continuation.
    /// Separate panes use separate queues and can make progress independently.

    /// Serialize the frontmost iOS app's accessibility tree to JSON
    /// bytes, annotated for `family`.
    ///
    static func tree(
        backend: any DeviceBackend,
        queue: BlockingWorkQueue,
        paneId: UUID,
        family: DeviceFamily
    ) async throws -> Data {
        try await queue.run {
            try treeSynchronously(
                backend: backend,
                paneId: paneId,
                family: family
            )
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
            throw frontmostFailure(
                error,
                paneId: paneId,
                operation: .axTree,
                message: BridgeMessage.unwrap(error)
            )
        }
        let noted = AXTreeAnnotator.annotate(
            tree: tree,
            family: family,
            probedElement: probeForOmittedElement(
                backend: backend,
                tree: tree,
                family: family
            )
        )
        var annotated = AXCoordinateAnnotator.tree(noted)
        // The divisor, beside the root's own rectangle rather than instead of
        // it. The two are the same number on every device whose tree is not
        // turned a quarter from its own root, and on one that is, the root
        // rectangle is not what the centres below it were made with.
        if let rootFrame = AXCoordinateAnnotator.rootFrame(of: noted) {
            annotated["rootFrame"] = rootFrame
        }
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

    /// Hit-test the one point `AXTreeAnnotator` nominates, so it can tell a
    /// tree that is thin because the screen is from one that is thin because
    /// the walk stopped short. Returns evidence the caller may annotate with,
    /// or nil when there was no point worth asking about, nothing was there,
    /// or the finding did not survive confirmation.
    ///
    /// Failures are absorbed rather than raised. `objectAtPointNil` is the
    /// bridge's routine "nothing here" and it shares a code with a systemic
    /// fault, and the probe is advisory: one that could turn a successful
    /// tree read into `bridgeFailed` would trade the verb for a hint.
    ///
    /// A screen whose tree covers the sample point spends nothing. One that
    /// does not spends a hit-test, and spends a second tree read only when
    /// that hit-test is about to become a claim.
    private static func probeForOmittedElement(
        backend: any DeviceBackend,
        tree: [String: Any],
        family: DeviceFamily
    ) -> [String: Any]? {
        guard let probe = AXTreeAnnotator.probePoint(for: tree, family: family) else { return nil }
        let geometry = AXSweep.geometry(fromTree: tree)
            ?? AXSweep.TreeGeometry(
                hitTest: CGSize(width: 1, height: 1),
                viewer: CGSize(width: 1, height: 1)
            )
        let pixelPoint = AXSweep.hitTestPoint(displayed: probe, geometry: geometry)
        guard let element = try? backend.accessibilityElement(at: pixelPoint),
            AXTreeAnnotator.provesIncompleteness(element, of: tree)
        else { return nil }
        // The tree and the hit-test are separate bridge calls. This queue
        // keeps DeviceTerm's own reads in order but cannot hold the app
        // still, so a transition between the two answers about a screen the
        // tree never described, and annotating then makes a claim about the
        // wrong one.
        //
        // Re-read and require the tree to be unchanged. Asking only whether
        // the element is missing from the second tree too is not enough: a
        // move from a complete screen to an incomplete one satisfies that and
        // still annotates the complete screen. What has to hold is that the
        // walk and the hit-test describe the same moment, and an identical
        // tree is the evidence for it.
        //
        // Paid only here, on the path that is about to assert something. Any
        // change at all withdraws the finding, including a clock tick or an
        // animation, which is the direction to fail in: a withdrawn finding
        // leaves the response unannotated, and a note on a healthy screen
        // sends a caller to a sweep it does not need.
        guard let confirmation = try? backend.accessibilityFrontmostTree(),
            (confirmation as NSDictionary) == (tree as NSDictionary)
        else { return nil }
        return element
    }

    /// Serialize the single AX element at a normalized point. Same dict shape
    /// as a `tree` root minus the `children` key. `rootFrame` carries the
    /// pre-flight screen frame this element's `normalizedCenter` was divided
    /// by, omitted when that root carried no usable frame.
    ///
    /// `(x, y)` is normalized in `[0, 1]` in displayed space, the same
    /// space the coordinate-bearing input verbs take, with the origin at
    /// the top-left of what the device is showing. It is mapped through the
    /// tree's own geometry: AXPTranslator's `objectAtPoint:` hit-tests in the
    /// space of the root frame, which turns with the interface, so the point
    /// needs no rotation into the panel. On a device whose children lay out
    /// turned from that root, a foldable's inner panel so far, the mapping
    /// carries the quarter turn.
    ///
    static func element(
        backend: any DeviceBackend,
        queue: BlockingWorkQueue,
        paneId: UUID,
        x: Double,
        y: Double
    ) async throws -> Data {
        try await queue.run {
            try elementSynchronously(
                backend: backend,
                paneId: paneId,
                x: x,
                y: y
            )
        }
    }

    private static func elementSynchronously(
        backend: any DeviceBackend,
        paneId: UUID,
        x: Double,
        y: Double
    ) throws -> Data {
        let rootTree: [String: Any]
        do {
            rootTree = try backend.accessibilityFrontmostTree()
        } catch let error as DeviceBackendError {
            throw PaneError.mapBackendError(error, paneId: paneId, operation: .axPoint)
        } catch {
            throw frontmostFailure(
                error,
                paneId: paneId,
                operation: .axPoint,
                message: "AX bridge unavailable (frontmostTree probe failed): "
                    + BridgeMessage.unwrap(error)
            )
        }
        let geometry = AXSweep.geometry(fromTree: rootTree)
            ?? AXSweep.TreeGeometry(
                hitTest: CGSize(width: 1, height: 1),
                viewer: CGSize(width: 1, height: 1)
            )
        let pixelPoint = AXSweep.hitTestPoint(
            displayed: CGPoint(x: x, y: y),
            geometry: geometry
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
        var annotated = AXCoordinateAnnotator.element(element, rootTree: rootTree)
        // The frame this element's `normalizedCenter` was divided by, from the
        // same pre-flight read rather than from a second one the caller would
        // have to issue and could not line up with this one.
        if let rootFrame = AXCoordinateAnnotator.rootFrame(of: rootTree) {
            annotated["rootFrame"] = rootFrame
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: annotated,
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
    /// mapped into the hit-test space derived from the pre-flight tree, with
    /// a quarter turn applied when that tree's geometry calls for one, so a
    /// turned device is swept over its whole screen rather than a transposed
    /// corner of it. The watchOS workaround for the case where
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
    /// A fifth non-tree field, `rootFrame`, describes the screen instead of
    /// the walk: the pre-flight frame each child's `normalizedCenter` was
    /// divided by, so a caller can carry one back to displayed points. It is
    /// omitted whenever the pre-flight produced no usable frame, including a
    /// sweep that expired before the pre-flight ran at all.
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
                step: step,
                budgetMs: budget,
                deadline: deadline
            )
        }
    }

    private static func sweepSynchronously(
        backend: any DeviceBackend,
        paneId: UUID,
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
                // No pre-flight ran, so there is no screen frame to report.
                rootFrame: nil,
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
            throw frontmostFailure(
                error,
                paneId: paneId,
                operation: .axSweep,
                message: "AX bridge unavailable (frontmostTree probe failed): "
                    + BridgeMessage.unwrap(error)
            )
        }
        let geometry = AXSweep.geometry(fromTree: rootTree)
            ?? AXSweep.TreeGeometry(
                hitTest: CGSize(width: 1, height: 1),
                viewer: CGSize(width: 1, height: 1)
            )
        // The geometry comes from this tree, so the walk and the hit-tests
        // agree by construction. A screen that turns *during* the walk still
        // splits it: the grid keeps mapping through the tree it started with.
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
            // Map the displayed grid point into the hit-test space
            // before the bridge call. AXPTranslator's
            // `objectAtPoint:` works in that space, so an unscaled
            // point lands in the sub-pixel `(0,0)` neighborhood and
            // every cell returns code 78.
            let pixelPoint = AXSweep.hitTestPoint(displayed: point, geometry: geometry)
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
        let annotated = unique.map {
            AXCoordinateAnnotator.element($0, rootTree: rootTree)
        }
        return try sweepRoot(
            paneId: paneId,
            step: clampedStep,
            budgetMs: budgetMs,
            rootFrame: AXCoordinateAnnotator.rootFrame(of: rootTree),
            unique: annotated,
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
        rootFrame: [String: Double]?,
        unique: [[String: Any]],
        swept: Int,
        truncated: Bool
    ) throws -> Data {
        var root: [String: Any] = [
            "role": "AXSweepRoot",
            // Normalized, and deliberately not the screen: this root is
            // synthetic and spans the grid the walk laid out. `rootFrame`
            // carries the screen's own measurements.
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
        // Absent rather than defaulted. A synthesized `{w: 1, h: 1}` reads
        // exactly like a genuine 1x1 screen, so it would hide the one thing
        // the caller needs to know here, which is that no usable frame was
        // available: either the pre-flight never ran, or what it read could
        // not be published.
        if let rootFrame {
            root["rootFrame"] = rootFrame
        }
        // A sweep note follows truncation and the post-clamp budget, not the
        // tree shape and device family `AXTreeAnnotator` reads. The pure
        // selector is what keeps the ceiling case testable without spending
        // the ceiling.
        if truncated {
            // `note` is the sentence a human reads; `noteCode` is the token a
            // client branches on. The two truncation notes differ only in
            // prose, so without the token a caller deciding whether a larger
            // budget is worth asking for has to match a paragraph.
            let note = AXTreeNote.forTruncatedSweep(budgetMs: budgetMs)
            root["note"] = note.rawValue
            root["noteCode"] = note.code
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

    /// Map a failed `frontmostTree` read. A nil frontmost application is
    /// treated as retryable because it can occur during simulator startup.
    /// Other failures map to `bridgeFailed`.
    static func frontmostFailure(
        _ error: Error,
        paneId: UUID,
        operation: PaneOperation,
        message: String
    ) -> PaneError {
        let nsError = error as NSError
        if nsError.domain == SimAccessibilityErrorDomain,
            nsError.code == SimAccessibilityErrorCode.frontmostNil.rawValue {
            return .accessibilityNotReady(paneId: paneId, operation: operation, message: message)
        }
        return .bridgeFailed(paneId: paneId, operation: operation, message: message)
    }
}
