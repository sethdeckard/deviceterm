// SPDX-License-Identifier: GPL-3.0-or-later

/// The canonical App Switcher gesture, defined once
/// so the GUI menu action and the `deviceterm app-switcher` CLI verb can't
/// drift apart.
///
/// The iOS home-indicator / App-Switcher swipe is a SpringBoard **system
/// edge gesture**, not an ordinary touch. The simulator routes a drag to
/// it only when the touch is tagged with the screen edge it originates
/// from (`IndigoHIDEdge`). So this is an **edge swipe** (`edge: bottom`),
/// driven through `pane.input.edgeSwipe`, since a plain touch swipe is eaten by
/// the foreground app (it just scrolls).
///
/// Coords are in displayed space, as everywhere on the input surface:
/// (0.5, ~1.0) is the bottom-edge center of what the viewer sees, (0.5,
/// 0.5) is mid-screen. Both the coordinates and the originating edge's
/// `IndigoHIDEdge` value rotate with the device, and the daemon resolves
/// them together at the input boundary (`plan(for:)`) from its
/// authoritative presentation orientation, rather than from a client
/// snapshot that may be stale.
public enum AppSwitcherGesture {
    /// How to play a displayed-bottom-edge swipe on a turned device.
    ///
    /// The tag names the native edge the contact originates from and the
    /// coordinates have to land on that same edge, so the two are
    /// decided together rather than separately; see `plan(for:)`.
    public struct Plan: Sendable, Equatable {
        /// Orientation the displayed coordinates are rotated through.
        public let orientation: Orientation
        /// `IndigoHIDEdge` value to tag the contacts with.
        public let edge: Int

        public init(orientation: Orientation, edge: Int) {
            self.orientation = orientation
            self.edge = edge
        }
    }

    /// `IndigoHIDEdge` value for the bottom edge, the live-confirmed
    /// value that routes the drag to the system home / App-Switcher
    /// recognizer. (Other edges' values are not yet verified.)
    public static let edge = 3
    /// Swipe origin: bottom-edge center.
    public static let fromX = 0.5
    public static let fromY = 0.99
    /// Swipe target: mid-screen. The dwell happens here.
    public static let toX = 0.5
    public static let toY = 0.5
    /// Upward-motion time before the dwell.
    public static let durationMs = 600
    /// Active dwell at the target before lifting, which makes the gesture
    /// land in the App Switcher rather than continuing to Home.
    public static let holdMs = 700

    /// Lower bound, in displayed unit-Y, of the bottom-edge band that
    /// arms the system gesture. A live mouse drag whose **start** point sits at or
    /// below this line (i.e. within the home-indicator strip at the
    /// bottom of the displayed screen) is treated as an edge gesture;
    /// anything higher is an ordinary touch. Tunable; refined live.
    public static let bottomEdgeBandMinY = 0.96

    /// `IndigoHIDEdge` value tagging the **displayed bottom** edge for a
    /// given device orientation, or `nil` when that orientation's value
    /// isn't live-confirmed yet (caller falls back to a plain touch, with no
    /// edge tag).
    ///
    /// iOS always renders the home indicator along the bottom of the
    /// *current* interface orientation, so a live bottom-edge drag tags
    /// its contacts with the edge value for that orientation. The values
    /// are live-confirmed (iPhone sim, an app open, drag opens the
    /// switcher): portrait = 3, landscape-left = 2, landscape-right = 4.
    /// **Upside-down has no home-gesture edge**: every `IndigoHIDEdge`
    /// value was swept and none armed the recognizer, so it returns
    /// `nil`. The two callers treat that differently: a live edge touch
    /// degrades to a plain touch, while `plan(for:)` falls back to the
    /// portrait macro. The simulator's IOSurface
    /// is portrait-native, so the contact *coordinates* are mapped into
    /// that frame by `Orientation.surfacePoint(displayedX:displayedY:)`;
    /// this answers only the edge *value*.
    public static func edge(for orientation: Orientation) -> Int? {
        switch orientation {
        case .portrait:
            return edge            // bottom = 3

        case .landscapeLeft:
            return 2

        case .landscapeRight:
            return 4

        case .portraitUpsideDown:
            return nil             // no home-gesture edge (swept, none work)
        }
    }

    /// Resolve the orientation and edge tag to play the gesture with,
    /// given the pane's live presentation orientation.
    ///
    /// An orientation with no confirmed home-gesture edge (upside-down)
    /// degrades to the portrait gesture wholesale. Rotating the
    /// coordinates 180° while tagging them with the portrait edge would
    /// have the tag and the swipe disagree about which edge the contact
    /// came from, and a disagreeing pair arms nothing.
    public static func plan(for orientation: Orientation) -> Plan {
        guard let tag = edge(for: orientation) else {
            return Plan(orientation: .portrait, edge: edge)
        }
        return Plan(orientation: orientation, edge: tag)
    }
}
