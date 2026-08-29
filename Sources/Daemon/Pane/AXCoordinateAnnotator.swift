// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Adds DeviceTerm-owned input coordinates to Apple accessibility nodes.
///
/// Apple frames stay in displayed points because callers need them for size
/// checks. `normalizedCenter` is the same displayed 0...1 coordinate accepted
/// by the input verbs. It is present only when the node has a finite origin,
/// positive finite dimensions, and an on-screen centre, so callers can pass it
/// back without another validity check.
enum AXCoordinateAnnotator {
    private struct Scale {
        let width: Double
        let height: Double

        init?(root: [String: Any]) {
            guard let frame = root["frame"] as? [String: Any],
                let width = Self.number(frame["w"]),
                let height = Self.number(frame["h"]),
                width.isFinite,
                height.isFinite,
                width > 0,
                height > 0
            else { return nil }
            self.width = width
            self.height = height
        }

        private static func number(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue
        }

        func normalizedCenter(of node: [String: Any]) -> (x: Double, y: Double)? {
            guard let frame = node["frame"] as? [String: Any],
                let x = Self.number(frame["x"]),
                let y = Self.number(frame["y"]),
                let frameWidth = Self.number(frame["w"]),
                let frameHeight = Self.number(frame["h"]),
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

    private static func node(
        _ node: [String: Any],
        scale: Scale?,
        recursively: Bool
    ) -> [String: Any] {
        var annotated = node
        // This key belongs to DeviceTerm. Never pass through a colliding
        // framework value whose units and validity we cannot guarantee.
        annotated.removeValue(forKey: "normalizedCenter")
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
