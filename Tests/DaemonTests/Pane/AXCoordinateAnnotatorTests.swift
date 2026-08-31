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
