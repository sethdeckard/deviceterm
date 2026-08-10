// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
@testable import Daemon
import Foundation
import Testing

// AXSweep covers the pure pieces of the grid-walk: the grid
// generator (`gridPoints(step:)`), the dedup key (`dedupKey(element:)`),
// the per-cell error classifier (`classify(error:)`), and the
// normalized-to-pixel conversion (`screenSize(fromTree:)` +
// `pixelPoint(normalized:screen:)`) that bridges the daemon's
// normalized RPC surface to AXPTranslator's pixel-space
// `objectAtPoint:`. All are unit-testable without a live sim because
// the bridge IPC is a separate concern; the live AccessibilityLiveTests
// in the live track sanity-check the end-to-end pipeline.

// MARK: - clampStep

@Test
func clampsBelowMinimumToMinimum() {
    #expect(AXSweep.clampStep(0) == AXSweep.minStep)
    #expect(AXSweep.clampStep(-1) == AXSweep.minStep)
    #expect(AXSweep.clampStep(AXSweep.minStep / 2) == AXSweep.minStep)
}

@Test
func clampsAboveMaximumToMaximum() {
    #expect(AXSweep.clampStep(1.0) == AXSweep.maxStep)
    #expect(AXSweep.clampStep(100) == AXSweep.maxStep)
}

@Test
func nilStepReturnsDefault() {
    #expect(AXSweep.clampStep(nil) == AXSweep.defaultStep)
}

@Test
func nonFiniteStepReturnsDefault() {
    #expect(AXSweep.clampStep(.nan) == AXSweep.defaultStep)
    #expect(AXSweep.clampStep(.infinity) == AXSweep.defaultStep)
}

@Test
func inRangeStepPassesThrough() {
    #expect(AXSweep.clampStep(0.05) == 0.05)
    #expect(AXSweep.clampStep(0.1) == 0.1)
    #expect(AXSweep.clampStep(0.25) == 0.25)
}

// MARK: - gridPoints

@Test
func gridIsRowMajorAndAnchorsAtZero() {
    let points = AXSweep.gridPoints(step: 0.5)
    // step 0.5 → samples at 0.0 and 0.5 on each axis; (0,0) (0.5,0)
    // (0,0.5) (0.5,0.5). Row-major (y fixed per row).
    #expect(
        points == [
        CGPoint.zero,
        CGPoint(x: 0.5, y: 0),
        CGPoint(x: 0, y: 0.5),
        CGPoint(x: 0.5, y: 0.5)
        ]
        )
}

@Test
func gridExcludesUpperBound() {
    // Bridge's normalized space is half-open at 1.0; sweep must
    // never emit a point at exactly 1.0 on either axis.
    let points = AXSweep.gridPoints(step: 0.5)
    for point in points {
        #expect(point.x < 1.0)
        #expect(point.y < 1.0)
    }
}

@Test
func gridSizeMatchesStep() {
    // step 0.25 → 4 samples per axis (0, 0.25, 0.5, 0.75) → 16 cells.
    #expect(AXSweep.gridPoints(step: 0.25).count == 16)
    // step 0.1 → 10 per axis → 100 cells.
    #expect(AXSweep.gridPoints(step: 0.1).count == 100)
}

@Test
func gridForDefaultStepFitsBudget() {
    // Sanity bound on the default: 0.05 step → 20×20 = 400 cells.
    // At ~5ms per bridge call that's ~2s end-to-end, within the
    // CLI's 30s timeout but worth pinning so a future default
    // change doesn't accidentally bloat the wire cost.
    let points = AXSweep.gridPoints(step: AXSweep.defaultStep)
    #expect(points.count == 400)
}

@Test
func gridAtMinStepFitsBoundedBudget() {
    // The whole point of `minStep`: even when the caller asks for
    // an absurd step, the resulting grid stays bounded. A 50×50
    // grid is the worst case; ~12s sweep at typical bridge cost,
    // already past most CLI timeouts but recoverable. Without this
    // floor, `--step 0.001` would generate a million bridge calls
    // and monopolize the PaneCoordinator actor for tens of minutes.
    let absurdRequest = AXSweep.gridPoints(step: 0.0001)
    let atFloor = AXSweep.gridPoints(step: AXSweep.minStep)
    #expect(absurdRequest.count == atFloor.count)
    // 50×50 = 2500 cells is the documented cap; assert it directly
    // so any future loosening of `minStep` is a deliberate change
    // with this test as the speed bump.
    #expect(atFloor.count <= 2_500)
}

