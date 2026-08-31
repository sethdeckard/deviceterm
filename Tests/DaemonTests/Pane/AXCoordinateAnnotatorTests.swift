// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

private func normalizedCenter(_ node: [String: Any]) -> (x: Double, y: Double)? {
    guard let center = node["normalizedCenter"] as? [String: Any],
        let x = (center["x"] as? NSNumber)?.doubleValue,
        let y = (center["y"] as? NSNumber)?.doubleValue
    else { return nil }
    return (x, y)
}

/// Reads a `{x, y, w, h}` dict back out of a decoded response. JSON hands
/// every number over as an `NSNumber`, so a whole-dict cast would turn on
/// which Swift type each literal happened to bridge as.
private func frame(_ node: [String: Any], key: String) -> [String: Double]? {
    guard let frame = node[key] as? [String: Any] else { return nil }
    var values: [String: Double] = [:]
    for (name, value) in frame {
        guard let number = (value as? NSNumber)?.doubleValue else { return nil }
        values[name] = number
    }
    return values
}

private func decodedObject(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try #require(object)
}

private func rootTree() -> [String: Any] {
    [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 400, "h": 800],
        "children": []
    ]
}

private func button() -> [String: Any] {
    [
        "role": "Button",
        "label": "Continue",
        "frame": ["x": 20, "y": 80, "w": 120, "h": 44]
    ]
}

@Test
func annotatesARecursiveTreeWithoutReplacingFrames() throws {
    var tree = rootTree()
    tree["children"] = [button()]

    let annotated = AXCoordinateAnnotator.tree(tree)
    let rootCenter = try #require(normalizedCenter(annotated))
    #expect(rootCenter.x == 0.5)
    #expect(rootCenter.y == 0.5)

    let children = try #require(annotated["children"] as? [[String: Any]])
    let child = try #require(children.first)
    let childCenter = try #require(normalizedCenter(child))
    #expect(childCenter.x == 0.2)
    #expect(childCenter.y == 0.1275)
    #expect(child["frame"] as? [String: Int] == button()["frame"] as? [String: Int])
    #expect(child["label"] as? String == "Continue")
}

@Test
func includesCentersOnTheDisplayedBoundary() throws {
    let nodes: [[String: Any]] = [
        ["frame": ["x": -20, "y": -40, "w": 40, "h": 80]],
        ["frame": ["x": 380, "y": 760, "w": 40, "h": 80]]
    ]
    let annotated = nodes.map { AXCoordinateAnnotator.element($0, rootTree: rootTree()) }
    let topLeft = try #require(normalizedCenter(annotated[0]))
    let bottomRight = try #require(normalizedCenter(annotated[1]))
    #expect(topLeft.x == 0)
    #expect(topLeft.y == 0)
    #expect(bottomRight.x == 1)
    #expect(bottomRight.y == 1)
}

@Test
func omitsCentersForUnusableGeometry() {
    let invalidNodes: [[String: Any]] = [
        [:],
        ["frame": ["x": 0, "y": 0, "w": 0, "h": 44]],
        ["frame": ["x": 0, "y": 0, "w": 44, "h": -1]],
        ["frame": ["x": Double.infinity, "y": 0, "w": 44, "h": 44]],
        ["frame": ["x": 401, "y": 0, "w": 44, "h": 44]]
    ]
    for node in invalidNodes {
        #expect(AXCoordinateAnnotator.element(node, rootTree: rootTree())["normalizedCenter"] == nil)
    }

    let noFrameRoot: [String: Any] = ["role": "Application"]
    let zeroRoot: [String: Any] = ["frame": ["x": 0, "y": 0, "w": 0, "h": 800]]
    #expect(AXCoordinateAnnotator.element(button(), rootTree: noFrameRoot)["normalizedCenter"] == nil)
    #expect(AXCoordinateAnnotator.element(button(), rootTree: zeroRoot)["normalizedCenter"] == nil)

    var colliding = button()
    colliding["normalizedCenter"] = ["x": 0.25, "y": 0.25]
    #expect(AXCoordinateAnnotator.element(colliding, rootTree: noFrameRoot)["normalizedCenter"] == nil)
}

@Test
func treeResponseAnnotatesItsRootAndChildren() async throws {
    let backend = MockDeviceBackend()
    backend.frontmostTree = rootTree().merging(["children": [button()]]) { _, new in new }

    let data = try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "test.ax.coordinates.tree"),
        paneId: UUID(),
        family: .phone,
        orientation: { .portrait }
    )
    let tree = try decodedObject(data)
    let children = try #require(tree["children"] as? [[String: Any]])
    #expect(normalizedCenter(tree)?.x == 0.5)
    #expect(normalizedCenter(try #require(children.first))?.x == 0.2)
}

