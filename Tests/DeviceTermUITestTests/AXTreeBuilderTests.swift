// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("accessibility tree shaping + limits")
struct AXTreeBuilderTests {
    /// Stand-in for an `AXUIElement`: the builder only ever asks for a
    /// node's attributes and its children.
    private struct FakeElement {
        let name: String
        var kids: [FakeElement] = []
    }

    private func build(
        _ root: FakeElement,
        limits: AXTreeLimits
    ) -> (root: [String: Any], truncated: Bool) {
        AXTreeBuilder.build(
            root: root,
            limits: limits,
            attributes: { ["role": $0.name] },
            children: { $0.kids }
        )
    }

    /// A chain `a → b → c …` `depth` links long.
    private func chain(depth: Int) -> FakeElement {
        var node = FakeElement(name: "n\(depth)")
        for level in stride(from: depth - 1, through: 0, by: -1) {
            node = FakeElement(name: "n\(level)", kids: [node])
        }
        return node
    }

    private func childRoles(_ node: [String: Any]) -> [String] {
        let kids = node["children"] as? [[String: Any]] ?? []
        return kids.compactMap { $0["role"] as? String }
    }

    @Test
    func nestsChildrenAndCarriesAttributes() throws {
        let tree = FakeElement(name: "AXApplication", kids: [
            FakeElement(name: "AXWindow", kids: [FakeElement(name: "AXButton")])
        ])
        let result = build(tree, limits: AXTreeLimits(maxDepth: 10, maxNodes: 100))

        #expect(result.truncated == false)
        #expect(result.root["role"] as? String == "AXApplication")
        #expect(childRoles(result.root) == ["AXWindow"])

        let window = try #require((result.root["children"] as? [[String: Any]])?.first)
        #expect(childRoles(window) == ["AXButton"])
    }

    /// A leaf must not be marked truncated just because it has no children:
    /// an agent has to distinguish "nothing more here" from "we stopped".
    @Test
    func aLeafIsNotMarkedTruncated() {
        let result = build(FakeElement(name: "AXButton"), limits: AXTreeLimits(maxDepth: 0, maxNodes: 1))
        #expect(result.truncated == false)
        #expect(result.root["truncated"] == nil)
        #expect(result.root["children"] == nil)
    }

    @Test
    func stopsAtTheDepthCeilingAndMarksTheNode() {
        let result = build(chain(depth: 5), limits: AXTreeLimits(maxDepth: 2, maxNodes: 1_000))
        #expect(result.truncated)

        // root(0) → child(1) → child(2, marked, children dropped)
        let level1 = (result.root["children"] as? [[String: Any]])?.first
        let level2 = (level1?["children"] as? [[String: Any]])?.first
        #expect(level2?["role"] as? String == "n2")
        #expect(level2?["truncated"] as? Bool == true)
        #expect(level2?["children"] == nil)
    }

    @Test
    func stopsAtTheNodeBudgetAndMarksTheParent() {
        let wide = FakeElement(name: "root", kids: (0..<5).map { FakeElement(name: "kid\($0)") })
        // root + 2 children = 3 nodes.
        let result = build(wide, limits: AXTreeLimits(maxDepth: 10, maxNodes: 3))

        #expect(result.truncated)
        #expect(result.root["truncated"] as? Bool == true)
        #expect(childRoles(result.root) == ["kid0", "kid1"])
    }

    /// The budget is global, not per-level: a deep-but-narrow tree exhausts
    /// it just as a wide one does.
    @Test
    func theNodeBudgetIsSharedAcrossTheWholeWalk() {
        let result = build(chain(depth: 10), limits: AXTreeLimits(maxDepth: 100, maxNodes: 4))
        #expect(result.truncated)

        var node: [String: Any]? = result.root
        var visited = 0
        while let current = node {
            visited += 1
            node = (current["children"] as? [[String: Any]])?.first
        }
        #expect(visited == 4)
    }

    @Test
    func defaultLimitsAreBoundedAndPositive() {
        #expect(AXTreeLimits.default.maxDepth > 0)
        #expect(AXTreeLimits.default.maxNodes > 0)
    }
}
