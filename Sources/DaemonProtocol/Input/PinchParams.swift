// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `pane.input.pinch`.
///
/// A two-finger pinch: each finger interpolates from its `from` point
/// to its `to` point over `durationMs`. All coords normalized 0..1.
public struct PinchParams: Codable, Sendable {
    public let paneId: String
    public let fromF1X: Double
    public let fromF1Y: Double
    public let fromF2X: Double
    public let fromF2Y: Double
    public let toF1X: Double
    public let toF1Y: Double
    public let toF2X: Double
    public let toF2Y: Double
    public let durationMs: Int?

    public init(
        paneId: String,
        fromF1X: Double,
        fromF1Y: Double,
        fromF2X: Double,
        fromF2Y: Double,
        toF1X: Double,
        toF1Y: Double,
        toF2X: Double,
        toF2Y: Double,
        durationMs: Int?
    ) {
        self.paneId = paneId
        self.fromF1X = fromF1X
        self.fromF1Y = fromF1Y
        self.fromF2X = fromF2X
        self.fromF2Y = fromF2Y
        self.toF1X = toF1X
        self.toF1Y = toF1Y
        self.toF2X = toF2X
        self.toF2Y = toF2Y
        self.durationMs = durationMs
    }
}
