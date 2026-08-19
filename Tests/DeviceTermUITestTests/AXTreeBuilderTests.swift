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
        limits: AXTreeLimits,
        shouldDescend: (FakeElement, Int) -> Bool = { _, _ in true }
    ) -> (root: [String: Any], truncated: Bool) {
        AXTreeBuilder.build(
            root: root,
            limits: limits,
            attributes: { ["role": $0.name] },
            children: { $0.kids },
            shouldDescend: shouldDescend
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
    func skipsASubtreeThePolicyDeclines() throws {
        let tree = FakeElement(name: "root", kids: [
            FakeElement(name: "closed", kids: [FakeElement(name: "beneath")]),
            FakeElement(name: "open", kids: [FakeElement(name: "seen")])
        ])
        let result = build(
            tree,
            limits: AXTreeLimits(maxDepth: 10, maxNodes: 100),
            shouldDescend: { element, _ in element.name != "closed" }
        )

        // A declined subtree is not truncation: nothing ran out.
        #expect(result.truncated == false)
        #expect(childRoles(result.root) == ["closed", "open"])

        let kids = try #require(result.root["children"] as? [[String: Any]])
        #expect(kids[0]["skipped"] as? Bool == true)
        #expect(kids[0]["truncated"] == nil)
        #expect(kids[0]["children"] == nil)
        // Declining one child leaves its siblings walked as usual.
        #expect(kids[1]["skipped"] == nil)
        #expect(childRoles(kids[1]) == ["seen"])
    }

    /// On a real AX tree every child read is IPC into another process, so
    /// the policy prunes a subtree before asking for its children rather
    /// than filtering a tree that was already read.
    @Test
    func aDeclinedNodesChildrenAreNeverRead() {
        var read: [String] = []
        let tree = FakeElement(name: "root", kids: [
            FakeElement(name: "closed", kids: [FakeElement(name: "beneath")])
        ])
        _ = AXTreeBuilder.build(
            root: tree,
            limits: AXTreeLimits(maxDepth: 10, maxNodes: 100),
            attributes: { ["role": $0.name] },
            children: {
                read.append($0.name)
                return $0.kids
            },
            shouldDescend: { element, _ in element.name != "closed" }
        )
        #expect(read == ["root"])
    }

    @Test
    func thePolicySeesEachChildsSiblingIndex() {
        let tree = FakeElement(
            name: "root",
            kids: (0..<3).map { FakeElement(name: "kid\($0)") }
        )
        var seen: [String: Int] = [:]
        _ = build(
            tree,
            limits: AXTreeLimits(maxDepth: 10, maxNodes: 100),
            shouldDescend: { element, index in
                seen[element.name] = index
                return true
            }
        )
        #expect(seen == ["kid0": 0, "kid1": 1, "kid2": 2])
    }

    /// The root is always walked. A policy that refuses everything still
    /// yields the root and its immediate children, each marked.
    @Test
    func theRootIsNeverOfferedToThePolicy() {
        let tree = FakeElement(name: "root", kids: [
            FakeElement(name: "kid", kids: [FakeElement(name: "grandkid")])
        ])
        let result = build(
            tree,
            limits: AXTreeLimits(maxDepth: 10, maxNodes: 100),
            shouldDescend: { _, _ in false }
        )

        #expect(result.root["skipped"] == nil)
        #expect(childRoles(result.root) == ["kid"])

        let kid = (result.root["children"] as? [[String: Any]])?.first
        #expect(kid?["skipped"] as? Bool == true)
        #expect(kid?["children"] == nil)
    }

    /// The marker records what the walk did, not what exists. A childless
    /// node still carries it, because declining means never finding out.
    @Test
    func aDeclinedLeafIsStillMarkedSkipped() {
        let tree = FakeElement(name: "root", kids: [FakeElement(name: "leaf")])
        let result = build(
            tree,
            limits: AXTreeLimits(maxDepth: 10, maxNodes: 100),
            shouldDescend: { _, _ in false }
        )

        let leaf = (result.root["children"] as? [[String: Any]])?.first
        #expect(leaf?["skipped"] as? Bool == true)
    }

    @Test
    func defaultLimitsAreBoundedAndPositive() {
        #expect(AXTreeLimits.default.maxDepth > 0)
        #expect(AXTreeLimits.default.maxNodes > 0)
    }
}
