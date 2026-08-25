// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `pane.input.rotate`.
///
/// Sets device orientation, either absolutely (`orientation`) or one 90°
/// step from where the daemon believes the device is (`direction`).
/// Exactly one is required. Both stay raw strings on the wire so the
/// daemon validates them in the handler and an unknown value surfaces as
/// `invalidParams` with the accepted set, rather than a generic decode
/// failure. The both-set and neither-set cases are rejected there too:
/// the wire permits them, `RotationTarget` doesn't.
public struct RotateParams: Codable, Sendable {
    public let paneId: String
    /// One of `portrait`, `portraitUpsideDown`, `landscapeLeft`,
    /// `landscapeRight`. Names match UIKit's `UIDeviceOrientation`. Nil
    /// on a relative request.
    public let orientation: String?
    /// `left` or `right`. Nil on an absolute request.
    public let direction: String?

    /// Build from a resolved target, so a first-party producer can't
    /// set both fields or neither.
    public init(paneId: String, target: RotationTarget) {
        self.paneId = paneId
        orientation = target.orientation?.rawValue
        direction = target.direction?.rawValue
    }

    /// Build the raw wire shape, including the combinations the handler
    /// rejects. For callers modelling a foreign or malformed client;
    /// first-party code takes the target initializer.
    public init(paneId: String, orientation: String?, direction: String?) {
        self.paneId = paneId
        self.orientation = orientation
        self.direction = direction
    }
}
