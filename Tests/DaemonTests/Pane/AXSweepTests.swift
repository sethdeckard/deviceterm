// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// AXSweep covers the pure pieces of the grid-walk: the grid
// generator (`gridPoints(step:)`), the dedup key (`dedupKey(element:)`),
// the per-cell error classifier (`classify(error:)`), and the
// displayed-to-panel conversion (`interfaceSize(fromTree:)` +
// `geometry(fromTree:)` + `hitTestPoint(displayed:geometry:)`) that carries the
// daemon's normalized RPC surface into the coordinates AXPTranslator's
// `objectAtPoint:` hit-tests. All are unit-testable without a live sim
// because the bridge IPC is a separate concern; the live
// AccessibilityLiveTests in the live track sanity-check the end-to-end
// pipeline, in portrait only.

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

// MARK: - interfaceSize

@Test
func interfaceSizeReadsRootFrameDimensions() {
    // Frontmost-tree shape: a root dict with `frame: {x, y, w, h}` where
    // {w, h} spans the display on iOS/watchOS (apps are fullscreen).
    // `interfaceSize` reads w/h and discards x/y/role/etc.
    let tree: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 184, "h": 224],
        "children": []
    ]
    let size = AXSweep.interfaceSize(fromTree: tree)
    #expect(size == CGSize(width: 184, height: 224))
}

@Test
func interfaceSizeReadsFloatingDimensions() {
    // accessibilityFrame can return CGFloat values (Retina factors,
    // letterboxing math). Pin float handling so a future contract
    // change to integer-only doesn't silently regress.
    let tree: [String: Any] = [
        "frame": ["x": 0.0, "y": 0.0, "w": 393.5, "h": 852.25]
    ]
    let size = AXSweep.interfaceSize(fromTree: tree)
    #expect(size?.width == 393.5)
    #expect(size?.height == 852.25)
}

@Test
func interfaceSizeReadsTheRootFrameInLandscape() {
    // A landscape app reports a wide root frame, and that rectangle is also
    // the space `objectAtPoint:` hit-tests in, so it is read as given.
    let landscape: [String: Any] = [
        "frame": ["x": 0, "y": 0, "w": 874, "h": 402]
    ]
    #expect(AXSweep.interfaceSize(fromTree: landscape) == CGSize(width: 874, height: 402))
}

@Test
func interfaceSizeReturnsNilOnMissingFrame() {
    // If the tree has no frame key at all (degenerate response), the
    // caller can't scale; surfacing nil lets the caller fall back to
    // an identity scale rather than dividing by zero.
    let tree: [String: Any] = ["role": "Application", "children": []]
    #expect(AXSweep.interfaceSize(fromTree: tree) == nil)
}

@Test
func interfaceSizeReturnsNilOnZeroDimensions() {
    // A zero-sized root frame is non-actionable for grid scaling.
    // Treat as "unknown screen" so the caller can pick a safe
    // fallback rather than silently multiplying every grid point by
    // zero (which would land every cell at the origin).
    let zeroW: [String: Any] = ["frame": ["x": 0, "y": 0, "w": 0, "h": 224]]
    let zeroH: [String: Any] = ["frame": ["x": 0, "y": 0, "w": 184, "h": 0]]
    #expect(AXSweep.interfaceSize(fromTree: zeroW) == nil)
    #expect(AXSweep.interfaceSize(fromTree: zeroH) == nil)
}

@Test
func interfaceSizeReturnsNilOnNonFiniteDimensions() {
    // `> 0` does not reject an infinity, and it reaches two places that
    // cannot take one: a hit-test point multiplied by it, and the divisor
    // published beside a normalized centre, where `JSONSerialization`
    // raises rather than returning an error.
    let infiniteW: [String: Any] = ["frame": ["x": 0, "y": 0, "w": Double.infinity, "h": 800]]
    let infiniteH: [String: Any] = ["frame": ["x": 0, "y": 0, "w": 400, "h": Double.infinity]]
    let notANumber: [String: Any] = ["frame": ["x": 0, "y": 0, "w": Double.nan, "h": 800]]
    #expect(AXSweep.interfaceSize(fromTree: infiniteW) == nil)
    #expect(AXSweep.interfaceSize(fromTree: infiniteH) == nil)
    #expect(AXSweep.interfaceSize(fromTree: notANumber) == nil)
    #expect(AXSweep.geometry(fromTree: infiniteW) == nil)
}

// MARK: - hitTestPoint

@Test
func hitTestPointScalesNormalizedIntoTheTreesOwnSpace() {
    // An unturned tree maps straight through: the whole conversion is
    // (normalized × size), the coordinate AXPTranslator expects.
    // Center of a watch screen → midpoints of (184, 224); top-left →
    // origin; near-edge (0.95) → just inside the half-open upper
    // bound `gridPoints` honors.
    // Use approximate equality at the near-edge sample because IEEE
    // 754 multiplication doesn't land on exact tenths (0.95 × 184
    // rounds to 174.79999… and asserting an exact 174.8 would be
    // a false-precision test, not a correctness test).
    let interface = CGSize(width: 184, height: 224)
    let geometry = AXSweep.TreeGeometry(hitTest: interface, viewer: interface)
    #expect(
        AXSweep.hitTestPoint(displayed: CGPoint(x: 0.5, y: 0.5), geometry: geometry)
            == CGPoint(x: 92.0, y: 112.0)
    )
    #expect(AXSweep.hitTestPoint(displayed: .zero, geometry: geometry) == CGPoint.zero)
    let near = AXSweep.hitTestPoint(displayed: CGPoint(x: 0.95, y: 0.95), geometry: geometry)
    #expect(abs(near.x - 174.8) < 0.001)
    #expect(abs(near.y - 212.8) < 0.001)
}