// MARK: - screenSize

@Test
func screenSizeReadsRootFrameDimensions() {
    // Frontmost-tree shape: a root dict with `frame: {x, y, w, h}` where
    // {w, h} is the screen pixel size on iOS/watchOS (apps are
    // fullscreen). `screenSize` reads w/h and discards x/y/role/etc.
    let tree: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 184, "h": 224],
        "children": []
    ]
    let size = AXSweep.screenSize(fromTree: tree)
    #expect(size == CGSize(width: 184, height: 224))
}

@Test
func screenSizeReadsFloatingDimensions() {
    // accessibilityFrame can return CGFloat values (Retina factors,
    // letterboxing math). Pin float handling so a future contract
    // change to integer-only doesn't silently regress.
    let tree: [String: Any] = [
        "frame": ["x": 0.0, "y": 0.0, "w": 393.5, "h": 852.25]
    ]
    let size = AXSweep.screenSize(fromTree: tree)
    #expect(size?.width == 393.5)
    #expect(size?.height == 852.25)
}

@Test
func screenSizeReturnsNilOnMissingFrame() {
    // If the tree has no frame key at all (degenerate response), the
    // caller can't scale; surfacing nil lets the caller fall back to
    // an identity scale rather than dividing by zero.
    let tree: [String: Any] = ["role": "Application", "children": []]
    #expect(AXSweep.screenSize(fromTree: tree) == nil)
}

@Test
func screenSizeReturnsNilOnZeroDimensions() {
    // A zero-sized root frame is non-actionable for grid scaling.
    // Treat as "unknown screen" so the caller can pick a safe
    // fallback rather than silently multiplying every grid point by
    // zero (which would land every cell at the origin).
    let zeroW: [String: Any] = ["frame": ["x": 0, "y": 0, "w": 0, "h": 224]]
    let zeroH: [String: Any] = ["frame": ["x": 0, "y": 0, "w": 184, "h": 0]]
    #expect(AXSweep.screenSize(fromTree: zeroW) == nil)
    #expect(AXSweep.screenSize(fromTree: zeroH) == nil)
}

// MARK: - pixelPoint

@Test
func pixelPointScalesNormalizedToScreen() {
    // The load-bearing identity: (norm * size) is the pixel coord
    // AXPTranslator expects. Center of a watch screen → midpoints
    // of (184, 224); top-left → origin; near-edge (0.95) → just
    // inside the half-open upper bound `gridPoints` honors.
    // Use approximate equality at the near-edge sample because IEEE
    // 754 multiplication doesn't land on exact tenths (0.95 × 184
    // rounds to 174.79999… and asserting an exact 174.8 would be
    // a false-precision test, not a correctness test).
    let screen = CGSize(width: 184, height: 224)
    #expect(
        AXSweep.pixelPoint(
        normalized: CGPoint(x: 0.5, y: 0.5),
        screen: screen
    ) == CGPoint(x: 92.0, y: 112.0)
        )
    #expect(
        AXSweep.pixelPoint(
        normalized: CGPoint.zero,
        screen: screen
    ) == CGPoint.zero
        )
    let near = AXSweep.pixelPoint(
        normalized: CGPoint(x: 0.95, y: 0.95),
        screen: screen
    )
    #expect(abs(near.x - 174.8) < 0.001)
    #expect(abs(near.y - 212.8) < 0.001)
}

@Test
func pixelPointHitsKnownWatchOSElement() {
    // Regression cover for the coord-space mismatch: on a 184×224
    // Apple Watch screen, a Text element at pixel frame
    // {x:7, y:63.5, w:78, h:11} sits within the default-grid cell
    // at normalized (0.25, 0.30). Without the scaling fix the
    // daemon sent (0.25, 0.30) straight to objectAtPoint as
    // sub-pixel coords near (0,0) and missed every element on
    // every screen. This recomputes the conversion and pins that
    // the scaled pixel does in fact land inside that element's
    // bounding box, so a future regression of the scaling math
    // (or a misclassification of bridge coord-space contract)
    // surfaces here as a clear failure.
    let screen = CGSize(width: 184, height: 224)
    let pixel = AXSweep.pixelPoint(
        normalized: CGPoint(x: 0.25, y: 0.30),
        screen: screen
    )
    let element = CGRect(x: 7, y: 63.5, width: 78, height: 11)
    #expect(
        element.contains(pixel),
            "scaled pixel \(pixel) must fall inside \(element)"
        )
}

