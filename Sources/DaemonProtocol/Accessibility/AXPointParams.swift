// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `pane.ax.point`.
///
/// Requests the accessibility element at a normalized display point.
public struct AXPointParams: Codable, Sendable {
    public let paneId: String
    /// Normalized display coords (0..1).
    public let x: Double
    public let y: Double

    public init(paneId: String, x: Double, y: Double) {
        self.paneId = paneId
        self.x = x
        self.y = y
    }
}
