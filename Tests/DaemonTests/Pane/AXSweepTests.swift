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
// `nativeSize(interface:orientation:)` +
// `nativePixel(displayed:orientation:interface:)`) that carries the
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
func interfaceSizeReportsTheTurnedInterfaceNotThePanel() {
    // A landscape app reports a wide root frame while the panel
    // underneath stays portrait, so this value is the interface's size
    // and not the panel's. Anything that scales by it without asking
    // `nativeSize` first divides each axis by the other one's length.
    let landscape: [String: Any] = [
        "frame": ["x": 0, "y": 0, "w": 874, "h": 402]
    ]
    #expect(AXSweep.interfaceSize(fromTree: landscape) == CGSize(width: 874, height: 402))
    #expect(
        AXSweep.nativeSize(interface: CGSize(width: 874, height: 402), orientation: .landscapeLeft)
            == CGSize(width: 402, height: 874)
    )
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

// MARK: - nativeSize

@Test("the panel transposes in landscape and holds in portrait", arguments: [
    (Orientation.portrait, CGSize(width: 402, height: 874)),
    (Orientation.portraitUpsideDown, CGSize(width: 402, height: 874)),
    (Orientation.landscapeLeft, CGSize(width: 874, height: 402)),
    (Orientation.landscapeRight, CGSize(width: 874, height: 402))
])
func nativeSizeTransposesOnlyInLandscape(orientation: Orientation, interface: CGSize) {
    // Whatever the interface reports, the panel is the same portrait
    // rectangle. Upside-down turns the picture without turning the
    // rectangle, which is why it groups with portrait here.
    #expect(
        AXSweep.nativeSize(interface: interface, orientation: orientation)
            == CGSize(width: 402, height: 874)
    )
}

// MARK: - nativePixel

@Test
func nativePixelScalesNormalizedToThePanelInPortrait() {
    // Portrait is the identity rotation, so the whole conversion is
    // (normalized × size), the coordinate AXPTranslator expects.
    // Center of a watch screen → midpoints of (184, 224); top-left →
    // origin; near-edge (0.95) → just inside the half-open upper
    // bound `gridPoints` honors.
    // Use approximate equality at the near-edge sample because IEEE
    // 754 multiplication doesn't land on exact tenths (0.95 × 184
    // rounds to 174.79999… and asserting an exact 174.8 would be
    // a false-precision test, not a correctness test).
    let interface = CGSize(width: 184, height: 224)
    #expect(
        AXSweep.nativePixel(
        displayed: CGPoint(x: 0.5, y: 0.5),
        orientation: .portrait,
        interface: interface
    ) == CGPoint(x: 92.0, y: 112.0)
        )
    #expect(
        AXSweep.nativePixel(
        displayed: CGPoint.zero,
        orientation: .portrait,
        interface: interface
    ) == CGPoint.zero
        )
    let near = AXSweep.nativePixel(
        displayed: CGPoint(x: 0.95, y: 0.95),
        orientation: .portrait,
        interface: interface
    )
    #expect(abs(near.x - 174.8) < 0.001)
    #expect(abs(near.y - 212.8) < 0.001)
}

@Test
func nativePixelHitsKnownWatchOSElement() {
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
    let pixel = AXSweep.nativePixel(
        displayed: CGPoint(x: 0.25, y: 0.30),
        orientation: .portrait,
        interface: interface
    )
    let element = CGRect(x: 7, y: 63.5, width: 78, height: 11)
    #expect(
        element.contains(pixel),
            "scaled pixel \(pixel) must fall inside \(element)"
        )
}

@Test
func nativePixelHitsALandscapeElementReadOutOfTheTree() {
    // The recipe DeviceTerm publishes, end to end, in landscape: take a
    // frame out of `ax tree`, normalize it by the root frame, hand the
    // centre back as a query point.
    //
    // The frame and the root are landscape-left interface space. The
    // element is a control near the displayed top-left. The query has
    // to come back inside the frame, and it only does if the point is
    // rotated *and* divided by the panel's own 402×874 rather than by
    // the 874×402 the tree reported.
    let interface = CGSize(width: 874, height: 402)
    let element = CGRect(x: 232, y: 298, width: 100, height: 24)
    let centre = CGPoint(
        x: element.midX / interface.width,
        y: element.midY / interface.height
    )
    let pixel = AXSweep.nativePixel(
        displayed: centre,
        orientation: .landscapeLeft,
        interface: interface
    )
    // The panel sees the same element transposed: its interface
    // (x, y) is the panel's (h - y, x).
    let onPanel = CGRect(
        x: interface.height - element.maxY,
        y: element.minX,
        width: element.height,
        height: element.width
    )
    #expect(
        onPanel.contains(pixel),
            "\(pixel) must fall inside the panel-space element \(onPanel)"
        )
}

// A 402×874 panel, and the interface size the accessibility tree
// reports for it in each orientation. Shared by the two tests below so
// the panel stays one number while the reported size turns.
private let panelUnderTest = CGRect(x: 0, y: 0, width: 402, height: 874)
private let portraitInterface = CGSize(width: 402, height: 874)
private let landscapeInterface = CGSize(width: 874, height: 402)

@Test("every orientation maps the displayed corner it names", arguments: [
    (Orientation.portrait, portraitInterface, CGPoint(x: 40.2, y: 87.4)),
    (Orientation.landscapeLeft, landscapeInterface, CGPoint(x: 361.8, y: 87.4)),
    (Orientation.portraitUpsideDown, portraitInterface, CGPoint(x: 361.8, y: 786.6)),
    (Orientation.landscapeRight, landscapeInterface, CGPoint(x: 40.2, y: 786.6))
])
func nativePixelRotatesWithTheDevice(
    orientation: Orientation,
    interface: CGSize,
    expected: CGPoint
) {
    // One displayed point, a tenth in from the top-left of the picture,
    // through each orientation. The panel is 402×874 throughout; what
    // changes is which of its corners the picture's top-left sits in.
    let pixel = AXSweep.nativePixel(
        displayed: CGPoint(x: 0.1, y: 0.1),
        orientation: orientation,
        interface: interface
    )
    #expect(abs(pixel.x - expected.x) < 0.001, "x: got \(pixel.x), want \(expected.x)")
    #expect(abs(pixel.y - expected.y) < 0.001, "y: got \(pixel.y), want \(expected.y)")
}

@Test("a rotated edge stays on the panel", arguments: [
    (Orientation.portrait, portraitInterface),
    (Orientation.portraitUpsideDown, portraitInterface),
    (Orientation.landscapeLeft, landscapeInterface),
    (Orientation.landscapeRight, landscapeInterface)
])
func nativePixelKeepsTheRotatedEdgeAddressable(orientation: Orientation, interface: CGSize) {
    // Every orientation but portrait sends some displayed boundary the
    // grid emits to exactly 1.0, one past the last coordinate a frame
    // contains: the top edge (y = 0) under landscape-left, the left edge
    // (x = 0) under landscape-right, both upside-down. Unclamped, that
    // whole line of the sweep hits nothing.
    let boundary = [
        CGPoint.zero,
        CGPoint(x: 0.5, y: 0),      // mid displayed top edge
        CGPoint(x: 0, y: 0.5),      // mid displayed left edge
        CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1)
    ]
    for displayed in boundary {
        let pixel = AXSweep.nativePixel(
            displayed: displayed,
            orientation: orientation,
            interface: interface
        )
        #expect(
            panelUnderTest.contains(pixel),
                "\(orientation) sent displayed \(displayed) to \(pixel), off the panel"
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
