// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.input.fold` parameters: where to put a foldable device's hinge.
public struct FoldParams: Codable, Sendable {
    public let paneId: String
    /// Hinge angle in degrees, `0` shut and `180` flat.
    ///
    /// Degrees rather than a posture name because the hinge is continuous. A
    /// caller that wants a named position resolves it through
    /// `FoldPosture.degrees` before sending, so no two callers can drift on
    /// what a name means.
    public let degrees: Double

    public init(paneId: String, degrees: Double) {
        self.paneId = paneId
        self.degrees = degrees
    }
}
