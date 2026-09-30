// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// AX tests cover the validation + wrapping path without needing a
// booted simulator. Bridge-level AX (frontmostTree against a real
// device, recursive children walks, AXPTranslator multi-tenant
// behavior) is covered by `CoreSimulatorBridgeTests/
// AccessibilityTests.swift` when a real device is available.

// MARK: - Coordinator-level: unknown pane

@Test
func accessibilityTreeOnUnknownPaneThrowsNotFound() async throws {
    let coordinator = PaneCoordinator()
    let strayId = UUID()
    await #expect(throws: PaneError.notFound(paneId: strayId)) {
        _ = try await coordinator.accessibilityTree(paneId: strayId, as: .guiPeer)
    }
}

// MARK: - RPC: validation

@Test
func paneAXTreeRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneax")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.ax.tree",
        body: .params(try paramsBytes(AXTreeParams(paneId: "nope")))
    )
        )
    let response = try client.receive()
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
    #expect(rpcError.message.contains("paneId"))
}

@Test
func paneAXPointRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneax")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.ax.point",
        body: .params(
            try paramsBytes(
            AXPointParams(
            paneId: "still-nope",
            x: 0.5,
            y: 0.5
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
}

// MARK: - PaneError → RPCMethodError mapping

@Test
func bridgeFailedMapsToDedicatedWireCode() {
    // Wire-contract pin: a systemic bridge failure surfaces as
    // `error.bridgeFailed` (code -32020), distinct from the
    // catch-all `serverError` (-32000). Machine consumers
    // dispatch on the code field, not the message string. The
    // operation name + bridge message ride through unchanged.
    let mapped = PaneMethods.mapPaneError(
        .bridgeFailed(
        paneId: UUID(),
        operation: .axSweep,
        message: "AX server not ready"
    )
        )
    #expect(mapped.code == RPCMethodError.bridgeFailedCode)
    #expect(mapped.code != RPCErrorCode.serverError)
    #expect(mapped.message.contains("ax.sweep"))
    #expect(mapped.message.contains("AX server not ready"))
}

@Test
func aMissingFrontmostApplicationIsReportedAsNotReady() throws {
    // A missing frontmost application can occur during simulator startup, so
    // it's retryable. It keeps the bridge-failure code for clients that ignore
    // `details`; the reason is what tells a wait it can keep polling.
    let frontmostNil = NSError(
        domain: SimAccessibilityErrorDomain,
        code: SimAccessibilityErrorCode.frontmostNil.rawValue
    )
    let error = PaneAccessibility.frontmostFailure(
        frontmostNil,
        paneId: UUID(),
        operation: .axTree,
        message: "frontmostApplication returned nil"
    )
    guard case .accessibilityNotReady = error else {
        Issue.record("expected accessibilityNotReady, got \(error)")
        return
    }
    let mapped = PaneMethods.mapPaneError(error)
    #expect(mapped.code == RPCMethodError.bridgeFailedCode)
    #expect(mapped.message.contains("ax.tree"))
    let details = try #require(mapped.details)
    let object = try #require(JSONSerialization.jsonObject(with: details) as? [String: String])
    #expect(object[AXFailureReason.detailsKey] == AXFailureReason.notReady.rawValue)
}

@Test("every other frontmost failure stays a plain bridge failure", arguments: [
    NSError(domain: SimAccessibilityErrorDomain, code: 77),
    NSError(domain: "SomeOtherDomain", code: SimAccessibilityErrorCode.frontmostNil.rawValue)
])
func otherFrontmostFailuresStayBridgeFailures(error: NSError) {
    let mapped = PaneAccessibility.frontmostFailure(
        error,
        paneId: UUID(),
        operation: .axPoint,
        message: "boom"
    )
    guard case .bridgeFailed = mapped else {
        Issue.record("expected bridgeFailed, got \(mapped)")
        return
    }
    #expect(PaneMethods.mapPaneError(mapped).details == nil)
}

// MARK: - Coordinator-level: coordinate mapping

@Test("a point query scales against the tree it just read")
func aPointQueryScalesAgainstTheTreeItJustRead() async throws {
    // Accessibility is asked in the tree's own space: the root frame turns
    // with the interface and `objectAtPoint:` hit-tests in that same
    // rectangle, measured on an iPad in both orientations. So a displayed
    // point scales straight into whichever root the tree reports, and is
    // never rotated into the panel.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.frontmostTree = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": []
    ]
    let result = try await coordinator.createMockPane(
        udid: "udid-ax-orientation",
        sessionId: UUID(),
        backend: backend
    )
    let centre = (x: 282.0 / 874.0, y: 310.0 / 402.0)

    _ = try await coordinator.accessibilityElement(
        paneId: result.paneId,
        as: .guiPeer,
        x: centre.x,
        y: centre.y
    )
    let portrait = try #require(backend.accessibilityPoints.last)
    #expect(abs(portrait.x - centre.x * 402) < 0.001)
    #expect(abs(portrait.y - centre.y * 874) < 0.001)

    // Turn the device. The tree reports the interface transposed, as the real
    // bridge does, and the query follows it rather than the panel.
    backend.frontmostTree = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 874, "h": 402],
        "children": []
    ]
    _ = try await coordinator.accessibilityElement(
        paneId: result.paneId,
        as: .guiPeer,
        x: centre.x,
        y: centre.y
    )
    let landscape = try #require(backend.accessibilityPoints.last)
    #expect(
        abs(landscape.x - 282) < 0.001 && abs(landscape.y - 310) < 0.001,
        "landscape query hit \(landscape), want root-frame scaling (282.0, 310.0)"
    )
}

