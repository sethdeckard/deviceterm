// SPDX-License-Identifier: GPL-3.0-or-later
//
// LongPressParams: wire shape for `pane.input.longPress`.
//
// A press held stationary at normalized coords for `durationMs`.

public struct LongPressParams: Codable, Sendable {
    public let paneId: String
    public let x: Double
    public let y: Double
    public let durationMs: Int?

    public init(paneId: String, x: Double, y: Double, durationMs: Int?) {
        self.paneId = paneId
        self.x = x
        self.y = y
        self.durationMs = durationMs
    }
}
