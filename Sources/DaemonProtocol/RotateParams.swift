// SPDX-License-Identifier: GPL-3.0-or-later
//
// RotateParams: wire shape for `pane.input.rotate`.
//
// Sets device orientation. `orientation` stays a raw string on the
// wire; the daemon validates it against `Orientation(rawValue:)` in
// the handler so an unknown value surfaces as `invalidParams` with the
// accepted set, rather than a generic decode failure.

public struct RotateParams: Codable, Sendable {
    public let paneId: String
    /// One of `portrait`, `portraitUpsideDown`, `landscapeLeft`,
    /// `landscapeRight`. Names match UIKit's `UIDeviceOrientation`.
    public let orientation: String

    public init(paneId: String, orientation: String) {
        self.paneId = paneId
        self.orientation = orientation
    }
}