@Test
func pointResponseUsesTheFrontmostRoot() async throws {
    let backend = MockDeviceBackend()
    backend.frontmostTree = rootTree()
    backend.accessibilityElement = button()

    let data = try await PaneAccessibility.element(
        backend: backend,
        queue: BlockingWorkQueue(label: "test.ax.coordinates.point"),
        paneId: UUID(),
        orientation: { .portrait },
        x: 0.2,
        y: 0.1275
    )
    let element = try decodedObject(data)
    #expect(normalizedCenter(element)?.x == 0.2)
    #expect(normalizedCenter(element)?.y == 0.1275)
    #expect(element["frame"] is [String: Any])
}

@Test
func aPointResponseCarriesTheFrameItsCentreWasDividedBy() async throws {
    let backend = MockDeviceBackend()
    backend.frontmostTree = rootTree()
    backend.accessibilityElement = button()

    let data = try await PaneAccessibility.element(
        backend: backend,
        queue: BlockingWorkQueue(label: "test.ax.rootframe.point"),
        paneId: UUID(),
        orientation: { .portrait },
        x: 0.2,
        y: 0.1275
    )
    let element = try decodedObject(data)
    let published = try #require(frame(element, key: "rootFrame"))
    #expect(published == ["x": 0, "y": 0, "w": 400, "h": 800])

    // Asserted as arithmetic, not as a pair of literals: multiplying a
    // normalized centre by this frame must land on the element's own
    // displayed centre.
    let center = try #require(normalizedCenter(element))
    let own = try #require(frame(element, key: "frame"))
    let width = try #require(published["w"])
    let height = try #require(published["h"])
    let ownX = try #require(own["x"])
    let ownY = try #require(own["y"])
    let ownWidth = try #require(own["w"])
    let ownHeight = try #require(own["h"])
    #expect(center.x * width == ownX + ownWidth / 2)
    #expect(center.y * height == ownY + ownHeight / 2)
}

@Test
func aSweepRootCarriesTheScreenBesideItsNormalizedFrame() async throws {
    let backend = MockDeviceBackend()
    backend.frontmostTree = rootTree()
    backend.accessibilityElement = button()

    let data = try await PaneAccessibility.sweep(
        backend: backend,
        queue: BlockingWorkQueue(label: "test.ax.rootframe.sweep"),
        paneId: UUID(),
        orientation: { .portrait },
        step: AXSweep.maxStep,
        budgetMs: AXSweepBudget.maxMs
    )
    let root = try decodedObject(data)
    #expect(frame(root, key: "rootFrame") == ["x": 0, "y": 0, "w": 400, "h": 800])
    // The synthetic root's own frame is the published placeholder and does not
    // move. `rootFrame` distinguishes the measured screen from that
    // placeholder, so a change to either one here is a wire break.
    #expect(frame(root, key: "frame") == ["x": 0, "y": 0, "w": 1, "h": 1])

    // Only the root. A child's frame is already in displayed points, so a
    // per-child copy of the screen would be noise on every element.
    let children = try #require(root["children"] as? [[String: Any]])
    #expect(children.isEmpty == false)
    #expect(children.allSatisfy { $0["rootFrame"] == nil })
}

@Test
func anUnusableRootPublishesNeitherAScreenNorACentre() async throws {
    // An infinite dimension is the trap the reconstruction exists for.
    // `JSONSerialization` raises on a non-finite number instead of returning
    // an error, and the raise is an Objective-C exception no Swift `catch`
    // sees, so echoing the root's frame through would abort the daemon.
    // Written as a loop rather than as `arguments:`, because a tree is
    // `[String: Any]` and a Swift Testing argument has to be `Sendable`.
    let unusableRoots: [[String: Any]] = [
        ["role": "Application"],
        ["frame": ["x": 0, "y": 0, "w": 0, "h": 800]],
        ["frame": ["x": 0, "y": 0, "w": Double.infinity, "h": 800]]
    ]
    for root in unusableRoots {
        let backend = MockDeviceBackend()
        backend.frontmostTree = root
        backend.accessibilityElement = button()

        let point = try decodedObject(try await PaneAccessibility.element(
            backend: backend,
            queue: BlockingWorkQueue(label: "test.ax.rootframe.unusable.point"),
            paneId: UUID(),
            orientation: { .portrait },
            x: 0.5,
            y: 0.5
        ))
        #expect(point["rootFrame"] == nil)
        #expect(point["normalizedCenter"] == nil)

        let swept = try decodedObject(try await PaneAccessibility.sweep(
            backend: backend,
            queue: BlockingWorkQueue(label: "test.ax.rootframe.unusable.sweep"),
            paneId: UUID(),
            orientation: { .portrait },
            step: AXSweep.maxStep,
            budgetMs: AXSweepBudget.maxMs
        ))
        #expect(swept["rootFrame"] == nil)
        let children = try #require(swept["children"] as? [[String: Any]])
        #expect(children.allSatisfy { $0["normalizedCenter"] == nil })
    }
}

