// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("accessibility tree shaping + limits")
struct AXTreeBuilderTests {
    /// Stand-in for an `AXUIElement`: the builder only ever asks for a
    /// node's attributes, its children, and its identity.
    private struct FakeElement {
        let name: String
        var kids: [FakeElement] = []
        /// Identity, when it has to differ from the name. Two elements
        /// reporting the same role while *being* different elements is the
        /// case the role rule exists for, and `name` doubles as the role
        /// here, so that case needs the two pulled apart.
        var id: String?

        var key: String { id ?? name }
    }

    private func build(
        _ root: FakeElement,
        limits: AXTreeLimits,
        shouldDescend: ([String: Any], Int) -> Bool = { _, _ in true }
    ) -> AXTreeResult {
        build(
            root: root,
            limits: limits,
            attributes: { ["role": $0.name] },
            children: { $0.kids },
            shouldDescend: shouldDescend
        )
    }

    /// `AXTreeBuilder.build` with `identity` defaulted to the fake element's
    /// key; callers may override it.
    private func build(
        root: FakeElement,
        limits: AXTreeLimits = .default,
        attributes: (FakeElement) -> [String: Any],
        children: (FakeElement) -> [FakeElement]?,
        identity: ((FakeElement) -> AnyHashable)? = nil,
        shouldDescend: ([String: Any], Int) -> Bool = { _, _ in true }
    ) -> AXTreeResult {
        AXTreeBuilder.build(
            root: root,
            limits: limits,
            attributes: attributes,
            children: children,
            identity: identity ?? { $0.key },
            shouldDescend: shouldDescend
        )
    }

    /// The names a node records as unread, or nil when it records none.
    private func unread(_ node: [String: Any]?) -> [String]? {
        node?[AXTreeBuilder.unreadableKey] as? [String]
    }

    /// A self-child is emitted once, marked, and not descended into. Without
    /// the guard the walk would emit `maxDepth` copies of it and mark the
    /// result truncated.
    @Test
    func stopsAtAnElementThatIsItsOwnChild() {
        let result = build(
            root: FakeElement(name: "root"),
            attributes: { ["role": $0.name] },
            children: { _ in [FakeElement(name: "root")] }
        )
        let kids = result.tree["children"] as? [[String: Any]]
        #expect(kids?.count == 1)
        #expect(kids?.first?[AXTreeBuilder.cycleKey] as? Bool == true)
        #expect(kids?.first?["role"] as? String == "root")
        #expect(kids?.first?["children"] == nil)
        #expect(!result.truncated)
    }

    /// The loop need not close on a direct child. Keying only the parent
    /// would catch the shape that happened to be found and miss this one.
    @Test
    func stopsAtALoopThatClosesFurtherDown() {
        let result = build(
            root: FakeElement(name: "a"),
            attributes: { ["role": $0.name] },
            children: { element in
                switch element.name {
                case "a":
                    return [FakeElement(name: "b")]

                case "b":
                    return [FakeElement(name: "a")]

                default:
                    return []
                }
            }
        )
        let middle = (result.tree["children"] as? [[String: Any]])?.first
        let repeated = (middle?["children"] as? [[String: Any]])?.first
        #expect(middle?["role"] as? String == "b")
        #expect(repeated?["role"] as? String == "a")
        #expect(repeated?[AXTreeBuilder.cycleKey] as? Bool == true)
        #expect(!result.truncated)
    }

    /// Membership is of the path from the root, not of everything seen. One
    /// element under two different parents is a shared node, and walking it
    /// twice is correct; marking the second as a loop would drop real UI.
    @Test
    func aSharedElementUnderTwoParentsIsNotALoop() {
        let shared = FakeElement(name: "shared")
        let result = build(
            root: FakeElement(name: "root", kids: [
                FakeElement(name: "left", kids: [shared]),
                FakeElement(name: "right", kids: [shared])
            ]),
            attributes: { ["role": $0.name] },
            children: { $0.kids }
        )
        let branches = result.tree["children"] as? [[String: Any]]
        let under = branches?.compactMap { ($0["children"] as? [[String: Any]])?.first }
        #expect(under?.count == 2)
        #expect(under?.allSatisfy { $0["role"] as? String == "shared" } == true)
        #expect(under?.allSatisfy { $0[AXTreeBuilder.cycleKey] == nil } == true)
    }

