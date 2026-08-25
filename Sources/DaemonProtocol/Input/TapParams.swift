// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `pane.input.tap`.
///
/// A discrete tap at normalized display coords.
public struct TapParams: Codable, Sendable {
    public let paneId: String
    /// Normalized display coords; (0, 0) is top-left, (1, 1) is
    /// bottom-right. The daemon doesn't enforce a 0..1 clamp:
    /// out-of-range values are passed to CoreSimulator as-is in
    /// case any future device exposes off-screen input regions.
    public let x: Double
    public let y: Double

    public init(paneId: String, x: Double, y: Double) {
        self.paneId = paneId
        self.x = x
        self.y = y
    }
}