@Test
func aRootWhoseOriginIsUnusableStillCentresButPublishesNoScreen() async throws {
    let backend = MockDeviceBackend()
    // `Scale` reads only `w` and `h`, so this root scales fine while its
    // origin cannot be serialized. The two fields part company here, and they
    // part in the safe direction: the caller loses the convenience rather
    // than receiving a repaired frame that is quietly wrong.
    backend.frontmostTree = ["frame": ["x": Double.infinity, "y": 0, "w": 400, "h": 800]]
    backend.accessibilityElement = button()

    let element = try decodedObject(try await PaneAccessibility.element(
        backend: backend,
        queue: BlockingWorkQueue(label: "test.ax.rootframe.origin"),
        paneId: UUID(),
        orientation: { .portrait },
        x: 0.2,
        y: 0.1275
    ))
    #expect(normalizedCenter(element)?.x == 0.2)
    #expect(element["rootFrame"] == nil)
}

@Test
func aBridgeSuppliedRootFrameNeverSurvives() async throws {
    var colliding = button()
    colliding["rootFrame"] = ["x": 7, "y": 7, "w": 7, "h": 7]

    let usable = MockDeviceBackend()
    usable.frontmostTree = rootTree()
    usable.accessibilityElement = colliding
    let overwritten = try decodedObject(try await PaneAccessibility.element(
        backend: usable,
        queue: BlockingWorkQueue(label: "test.ax.rootframe.collide.usable"),
        paneId: UUID(),
        orientation: { .portrait },
        x: 0.2,
        y: 0.1275
    ))
    #expect(frame(overwritten, key: "rootFrame") == ["x": 0, "y": 0, "w": 400, "h": 800])

    // The case a call-site-only strip would miss: with no frame of our own to
    // stamp, a framework value in this key would be the one the caller reads.
    let unusable = MockDeviceBackend()
    unusable.frontmostTree = ["role": "Application"]
    unusable.accessibilityElement = colliding
    let stripped = try decodedObject(try await PaneAccessibility.element(
        backend: unusable,
        queue: BlockingWorkQueue(label: "test.ax.rootframe.collide.unusable"),
        paneId: UUID(),
        orientation: { .portrait },
        x: 0.2,
        y: 0.1275
    ))
    #expect(stripped["rootFrame"] == nil)
}

@Test
func anAccessibilityTreeCarriesNoScreenFrameAtAnyDepth() async throws {
    // `ax tree` needs no such field: its own root frame *is* the divisor, so
    // publishing a second copy of it would be the same number twice.
    var seeded = button()
    seeded["rootFrame"] = ["x": 7, "y": 7, "w": 7, "h": 7]
    var tree = rootTree()
    tree["rootFrame"] = ["x": 7, "y": 7, "w": 7, "h": 7]
    tree["children"] = [seeded]

    let backend = MockDeviceBackend()
    backend.frontmostTree = tree
    let decoded = try decodedObject(try await PaneAccessibility.tree(
        backend: backend,
        queue: BlockingWorkQueue(label: "test.ax.rootframe.tree"),
        paneId: UUID(),
        family: .phone,
        orientation: { .portrait }
    ))
    #expect(decoded["rootFrame"] == nil)
    let children = try #require(decoded["children"] as? [[String: Any]])
    let child = try #require(children.first)
    #expect(child["rootFrame"] == nil)
}

@Test
func sweepAnnotatesChildrenButNotItsSyntheticRoot() async throws {
    let backend = MockDeviceBackend()
    backend.frontmostTree = rootTree()
    backend.accessibilityElement = button()

    let data = try await PaneAccessibility.sweep(
        backend: backend,
        queue: BlockingWorkQueue(label: "test.ax.coordinates.sweep"),
        paneId: UUID(),
        orientation: { .portrait },
        step: AXSweep.maxStep,
        budgetMs: AXSweepBudget.maxMs
    )
    let root = try decodedObject(data)
    let children = try #require(root["children"] as? [[String: Any]])
    #expect(root["role"] as? String == "AXSweepRoot")
    #expect(root["normalizedCenter"] == nil)
    #expect(normalizedCenter(try #require(children.first))?.x == 0.2)
    #expect(children.count == 1)
}