// MARK: - The completeness probe

/// Counts bridge reads so a test can assert what a path spent.
///
/// `@unchecked Sendable` for the reason `MockDeviceBackend` is: the pane's
/// serial work queue runs every one of these calls, so there is no concurrent
/// access to guard against.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

/// The element a racing hit-test answers with, belonging to the screen that
/// replaced the one the tree described. Built by a function rather than held
/// in a variable so the `@Sendable` fake never captures a Foundation dict.
private func lateArrival() -> [String: Any] {
    [
        "role": "StaticText",
        "label": "Arrived Late",
        "frame": ["x": 23, "y": 436, "w": 272, "h": 19],
        "children": []
    ]
}

/// The screen that element does belong to, which the confirming read sees.
private func treeContainingLateArrival() -> [String: Any] {
    [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": [lateArrival()]
    ]
}

/// A different screen that is itself incomplete: same bounds, chrome only,
/// and it does not enumerate the late arrival either. Asking only whether the
/// element is missing from the second tree would accept this one.
private func otherIncompleteTree() -> [String: Any] {
    [
        "role": "Application",
        "label": "Safari",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": [
            [
                "role": "Button",
                "label": "Tabs",
                "frame": ["x": 320, "y": 792, "w": 48, "h": 48],
                "children": []
            ]
        ]
    ]
}

/// A tree whose only child sits in the bottom toolbar band, so nothing covers
/// the centre and the probe fires. `interface` is the frame the tree reports,
/// which transposes with the device.
private func uncoveredTree(interface: CGSize) -> [String: Any] {
    [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": interface.width, "h": interface.height],
        "children": [
            [
                "role": "Button",
                "label": "Back",
                "frame": ["x": 0, "y": 0, "w": 8, "h": 8],
                "children": []
            ]
        ]
    ]
}

@Test(
    "the completeness probe scales against the tree it read",
    arguments: [
        (CGSize(width: 402, height: 874), CGPoint(x: 201, y: 437)),
        (CGSize(width: 874, height: 402), CGPoint(x: 437, y: 201))
    ]
)
func theProbeScalesAgainstTheTree(
    interface: CGSize,
    expected: CGPoint
) async throws {
    // The probe hit-tests the centre of whatever root the tree reported,
    // because that rectangle is the space `objectAtPoint:` answers in. A
    // landscape tree probes the centre of a landscape rectangle, not the
    // centre of a portrait panel.
    let backend = MockDeviceBackend()
    backend.frontmostTree = uncoveredTree(interface: interface)

    _ = try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "com.deviceterm.test.pane-ax-probe"),
        paneId: UUID(),
        family: .phone
    )

    let queried = try #require(backend.accessibilityPoints.last)
    #expect(
        abs(queried.x - expected.x) < 0.001 && abs(queried.y - expected.y) < 0.001,
        "probed \(queried); want the centre of the reported root \(expected)"
    )
}

@Test
func aFailedProbeStillAnswersTheTree() async throws {
    // `objectAtPointNil` is the bridge's routine "nothing here" and shares a
    // code with a systemic fault. The probe is advisory, so one that could
    // turn a successful tree read into `bridgeFailed` would trade the verb
    // for a hint.
    let backend = MockDeviceBackend()
    backend.frontmostTree = uncoveredTree(interface: CGSize(width: 402, height: 874))
    backend.accessibilityElementError = PaneError.bridgeFailed(
        paneId: UUID(),
        operation: .axPoint,
        message: "No element at point"
    )

    let data = try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "com.deviceterm.test.pane-ax-probe-fails"),
        paneId: UUID(),
        family: .phone
    )

    let tree = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(tree["role"] as? String == "Application")
    #expect(tree["note"] == nil)
    #expect(tree["noteCode"] == nil)
}

