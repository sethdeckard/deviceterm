// SPDX-License-Identifier: GPL-3.0-or-later

/// One contact in a live `pane.input.multitouch` frame. `id` is a
/// stable per-finger identity for forward-compat (future N-finger
/// support); the daemon keys off array order (`points[0]` = finger 1,
/// `points[1]` = finger 2).
public struct MultitouchPoint: Codable, Sendable {
    public let id: Int
    /// Normalized display coords; off-[0,1] values are passed to
    /// CoreSimulator as-is (mirrored fingers can land off-screen).
    public let x: Double
    public let y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}
