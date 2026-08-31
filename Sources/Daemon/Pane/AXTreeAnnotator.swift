// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Foundation

/// Pure decisions about the explanatory `note` the daemon may inject into an
/// `ax tree` response: which point is worth hit-testing, and which note the
/// result earns.
///
/// Split out of `PaneCoordinator.accessibilityTree(paneId:)` so both halves
/// are unit-testable without a live sim. The live test sees the un-annotated
/// bridge dict; these helpers cover the daemon-side branch. The hit-test
/// itself belongs to `PaneAccessibility`, which owns the backend: this type
/// says where to look and what the answer means, never how to ask.
///
/// Two rules, and `note`/`noteCode` hold one value, so they are a priority
/// order rather than a set. A watchOS tree whose walk came back empty is
/// inference from a known platform limitation. Anything else is evidence: a
/// point no node covers, hit-tested, answering with an element the walk did
/// not produce.
enum AXTreeAnnotator {
    /// A validated accessibility frame. Every component must be finite, and
    /// the dimensions positive, so a comparison against it cannot silently
    /// answer from a `CGRectNull` origin or a zero-sized box.
    private struct Frame {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init?(_ value: Any?) {
            guard let frame = value as? [String: Any],
                let x = Self.number(frame["x"]),
                let y = Self.number(frame["y"]),
                let width = Self.number(frame["w"]),
                let height = Self.number(frame["h"]),
                width > 0,
                height > 0
            else { return nil }
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        private static func number(_ value: Any?) -> Double? {
            guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else {
                return nil
            }
            return number
        }

        func contains(_ point: CGPoint) -> Bool {
            point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
        }

        /// Inside `other`'s bounds and not equal to them.
        func isStrictlyInside(_ other: Frame) -> Bool {
            guard x >= other.x,
                y >= other.y,
                x + width <= other.x + other.width,
                y + height <= other.y + other.height
            else { return false }
            return !(x == other.x && y == other.y && width == other.width && height == other.height)
        }
    }

    /// Where to hit-test to test `tree` for completeness, as a normalized
    /// point in displayed space, or nil when there is nothing to learn or no
    /// way to map it.
    ///
    /// The caller performs the query and hands the result to `annotate`. Nil
    /// covers three cases: a watchOS tree that has already earned its own
    /// note, so a bridge call on every `ax tree` would buy nothing; a root
    /// with no usable frame, which leaves the point unmappable; and a tree
    /// that already describes something at the sample point, which is the
    /// ordinary healthy screen and the reason the probe costs nothing there.
    ///
    /// The point is the centre. The top of the screen is the status bar, whose
    /// elements belong to SpringBoard and appear in no app's tree, so a probe
    /// there would report every screen incomplete; sampling anywhere else
    /// means re-checking that band first.
    static func probePoint(for tree: [String: Any], family: DeviceFamily) -> CGPoint? {
        guard watchWalkCameBackEmpty(tree, family: family) == false,
            let root = Frame(tree["frame"])
        else { return nil }
        let centre = CGPoint(x: root.x + root.width / 2, y: root.y + root.height / 2)
        guard descendantCovers(centre, of: tree) == false else { return nil }
        return CGPoint(x: 0.5, y: 0.5)
    }

    /// Return `tree` with an `AXTreeNote` injected at top level when the
    /// (family, tree, probe) triple indicates a known limitation; otherwise
    /// return `tree` unchanged. Top-level placement puts the note next to
    /// `role` / `frame` / `children`, so agents read `tree.note` rather than
    /// walking children to find it.
    ///
    /// `probedElement` is what `probePoint`'s point hit-tested to, or nil when
    /// no probe was made or it found nothing.
    static func annotate(
        tree: [String: Any],
        family: DeviceFamily,
        probedElement: [String: Any]?
    ) -> [String: Any] {
        guard let note = note(for: tree, family: family, probedElement: probedElement) else {
            return tree
        }
        var annotated = tree
        // `note` is the sentence a human reads; `noteCode` is the token a
        // client branches on, so neither has to substring-match the other.
        annotated["note"] = note.rawValue
        annotated["noteCode"] = note.code
        return annotated
    }

    private static func note(
        for tree: [String: Any],
        family: DeviceFamily,
        probedElement: [String: Any]?
    ) -> AXTreeNote? {
        // Checked first, and still inference rather than evidence. When this
        // rule fires, `probePoint` has already declined to nominate a point,
        // so the daemon never arrives at the one below carrying a probe
        // result. A watch tree that does enumerate is probed like any other.
        // A caller that supplies both still gets a deterministic answer.
        if watchWalkCameBackEmpty(tree, family: family) {
            return .watchOSEnumerationUnsupported
        }
        guard let probedElement, provesIncompleteness(probedElement, of: tree) else { return nil }
        return .treeIncomplete
    }

    /// Whether `element` is proof that `tree` describes less than the screen
    /// holds. Two rejections, neither carrying a tuned number.
    ///
    /// Visible to `PaneAccessibility` so it can ask before deciding whether a
    /// finding is worth confirming. A hit-test result the rules reject costs
    /// no second read, because there is no claim to stand behind.
    static func provesIncompleteness(
        _ element: [String: Any],
        of tree: [String: Any]
    ) -> Bool {
        // A frame equal to the root's is what `objectAtPoint:` answers with
        // when nothing specific sits under the point: it falls back to an
        // enclosing container. Requiring the frame to be strictly inside the
        // root separates a found element from that fallback without a fraction
        // to pick. An element reaching past the root is likewise not a finding.
        guard let root = Frame(tree["frame"]),
            let found = Frame(element["frame"]),
            found.isStrictlyInside(root)
        else { return false }
        // An element the walk already produced proves the opposite of the
        // note. Identity is the sweep's, which exists for this same question
        // when one element answers several adjacent grid points.
        let key = AXSweep.dedupKey(element: element)
        return contains(key: key, in: tree) == false
    }

    /// Whether the recursive walk returned nothing on a device family where
    /// that is a platform limitation rather than an empty screen.
    private static func watchWalkCameBackEmpty(
        _ tree: [String: Any],
        family: DeviceFamily
    ) -> Bool {
        guard family == .watch, let children = tree["children"] as? [Any] else { return false }
        return children.isEmpty
    }

    /// Whether any node below `tree`'s root has a frame containing `point`.
    ///
    /// The root is excluded deliberately. Its frame spans the screen, so
    /// counting it would cover every point and no tree would ever be probed.
    private static func descendantCovers(_ point: CGPoint, of tree: [String: Any]) -> Bool {
        childDictionaries(of: tree).contains { nodeOrDescendantCovers(point, of: $0) }
    }

    private static func nodeOrDescendantCovers(_ point: CGPoint, of node: [String: Any]) -> Bool {
        if let frame = Frame(node["frame"]), frame.contains(point) { return true }
        return childDictionaries(of: node).contains { nodeOrDescendantCovers(point, of: $0) }
    }

    /// Whether any node in `tree`, root included, carries `key`.
    private static func contains(key: String, in tree: [String: Any]) -> Bool {
        if AXSweep.dedupKey(element: tree) == key { return true }
        return childDictionaries(of: tree).contains { contains(key: key, in: $0) }
    }

    /// A node's children that are themselves nodes. The bridge writes an array
    /// of dicts; anything else in there is skipped rather than trusted.
    private static func childDictionaries(of node: [String: Any]) -> [[String: Any]] {
        (node["children"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }
}
