// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure recursive tree shaping with hard limits.
///
/// Split from `AXDumpService` so the traversal, the depth/node ceilings,
/// and the truncation and skip markers can be unit-tested against a fake
/// tree, with no live app and no Accessibility grant. The service supplies
/// the closures that read a real `AXUIElement`, and the policy deciding
/// which subtrees are worth descending into.
///
/// The limits are not cosmetic. An accessibility tree is a foreign process's
/// data structure and it can be enormous (a scrolled terminal). Bounding
/// depth and node count keeps one `ax dump` from hanging the harness or
/// returning a megabyte of JSON an agent cannot use.
///
/// A repeat is handled by `identity` rather than left to those ceilings. They
/// do bound a loop, but only by spending themselves on it: the walk emits
/// `maxDepth` copies of the repeating element and marks the result truncated,
/// and where that element has siblings, the subtree beneath them is re-walked
/// at every level and can exhaust the node budget before later branches are
/// reached. Stopping at the repeat leaves both for the rest of the tree.
enum AXTreeBuilder {
    /// Lists the attribute names whose reads failed on a node, `AXChildren`
    /// among them. Written by `attributes` for a node's own attributes, and
    /// here for its children. A name under this key means that value is
    /// unknown rather than absent.
    ///
    /// Names rather than a bare flag because the two failures call for
    /// different responses, and the caller is the one who knows which
    /// attribute its assertion rests on.
    static let unreadableKey = "unreadable"

    /// Marks a node that *is* one of its own ancestors, established by
    /// comparing element identity. The walk stops there; everything below it
    /// is already in the tree.
    ///
    /// Kept distinct from `"skipped"` on purpose. This marker asserts the
    /// element was met before, which only an identity comparison can show.
    /// A node cut by `AXTraversalPolicy` for its role is marked skipped
    /// instead, because that rule says nothing about which element it is.
    static let cycleKey = "cycle"

    /// Reads whose failure leaves the tree's shape or a node's identity in
    /// doubt, and so set `AXTreeResult.unreadable` for the whole walk.
    ///
    /// A failed `AXChildren` hides a subtree. A failed `AXRole` or
    /// `AXIdentifier` makes a node fail to match the predicate that describes
    /// it, which reads as a shorter list rather than as an error. What sets
    /// these three apart is that they decide whether a caller finds the node
    /// at all; every other attribute is a value read off a node already in
    /// hand, so a caller wanting it can see for itself that it did not
    /// arrive.
    ///
    /// Every other attribute is recorded on its node and goes no further. A
    /// title or a value that would not read leaves one assertion incomplete,
    /// but it cannot hide a node or misclassify one, and treating it as fatal
    /// refuses a whole tree over a single control publishing an unreadable
    /// icon.
    static let structuralAttributes: Set<String> = [
        AXAttribute.children,
        AXAttribute.role,
        AXAttribute.identifier
    ]