@Test
func hitTestPointHitsKnownWatchOSElement() {
    // Regression cover for the coord-space mismatch: on a 184×224
    // Apple Watch screen, a Text element at pixel frame
    // {x:7, y:63.5, w:78, h:11} sits within the default-grid cell
    // at normalized (0.25, 0.30). Without the scaling step the
    // daemon sends (0.25, 0.30) straight to objectAtPoint as
    // sub-pixel coords near (0,0) and misses every element on
    // every screen. This recomputes the conversion and pins that
    // the scaled pixel does in fact land inside that element's
    // bounding box, so a future regression of the scaling math
    // (or a misclassification of bridge coord-space contract)
    // surfaces here as a clear failure.
    let interface = CGSize(width: 184, height: 224)
    let pixel = AXSweep.hitTestPoint(
        displayed: CGPoint(x: 0.25, y: 0.30),
        geometry: AXSweep.TreeGeometry(hitTest: interface, viewer: interface)
    )
    let element = CGRect(x: 7, y: 63.5, width: 78, height: 11)
    #expect(
        element.contains(pixel),
            "scaled pixel \(pixel) must fall inside \(element)"
        )
}

@Test
func hitTestPointReturnsALandscapeElementToItsOwnFrame() {
    // Measured on an iPad in landscape: the root frame turns with the
    // interface and `objectAtPoint:` hit-tests in that same space, so a
    // frame's centre normalized by the root has to come back inside that
    // frame.
    let root = CGSize(width: 1_210, height: 834)
    let element = CGRect(x: 232, y: 298, width: 100, height: 24)
    let centre = CGPoint(x: element.midX / root.width, y: element.midY / root.height)
    let point = AXSweep.hitTestPoint(
        displayed: centre,
        geometry: AXSweep.TreeGeometry(hitTest: root, viewer: root)
    )
    #expect(element.contains(point), "\(point) must fall inside \(element)")
}

@Test
func hitTestPointTurnsAFoldableInnerPanelIntoItsHitSpace() {
    // Measured on an unfolded iPhone Duo: the root reports 669x951 while the
    // children lay out 951x669, and `Button|About` centred at (691, 373) in
    // that child space hit-tests back to itself only at (373, 951 - 691).
    let geometry = AXSweep.TreeGeometry(
        hitTest: CGSize(width: 669, height: 951),
        viewer: CGSize(width: 951, height: 669)
    )
    let about = CGPoint(x: 691, y: 373)
    let point = AXSweep.hitTestPoint(
        displayed: CGPoint(x: about.x / 951, y: about.y / 669),
        geometry: geometry
    )
    #expect(abs(point.x - about.y) < 0.001)
    #expect(abs(point.y - (951 - about.x)) < 0.001)
}

@Test
func geometryTellsATurnedTreeFromAPartlyFilledOne() {
    // Turned: the children overflow the root's width and fit its height.
    let turned: [String: Any] = [
        "frame": ["x": 0, "y": 0, "w": 669, "h": 951],
        "children": [["frame": ["x": 0, "y": 0, "w": 951, "h": 669]]]
    ]
    #expect(AXSweep.geometry(fromTree: turned)?.viewer == CGSize(width: 951, height: 669))
    #expect(AXSweep.geometry(fromTree: turned)?.isTurned == true)

    // Content that scrolls past the visible height is still turned: only the
    // width is matched, because a long list overruns the other axis.
    let scrolled: [String: Any] = [
        "frame": ["x": 0, "y": 0, "w": 669, "h": 951],
        "children": [["frame": ["x": 0, "y": 0, "w": 951, "h": 1_400]]]
    ]
    #expect(AXSweep.geometry(fromTree: scrolled)?.isTurned == true)

    // Wider than the root but not matching its height: a sideways-scrolling
    // view, not a turn.
    let sideways: [String: Any] = [
        "frame": ["x": 0, "y": 0, "w": 669, "h": 951],
        "children": [["frame": ["x": 0, "y": 0, "w": 1_500, "h": 400]]]
    ]
    #expect(AXSweep.geometry(fromTree: sideways)?.isTurned == false)

    // A dialog over a full-screen app fills less than the root, which is not
    // a quarter turn and must not be read as one.
    let partial: [String: Any] = [
        "frame": ["x": 0, "y": 0, "w": 669, "h": 951],
        "children": [["frame": ["x": 100, "y": 400, "w": 300, "h": 200]]]
    ]
    #expect(AXSweep.geometry(fromTree: partial)?.isTurned == false)
    #expect(AXSweep.geometry(fromTree: partial)?.viewer == CGSize(width: 669, height: 951))
}

@Test("a displayed edge stays inside the hit-test rectangle", arguments: [
    AXSweep.TreeGeometry(
        hitTest: CGSize(width: 402, height: 874),
        viewer: CGSize(width: 402, height: 874)
    ),
    AXSweep.TreeGeometry(
        hitTest: CGSize(width: 669, height: 951),
        viewer: CGSize(width: 951, height: 669)
    )
])
func hitTestPointKeepsTheFarEdgeAddressable(geometry: AXSweep.TreeGeometry) {
    // A caller may supply displayed 1.0, and turning a sampled zero edge can
    // reach the far hit-test boundary too. That boundary is one past the last
    // coordinate any frame contains, so unclamped it would hit nothing.
    let rectangle = CGRect(origin: .zero, size: geometry.hitTest)
    for displayed in [
        CGPoint.zero,
        CGPoint(x: 0.5, y: 0),
        CGPoint(x: 0, y: 0.5),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1)
    ] {
        let point = AXSweep.hitTestPoint(displayed: displayed, geometry: geometry)
        #expect(
            rectangle.contains(point),
            "displayed \(displayed) landed at \(point), outside \(rectangle)"
        )
    }
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
