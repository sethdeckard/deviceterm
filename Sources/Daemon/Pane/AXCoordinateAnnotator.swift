// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Adds DeviceTerm-owned input coordinates to Apple accessibility nodes.
///
/// Apple frames stay in displayed points because callers need them for size
/// checks. `normalizedCenter` is the same displayed 0...1 coordinate accepted
/// by the input verbs. It is present only when the node has a finite origin,
/// positive finite dimensions, and an on-screen centre, so callers can pass it
/// back without another validity check.
///
/// `rootFrame` is the other half of the same contract, and the annotator only
/// vends it: it is the screen frame those centres were divided by, which
/// `PaneAccessibility` stamps on a point response and on the sweep root so a
/// caller can carry a normalized coordinate back to displayed points without
/// re-reading the screen.
enum AXCoordinateAnnotator {
    private struct Scale {
        let width: Double
        let height: Double

        init?(root: [String: Any]) {
            guard let frame = root["frame"] as? [String: Any],
                let width = AXCoordinateAnnotator.number(frame["w"]),
                let height = AXCoordinateAnnotator.number(frame["h"]),
                width.isFinite,
                height.isFinite,
                width > 0,
                height > 0
            else { return nil }
            self.width = width
            self.height = height
        }

        func normalizedCenter(of node: [String: Any]) -> (x: Double, y: Double)? {
            guard let frame = node["frame"] as? [String: Any],
                let x = AXCoordinateAnnotator.number(frame["x"]),
                let y = AXCoordinateAnnotator.number(frame["y"]),
                let frameWidth = AXCoordinateAnnotator.number(frame["w"]),
                let frameHeight = AXCoordinateAnnotator.number(frame["h"]),
                x.isFinite,
                y.isFinite,
                frameWidth.isFinite,
                frameHeight.isFinite,
                frameWidth > 0,
                frameHeight > 0
            else { return nil }
            let normalizedX = (x + frameWidth / 2) / width
            let normalizedY = (y + frameHeight / 2) / height
            guard normalizedX.isFinite,
                normalizedY.isFinite,
                (0...1).contains(normalizedX),
                (0...1).contains(normalizedY)
            else { return nil }
            return (normalizedX, normalizedY)
        }
    }

    /// Annotate a recursive frontmost tree using its root frame as the screen.
    static func tree(_ tree: [String: Any]) -> [String: Any] {
        node(tree, scale: Scale(root: tree), recursively: true)
    }

    /// Annotate one flat point/sweep element using a frontmost tree's frame.
    static func element(
        _ element: [String: Any],
        rootTree: [String: Any]
    ) -> [String: Any] {
        node(element, scale: Scale(root: rootTree), recursively: false)
    }

    /// The frontmost root's frame, in the same `{x, y, w, h}` shape a node
    /// carries, or nil when it cannot be published.
    ///
    /// `w` and `h` are the exact divisor every `normalizedCenter` in the same
    /// response was produced from, so a caller who wants displayed points back
    /// multiplies by them instead of issuing a second `ax tree` and trusting
    /// the screen to have held still between the two reads.
    ///
    /// Rebuilt from validated numbers rather than passed through. The bridge
    /// writes `accessibilityFrame` into the tree as it finds it, and a null
    /// frame carries an infinite origin. `JSONSerialization` does not return an
    /// error for a non-finite number; it raises an Objective-C exception that
    /// Swift cannot catch, so echoing one would abort the daemon rather than
    /// fail the request.
    ///
    /// Nil covers a root `Scale` rejected, which is a root that produced no
    /// `normalizedCenter` anywhere in the response either, and also a root
    /// whose `w`/`h` are usable while its origin is not. That second case can
    /// still carry centres, because `Scale` never reads the root's origin,
    /// though a node's own geometry has to be usable for one. Withhold the
    /// frame there and a caller loses a convenience; publish a repaired one
    /// and they get a number that is quietly wrong.
    static func rootFrame(of root: [String: Any]) -> [String: Double]? {
        guard Scale(root: root) != nil,
            let frame = root["frame"] as? [String: Any],
            let x = number(frame["x"]),
            let y = number(frame["y"]),
            let width = number(frame["w"]),
            let height = number(frame["h"]),
            x.isFinite,
            y.isFinite
        else { return nil }
        return ["x": x, "y": y, "w": width, "h": height]
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func node(
        _ node: [String: Any],
        scale: Scale?,
        recursively: Bool
    ) -> [String: Any] {
        var annotated = node
        // Both keys belong to DeviceTerm. Never pass through a colliding
        // framework value whose units and validity we cannot guarantee.
        // `rootFrame` is stripped here rather than where it is stamped so the
        // guarantee also covers `ax tree` nodes and sweep children, which are
        // never meant to carry one.
        annotated.removeValue(forKey: "normalizedCenter")
        annotated.removeValue(forKey: "rootFrame")
        if let center = scale?.normalizedCenter(of: node) {
            annotated["normalizedCenter"] = ["x": center.x, "y": center.y]
        }
        if recursively, let children = node["children"] as? [Any] {
            annotated["children"] = children.map { child -> Any in
                guard let child = child as? [String: Any] else { return child }
                return self.node(child, scale: scale, recursively: true)
            }
        }
        return annotated
    }
}