    /// Identity catches a nested application only when accessibility hands
    /// back an element that compares equal to its ancestor, and nothing in the
    /// API promises that, so `AXTraversalPolicy` refuses the role whether or
    /// not it does.
    ///
    /// The markers differ deliberately. `skipped` says the walk declined by
    /// rule; `cycle` would claim the element was met before, which a role
    /// comparison cannot establish.
    @Test
    func stopsAtANestedApplicationThatIsADistinctElement() throws {
        let result = build(
            root: FakeElement(
                name: "AXApplication",
                kids: [
                    FakeElement(name: "AXApplication", id: "nested"),
                    FakeElement(name: "AXWindow", kids: [FakeElement(name: "AXButton")])
                ],
                id: "root"
            ),
            attributes: { ["role": $0.name] },
            children: { $0.kids },
            shouldDescend: { node, index in
                AXTraversalPolicy.shouldEnter(
                    role: node["role"] as? String,
                    siblingIndex: index
                )
            }
        )

        let kids = try #require(result.tree["children"] as? [[String: Any]])
        #expect(kids.count == 2)
        #expect(kids[0]["role"] as? String == "AXApplication")
        #expect(kids[0]["skipped"] as? Bool == true)
        #expect(kids[0][AXTreeBuilder.cycleKey] == nil)
        #expect(kids[0]["children"] == nil)

        // Skipping the nested application preserves the sibling window.
        #expect(kids[1]["role"] as? String == "AXWindow")
        #expect(kids[1]["skipped"] == nil)
        #expect(childRoles(kids[1]) == ["AXButton"])
        #expect(!result.truncated)
    }

    /// A failed `AXChildren` read must not serialize like a childless node:
    /// that is how a timed-out walk comes to look like an empty UI. It names
    /// the attribute rather than setting a bare flag, so a caller can see
    /// that what failed was the structure and not a label.
    @Test
    func marksANodeWhoseChildrenCouldNotBeRead() {
        let result = build(
            root: FakeElement(name: "root"),
            limits: .default,
            attributes: { ["role": $0.name] },
            children: { _ in nil }
        )
        #expect(result.unreadable)
        #expect(unread(result.tree) == [AXAttribute.children])
        #expect(result.tree["children"] == nil)
    }

    /// The names accumulate. A node whose title failed and whose children
    /// then failed carries both, or the second write would erase the first
    /// and the tree would understate what it does not know.
    @Test
    func aFailedChildrenReadJoinsTheNamesAlreadyRecorded() {
        let result = build(
            root: FakeElement(name: "root"),
            limits: .default,
            attributes: { _ in [AXTreeBuilder.unreadableKey: [AXAttribute.title]] },
            children: { _ in nil }
        )
        #expect(unread(result.tree) == [AXAttribute.title, AXAttribute.children])
    }

    /// The marker is per-node and the flag is for the whole walk, so an
    /// unreadable child is reported even when the root read fine.
    @Test
    func reportsAnUnreadableChildBeneathAReadableRoot() {
        let leaf = FakeElement(name: "leaf")
        let result = build(
            root: FakeElement(name: "root", kids: [leaf]),
            limits: .default,
            attributes: { ["role": $0.name] },
            children: { $0.name == "leaf" ? nil : $0.kids }
        )
        #expect(result.unreadable)
        #expect(result.tree["unreadable"] == nil)
        let kids = result.tree["children"] as? [[String: Any]]
        #expect(unread(kids?.first) == [AXAttribute.children])
    }

    /// `attributes` records a read it could not make, and a structural one
    /// must reach the walk-wide flag even when every `children` read
    /// succeeded. Otherwise a node whose role timed out serializes as an
    /// ordinary one that simply matches no predicate, and a caller counting
    /// roles scores it zero and calls that an observation.
    @Test(arguments: [AXAttribute.role, AXAttribute.identifier, AXAttribute.children])
    func aFailedStructuralReadRaisesTheWalkWideFlag(attribute: String) {
        let result = build(
            root: FakeElement(name: "root", kids: [FakeElement(name: "leaf")]),
            limits: .default,
            attributes: { element in
                element.name == "leaf"
                    ? [AXTreeBuilder.unreadableKey: [attribute]]
                    : ["role": element.name]
            },
            children: { $0.kids }
        )
        #expect(result.unreadable)
        let kids = result.tree["children"] as? [[String: Any]]
        #expect(unread(kids?.first) == [attribute])
    }

    /// The flag is what makes a consumer refuse the whole tree, so it answers
    /// only for reads that could hide a node or misclassify one. A title or a
    /// value that would not read is recorded and nothing more: a sim pane
    /// mounts system-vended controls that fail such a read on every dump, so
    /// treating those as fatal refuses every tree they appear in.
    @Test(arguments: [
        AXAttribute.title,
        AXAttribute.value,
        AXAttribute.position
    ])
    func aFailedNonStructuralReadIsRecordedButNotFatal(attribute: String) {
        let result = build(
            root: FakeElement(name: "root", kids: [FakeElement(name: "leaf")]),
            limits: .default,
            attributes: { element in
                element.name == "leaf"
                    ? [AXTreeBuilder.unreadableKey: [attribute]]
                    : ["role": element.name]
            },
            children: { $0.kids }
        )
        #expect(!result.unreadable)
        let kids = result.tree["children"] as? [[String: Any]]
        #expect(unread(kids?.first) == [attribute])
    }

