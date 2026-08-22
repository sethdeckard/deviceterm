// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneAccessibility: the pure accessibility half of `PaneCoordinator`.
//
// Each `pane.ax.*` op is a backend AX read plus `AXTreeAnnotator` /
// `AXSweep` post-processing and JSON serialization; none of it mutates
// `PaneCoordinator`'s pane state. The bridge returns Foundation dicts
// (not Sendable), so serialization happens here synchronously and only
// `Data` (Sendable) crosses back. The coordinator resolves the backend
// (its one stateful step) and reads the pane's immutable `family`, then
// hands both here.

import CoreGraphics
import DaemonProtocol
import Foundation

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
    /// dict shape as `tree` minus the `children` key. `(x, y)` is
    /// normalized in `[0, 1]` (origin top-left); scaled to pixel space
    /// against the frontmost app's screen frame before the bridge call,
    /// since AXPTranslator's `objectAtPoint:` operates in pixel
    /// coordinates (see AXSweep's header note).
    static func element(
        backend: any DeviceBackend,
        queue: BlockingWorkQueue,
        paneId: UUID,
        x: Double,
        y: Double
    ) async throws -> Data {
        try await queue.run {
            try elementSynchronously(backend: backend, paneId: paneId, x: x, y: y)
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
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .axPoint,
                message: "AX bridge unavailable (frontmostTree probe failed): "
                    + BridgeMessage.unwrap(error)
            )
        }
        let screen = AXSweep.screenSize(fromTree: rootTree)
            ?? CGSize(width: 1, height: 1)
        let pixelPoint = AXSweep.pixelPoint(
            normalized: CGPoint(x: x, y: y),
            screen: screen
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
    /// elements. The watchOS workaround for the case where
    /// `accessibilityChildren` enumeration returns empty (the limitation
    /// `AXTreeAnnotator` notes on `ax tree`), agents can still discover
    /// the on-screen elements by sweeping with `objectAtPoint:`.
    /// Result shape mirrors `ax tree`: a synthetic root dict with
    /// `role: "AXSweepRoot"`, normalized full-screen frame, and a
    /// `children` list of unique elements seen. Adds two non-tree
    /// fields the caller can use to size the response: `step` (the
    /// clamped step actually used) and `sweepedPoints` (the grid size).
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
        step: Double?
    ) async throws -> Data {
        try await queue.run {
            try sweepSynchronously(backend: backend, paneId: paneId, step: step)
        }
    }

    private static func sweepSynchronously(
        backend: any DeviceBackend,
        paneId: UUID,
        step: Double?
    ) throws -> Data {
        // Pre-flight: read `frontmostTree()` once to confirm the
        // AX bridge is reachable AND to learn the screen pixel
        // frame the grid scales into. The bridge's
        // `objectAtPointNil` (code 78) wraps two unrelated
        // conditions: "no element at this pixel" (routine on
        // blank canvas) and "AX server unavailable" (systemic).
        // Without this probe, an unavailable bridge would surface
        // as 400 per-cell skips and the sweep would silently
        // return an empty result, losing the retry signal. A
        // successful `frontmostTree` (even one that returns
        // `{children: []}` on watchOS, where the recursive walk
        // is limited) proves the bridge is operational AND
        // exposes the root frame's pixel dimensions.
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
        let screen = AXSweep.screenSize(fromTree: rootTree)
            ?? CGSize(width: 1, height: 1)
        let clampedStep = AXSweep.clampStep(step)
        let points = AXSweep.gridPoints(step: clampedStep)
        var seen = Set<String>()
        var unique: [[String: Any]] = []
        for point in points {
            // Scale normalized grid point into the screen's pixel
            // frame before the bridge call, since AXPTranslator's
            // `objectAtPoint:` works in pixel space. Without this
            // every grid point lands in the sub-pixel `(0,0)`
            // neighborhood and the bridge returns code 78 for all
            // 400 cells.
            let pixelPoint = AXSweep.pixelPoint(
                normalized: point,
                screen: screen
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
                        message: "bridge error at normalized point "
                            + "(\(point.x), \(point.y)) → pixel "
                            + "(\(pixelPoint.x), \(pixelPoint.y)): "
                            + BridgeMessage.unwrap(error)
                    )
                }
            }
            let key = AXSweep.dedupKey(element: element)
            if seen.insert(key).inserted { unique.append(element) }
        }
        let root: [String: Any] = [
            "role": "AXSweepRoot",
            "frame": ["x": 0, "y": 0, "w": 1, "h": 1],
            "children": unique,
            "step": clampedStep,
            "sweepedPoints": points.count
        ]
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