// MARK: - dedupKey

@Test
func dedupKeyCollapsesIdenticalElements() {
    let one: [String: Any] = [
        "role": "Button",
        "identifier": "submit",
        "label": "Submit",
        "frame": ["x": 10, "y": 20, "w": 100, "h": 44]
    ]
    let two: [String: Any] = [
        "role": "Button",
        "identifier": "submit",
        "label": "Submit",
        "frame": ["x": 10, "y": 20, "w": 100, "h": 44]
    ]
    #expect(AXSweep.dedupKey(element: one) == AXSweep.dedupKey(element: two))
}

@Test
func dedupKeyDistinguishesByRole() {
    let one: [String: Any] = ["role": "Button", "frame": ["x": 0, "y": 0, "w": 1, "h": 1]]
    let two: [String: Any] = ["role": "StaticText", "frame": ["x": 0, "y": 0, "w": 1, "h": 1]]
    #expect(AXSweep.dedupKey(element: one) != AXSweep.dedupKey(element: two))
}

@Test
func dedupKeyDistinguishesByFrame() {
    let one: [String: Any] = ["role": "Button", "frame": ["x": 0, "y": 0, "w": 10, "h": 10]]
    let two: [String: Any] = ["role": "Button", "frame": ["x": 0, "y": 0, "w": 20, "h": 20]]
    #expect(AXSweep.dedupKey(element: one) != AXSweep.dedupKey(element: two))
}

@Test
func dedupKeyDistinguishesByIdentifier() {
    let one: [String: Any] = [
        "role": "Button",
        "identifier": "save",
        "frame": ["x": 0, "y": 0, "w": 1, "h": 1]
    ]
    let two: [String: Any] = [
        "role": "Button",
        "identifier": "cancel",
        "frame": ["x": 0, "y": 0, "w": 1, "h": 1]
    ]
    #expect(AXSweep.dedupKey(element: one) != AXSweep.dedupKey(element: two))
}

@Test
func dedupKeyTreatsMissingFieldsAsEmpty() {
    // Bridge's `_populate` omits empty strings entirely; the dedup
    // key normalizes missing → "" so a dict without `identifier`
    // matches a dict with `identifier: ""`.
    let without: [String: Any] = ["role": "Button", "frame": ["x": 0, "y": 0, "w": 1, "h": 1]]
    let withEmpty: [String: Any] = [
        "role": "Button",
        "identifier": "",
        "label": "",
        "frame": ["x": 0, "y": 0, "w": 1, "h": 1]
    ]
    #expect(AXSweep.dedupKey(element: without) == AXSweep.dedupKey(element: withEmpty))
}

// MARK: - classify

@Test
func classifyObjectAtPointNilAsSkip() {
    // The bridge raises `code 78` in
    // `SimAccessibilityErrorDomain` for every grid point that hits
    // blank pixels. Pinned as `.skip` so the sweep keeps walking
    // and finding zero elements overall is a legitimate result
    // (sparse Canvas + GeometryReader composition), not a
    // bridge failure.
    let error = NSError(
        domain: SimAccessibilityErrorDomain,
        code: SimAccessibilityErrorCode.objectAtPointNil.rawValue,
        userInfo: nil
    )
    #expect(AXSweep.classify(error: error) == .skip)
}

@Test
func classifyOtherBridgeCodeAsFail() {
    // Any other code from the AX bridge (AXP load failure,
    // translator missing, device-not-found, …) is systemic. The
    // sweep aborts so the caller can retry deliberately rather
    // than burning ~400 cells against a broken bridge.
    for code in [70, 73, 76, 77, 79] {
        let error = NSError(
            domain: SimAccessibilityErrorDomain,
            code: code,
            userInfo: nil
        )
        #expect(
            AXSweep.classify(error: error) == .fail,
                "code \(code) should classify as fail"
            )
    }
}

@Test
func classifyForeignDomainAsFail() {
    // Defensive: an NSError carrying code 78 from a different
    // domain isn't the bridge's "no element at point"; it's
    // some other layer leaking through. Treat as systemic so a
    // future error layer can't accidentally degrade the sweep
    // into a silent skip on its own (genuine) failures.
    let error = NSError(
        domain: "Some.Other.Module",
        code: SimAccessibilityErrorCode.objectAtPointNil.rawValue,
        userInfo: nil
    )
    #expect(AXSweep.classify(error: error) == .fail)
}