    /// One structural name among non-structural ones is enough. The flag asks
    /// whether any read that matters failed, not whether every one did.
    @Test
    func aMixedListRaisesTheFlagOnItsStructuralName() {
        let result = build(
            root: FakeElement(name: "root"),
            limits: .default,
            attributes: { _ in
                [AXTreeBuilder.unreadableKey: [AXAttribute.title, AXAttribute.role]]
            },
            children: { $0.kids }
        )
        #expect(result.unreadable)
    }

    /// The policy is handed the attributes the walk already read, so it can
    /// never disagree with the emitted node about what the element is. A
    /// second read could, and a policy pruning on its own failed read would
    /// leave a subtree missing from a dump nothing marked.
    @Test
    func thePolicyDecidesFromTheAttributesTheWalkRead() {
        var offered: [[String: Any]] = []
        _ = build(
            root: FakeElement(name: "root", kids: [FakeElement(name: "kid")]),
            limits: .default,
            attributes: { ["role": $0.name, "identifier": "id.\($0.name)"] },
            children: { $0.kids },
            shouldDescend: { node, _ in
                offered.append(node)
                return true
            }
        )
        #expect(offered.count == 1)
        #expect(offered.first?["role"] as? String == "kid")
        #expect(offered.first?["identifier"] as? String == "id.kid")
    }

    /// A genuinely childless node stays unmarked, or the flag would fire on
    /// every leaf and mean nothing.
    @Test
    func aChildlessNodeIsNotMarkedUnreadable() {
        let result = build(
            root: FakeElement(name: "root"),
            limits: .default,
            attributes: { ["role": $0.name] },
            children: { $0.kids }
        )
        #expect(!result.unreadable)
        #expect(result.tree["unreadable"] == nil)
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
        #expect(result.tree["role"] as? String == "AXApplication")
        #expect(childRoles(result.tree) == ["AXWindow"])

        let window = try #require((result.tree["children"] as? [[String: Any]])?.first)
        #expect(childRoles(window) == ["AXButton"])
    }

    /// A leaf must not be marked truncated just because it has no children:
    /// an agent has to distinguish "nothing more here" from "we stopped".
    @Test
    func aLeafIsNotMarkedTruncated() {
        let result = build(FakeElement(name: "AXButton"), limits: AXTreeLimits(maxDepth: 0, maxNodes: 1))
        #expect(result.truncated == false)
        #expect(result.tree["truncated"] == nil)
        #expect(result.tree["children"] == nil)
    }

    @Test
    func stopsAtTheDepthCeilingAndMarksTheNode() {
        let result = build(chain(depth: 5), limits: AXTreeLimits(maxDepth: 2, maxNodes: 1_000))
        #expect(result.truncated)

        // root(0) → child(1) → child(2, marked, children dropped)
        let level1 = (result.tree["children"] as? [[String: Any]])?.first
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
        #expect(result.tree["truncated"] as? Bool == true)
        #expect(childRoles(result.tree) == ["kid0", "kid1"])
    }

    /// The budget is global, not per-level: a deep-but-narrow tree exhausts
    /// it just as a wide one does.
    @Test
    func theNodeBudgetIsSharedAcrossTheWholeWalk() {
        let result = build(chain(depth: 10), limits: AXTreeLimits(maxDepth: 100, maxNodes: 4))
        #expect(result.truncated)

        var node: [String: Any]? = result.tree
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
            shouldDescend: { node, _ in node["role"] as? String != "closed" }
        )

        // A declined subtree is not truncation: nothing ran out.
        #expect(result.truncated == false)
        #expect(childRoles(result.tree) == ["closed", "open"])

        let kids = try #require(result.tree["children"] as? [[String: Any]])
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
        _ = build(
            root: tree,
            limits: AXTreeLimits(maxDepth: 10, maxNodes: 100),
            attributes: { ["role": $0.name] },
            children: {
                read.append($0.name)
                return $0.kids
            },
            shouldDescend: { node, _ in node["role"] as? String != "closed" }
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
            shouldDescend: { node, index in
                seen[node["role"] as? String ?? "?"] = index
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

        #expect(result.tree["skipped"] == nil)
        #expect(childRoles(result.tree) == ["kid"])

        let kid = (result.tree["children"] as? [[String: Any]])?.first
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

        let leaf = (result.tree["children"] as? [[String: Any]])?.first
        #expect(leaf?["skipped"] as? Bool == true)
    }

    @Test
    func defaultLimitsAreBoundedAndPositive() {
        #expect(AXTreeLimits.default.maxDepth > 0)
        #expect(AXTreeLimits.default.maxNodes > 0)
    }
}