    /// Walk `root` depth-first into a JSON-ready dictionary.
    ///
    /// Any node whose children were dropped, because the depth ceiling or
    /// the node budget was reached, is marked `"truncated": true`, and the
    /// overall result reports whether that happened anywhere. A caller can
    /// then tell "this app has no more children" from "we stopped looking."
    ///
    /// `children` returning nil means the read failed, as distinct from an
    /// element that has none. That node records `AXChildren` under
    /// `"unreadable"`, so a caller can tell "nothing there" from "we could not
    /// look". Folding the two together is how a timed-out read comes to
    /// serialize identically to an empty UI.
    ///
    /// The overall result reports whether any node failed a *structural or
    /// identifying* read; see `structuralAttributes` for which those are and
    /// why the rest stop at the node.
    ///
    /// `shouldDescend` is consulted for each child, given the attributes the
    /// walk just read for it, and never for the root, which is always walked. Declining emits the
    /// node marked `"skipped": true` and never asks for its children, a
    /// third state kept distinct from `truncated`: the walk stopped by
    /// policy, so raising the limits reveals no more. The marker reports
    /// what the walk did rather than what exists, so a declined node that
    /// turns out to be childless is marked all the same.
    ///
    /// `identity` names an element so the walk can tell it has met one
    /// before. A child already on the path from the root is emitted marked
    /// `"cycle": true` and not descended into: the tree still records that
    /// accessibility reported it, without walking the same subtree twice.
    /// Membership is of the *current path*, not of everything seen, because
    /// the same element legitimately appearing under two different parents is
    /// a shared node rather than a loop. It has no default: a default would
    /// have to invent an identity, and one that differed per call would
    /// disable the guard silently.
    static func build<Element>(
        root: Element,
        limits: AXTreeLimits = .default,
        attributes: (Element) -> [String: Any],
        children: (Element) -> [Element]?,
        identity: (Element) -> AnyHashable,
        shouldDescend: (
            _ attributes: [String: Any],
            _ siblingIndex: Int
        ) -> Bool = { _, _ in true }
    ) -> AXTreeResult {
        var budget = limits.maxNodes
        var truncated = false
        var unreadable = false
        var onPath: Set<AnyHashable> = []

        func visit(_ element: Element, depth: Int, siblingIndex: Int) -> [String: Any] {
            var node = attributes(element)
            budget -= 1
            // The policy reads what the walk already read, rather than going
            // back to the element. A second read can disagree with the first,
            // and a policy deciding on its own failed read would prune (or
            // fail to prune) a subtree the emitted node cannot account for.
            let descend = siblingIndex < 0 || shouldDescend(node, siblingIndex)
            // `attributes` records the names it could not read. Aggregate the
            // structural ones into the walk-wide flag, so a node whose role or
            // identifier is unknown is reported even when every `children`
            // read succeeded.
            if failedStructurally(node) { unreadable = true }

            // Identity is checked before the policy so a genuine repeat is
            // reported as one. Both arms stop the walk here, but only this one
            // has evidence that the element *is* an ancestor; the policy's
            // cutoff is a rule about roles and establishes nothing about which
            // element this is. Checked after `attributes` so the repeat is
            // still described, and before `children` so the loop is never
            // entered.
            let key = identity(element)
            guard onPath.insert(key).inserted else {
                node[cycleKey] = true
                return node
            }
            defer { onPath.remove(key) }

            guard descend else {
                node["skipped"] = true
                return node
            }

            guard let kids = children(element) else {
                unreadable = true
                mark(&node, unreadable: AXAttribute.children)
                return node
            }
            guard !kids.isEmpty else { return node }

            if depth >= limits.maxDepth {
                truncated = true
                node["truncated"] = true
                return node
            }

            var emitted: [[String: Any]] = []
            emitted.reserveCapacity(kids.count)
            for (index, kid) in kids.enumerated() {
                if budget <= 0 {
                    truncated = true
                    node["truncated"] = true
                    break
                }
                emitted.append(visit(kid, depth: depth + 1, siblingIndex: index))
            }
            if !emitted.isEmpty { node["children"] = emitted }
            return node
        }

        // The root always costs one node, even when `maxNodes` is 0: an
        // empty dictionary would be a less useful answer than a bare root.
        // A negative sibling index marks the root, which is never offered to
        // the policy.
        let tree = visit(root, depth: 0, siblingIndex: -1)
        return AXTreeResult(tree: tree, truncated: truncated, unreadable: unreadable)
    }

    /// Record `attribute` on `node` as a read that failed.
    ///
    /// Additive, because a node can fail several reads and each one is a
    /// separate thing the caller may or may not care about. Repeats are
    /// dropped so the list stays a set of names.
    static func mark(_ node: inout [String: Any], unreadable attribute: String) {
        var names = node[unreadableKey] as? [String] ?? []
        guard !names.contains(attribute) else { return }
        names.append(attribute)
        node[unreadableKey] = names
    }

    /// Whether any read this node records as failed was a structural or
    /// identifying one.
    private static func failedStructurally(_ node: [String: Any]) -> Bool {
        guard let names = node[unreadableKey] as? [String] else { return false }
        return names.contains(where: structuralAttributes.contains)
    }
}