@Test
func aScreenThatChangedMidReadEarnsNoNote() async throws {
    // The tree read and the hit-test are separate bridge calls, so an app
    // transition between them can answer with an element from a screen the
    // first tree never described. Annotating then would call the wrong screen
    // incomplete. The confirming read is what catches it.
    let backend = MockDeviceBackend()
    backend.frontmostTree = uncoveredTree(interface: CGSize(width: 402, height: 874))
    backend.accessibilityElement = lateArrival()

    // The fake swaps in the screen the element belongs to, but only for the
    // confirming read, so the first tree is the stale one the probe raced.
    let reads = Counter()
    backend.onFrontmostTree = { [weak backend] in
        if reads.increment() == 2 {
            backend?.frontmostTree = treeContainingLateArrival()
        }
    }

    let data = try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "com.deviceterm.test.pane-ax-raced"),
        paneId: UUID(),
        family: .phone
    )

    let tree = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(reads.value == 2, "the finding was not confirmed against a second read")
    #expect(tree["note"] == nil)
    #expect(tree["noteCode"] == nil)
}

@Test
func aMoveToAnotherIncompleteScreenEarnsNoNote() async throws {
    // The case an absence-only confirmation cannot catch. The screen the tree
    // described is replaced by a different one that is also incomplete, so the
    // hit-tested element is missing from both trees and every absence check
    // agrees. Annotating here would call the first screen incomplete on
    // evidence gathered from the second, which says nothing about it.
    let backend = MockDeviceBackend()
    backend.frontmostTree = uncoveredTree(interface: CGSize(width: 402, height: 874))
    backend.accessibilityElement = lateArrival()

    let reads = Counter()
    backend.onFrontmostTree = { [weak backend] in
        if reads.increment() == 2 {
            backend?.frontmostTree = otherIncompleteTree()
        }
    }

    let data = try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "com.deviceterm.test.pane-ax-swapped"),
        paneId: UUID(),
        family: .phone
    )

    let tree = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(reads.value == 2)
    #expect(tree["note"] == nil)
    #expect(tree["noteCode"] == nil)
}

@Test
func aStableScreenSurvivesConfirmationAndIsNoted() async throws {
    // The other half: when both reads agree, the note stands. Without this
    // the test above would pass against an implementation that never notes.
    let backend = MockDeviceBackend()
    backend.frontmostTree = uncoveredTree(interface: CGSize(width: 402, height: 874))
    backend.accessibilityElement = [
        "role": "StaticText",
        "label": "For Wikipedia's accessibility guideline, see",
        "frame": ["x": 23, "y": 436, "w": 272, "h": 19],
        "children": []
    ]

    let data = try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "com.deviceterm.test.pane-ax-stable"),
        paneId: UUID(),
        family: .phone
    )

    let tree = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(tree["noteCode"] as? String == AXTreeNote.treeIncomplete.code)
}

@Test
func aRejectedProbeSpendsNoConfirmingRead() async throws {
    // A hit-test that answers with the enclosing container is refused before
    // the confirmation, so the second tree read costs nothing on a screen
    // that was never going to be annotated.
    let backend = MockDeviceBackend()
    backend.frontmostTree = uncoveredTree(interface: CGSize(width: 402, height: 874))
    backend.accessibilityElement = [
        "role": "Group",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874]
    ]
    let reads = Counter()
    backend.onFrontmostTree = { _ = reads.increment() }

    _ = try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "com.deviceterm.test.pane-ax-fallback"),
        paneId: UUID(),
        family: .phone
    )

    #expect(reads.value == 1)
}

@Test
func aCoveredCentreCostsNoBridgeCall() async throws {
    // What keeps the probe free on an ordinary screen: a tree that already
    // describes something at the centre is never hit-tested at all.
    let backend = MockDeviceBackend()
    backend.frontmostTree = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": [
            [
                "role": "Button",
                "label": "Action Button",
                "frame": ["x": 16, "y": 397, "w": 370, "h": 52],
                "children": []
            ]
        ]
    ]

    _ = try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "com.deviceterm.test.pane-ax-no-probe"),
        paneId: UUID(),
        family: .phone
    )

    #expect(backend.accessibilityPoints.isEmpty)
}

// MARK: - Response wrapping

@Test
func wrapAXResultProducesObjectWithKey() throws {
    // Sanity-check the helper that wraps a coordinator-side AX blob
    // into the canonical {tree: …} / {element: …} shape. Pinning
    // this means downstream clients can decode the response with a
    // small Codable struct without parsing surprises.
    let inner = try JSONSerialization.data(
        withJSONObject: ["role": "Button", "label": "OK"],
        options: []
    )
    let wrapped = try PaneMethods.wrapAXResult(key: "tree", innerJSON: inner)
    let parsed = try JSONSerialization.jsonObject(with: wrapped) as? [String: Any]
    let tree = parsed?["tree"] as? [String: Any]
    #expect(tree?["role"] as? String == "Button")
    #expect(tree?["label"] as? String == "OK")
}
