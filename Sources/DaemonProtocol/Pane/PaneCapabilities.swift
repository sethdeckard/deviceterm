// SPDX-License-Identifier: GPL-3.0-or-later

/// What input/control verbs a pane's device supports, reported per
/// pane on `pane.create` / `device.attach` and `panes.list`. The daemon
/// hosts a mix of pane kinds at once (a CoreSimulator pane supports
/// everything, a physical-device pane a subset), so capability is a
/// **per-pane** property, not a daemon-wide one. The GUI gates
/// applicable input and control actions on these flags; `location` only
/// reports backend support.
///
/// Each flag covers a verb family: `touch` is tap/touch/swipe/
/// longPress/pinch/multitouch; `key`/`text` are the keyboard verbs;
/// `button` is the hardware buttons; `rotate` is device orientation;
/// `crown` is the watch Digital Crown; `accessibility` is the `pane.ax.*`
/// tree/element/sweep family; `location` is simulated GPS position.
///
/// The daemon always emits a full set, but the *carrying* wire fields on
/// `PaneCreateResponse` / `PanesListEntry` are optional so a peer that
/// omits the block still decodes; a missing block means "unknown", and
/// clients fall back to `missingBlockFallback`.
///
/// When the added `location` key is absent it decodes as `false` (see
/// `init(from:)`), so no capability is assumed on a peer's behalf.
public struct PaneCapabilities: Codable, Sendable, Equatable {
    /// Everything a CoreSimulator pane supports.
    public static let simulator = PaneCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: true,
        accessibility: true,
        location: true
    )

    /// What a client assumes when the wire omits the capability block
    /// entirely.
    ///
    /// A missing block provides no evidence of location support, so
    /// `location` is false. The original flags remain true.
    public static let missingBlockFallback = PaneCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: true,
        accessibility: true,
        location: false
    )

    public var touch: Bool
    public var key: Bool
    public var text: Bool
    public var button: Bool
    public var rotate: Bool
    public var crown: Bool
    public var accessibility: Bool
    public var location: Bool

    public init(
        touch: Bool,
        key: Bool,
        text: Bool,
        button: Bool,
        rotate: Bool,
        crown: Bool,
        accessibility: Bool,
        location: Bool
    ) {
        self.touch = touch
        self.key = key
        self.text = text
        self.button = button
        self.rotate = rotate
        self.crown = crown
        self.accessibility = accessibility
        self.location = location
    }

    /// `location` decodes as absent ⇒ `false`; the other fields are
    /// required.
    ///
    /// Synthesized decoding would require `location` and reject the
    /// enclosing response when it is absent, because the failure lands on
    /// the inner object rather than the optional field carrying it.
    /// Defaulting to `false` keeps such a block decodable and keeps the
    /// answer honest: a peer that never mentioned location cannot be
    /// assumed to support it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        touch = try container.decode(Bool.self, forKey: .touch)
        key = try container.decode(Bool.self, forKey: .key)
        text = try container.decode(Bool.self, forKey: .text)
        button = try container.decode(Bool.self, forKey: .button)
        rotate = try container.decode(Bool.self, forKey: .rotate)
        crown = try container.decode(Bool.self, forKey: .crown)
        accessibility = try container.decode(Bool.self, forKey: .accessibility)
        location = try container.decodeIfPresent(Bool.self, forKey: .location) ?? false
    }
}
