// SPDX-License-Identifier: GPL-3.0-or-later
//
// AXTreeBuilder: pure recursive tree shaping with hard limits.
//
// Split from `AXDumpService` so the traversal, the depth/node ceilings,
// and the truncation marker can be unit-tested against a fake tree, with
// no live app and no Accessibility grant. The service supplies the two
// closures that read a real `AXUIElement`.
//
// The limits are not cosmetic. An accessibility tree is a foreign process's
// data structure: it can be enormous (a scrolled terminal), and a
// misbehaving app can even present a cycle. Bounding depth and node count
// keeps one `ax dump` from hanging the harness or returning a megabyte of
// JSON an agent cannot use.

import Foundation

struct AXTreeLimits: Equatable, Sendable {
    static let `default` = AXTreeLimits(maxDepth: 24, maxNodes: 4_000)

    /// How deep to descend before stopping. The root is depth 0.
    let maxDepth: Int
    /// Total nodes to emit across the whole walk.
    let maxNodes: Int
}

enum AXTreeBuilder {
    /// Walk `root` depth-first into a JSON-ready dictionary.
    ///
    /// Any node whose children were dropped, because the depth ceiling or
    /// the node budget was reached, is marked `"truncated": true`, and the
    /// overall result reports whether that happened anywhere. A caller can
    /// then tell "this app has no more children" from "we stopped looking."
    static func build<Element>(
        root: Element,
        limits: AXTreeLimits = .default,
        attributes: (Element) -> [String: Any],
        children: (Element) -> [Element]
    ) -> (root: [String: Any], truncated: Bool) {
        var budget = limits.maxNodes
        var truncated = false

        func visit(_ element: Element, depth: Int) -> [String: Any] {
            var node = attributes(element)
            budget -= 1

            let kids = children(element)
            guard !kids.isEmpty else { return node }

            if depth >= limits.maxDepth {
                truncated = true
                node["truncated"] = true
                return node
            }

            var emitted: [[String: Any]] = []
            emitted.reserveCapacity(kids.count)
            for kid in kids {
                if budget <= 0 {
                    truncated = true
                    node["truncated"] = true
                    break
                }
                emitted.append(visit(kid, depth: depth + 1))
            }
            if !emitted.isEmpty { node["children"] = emitted }
            return node
        }

        // The root always costs one node, even when `maxNodes` is 0: an
        // empty dictionary would be a less useful answer than a bare root.
        let tree = visit(root, depth: 0)
        return (tree, truncated)
    }
}
