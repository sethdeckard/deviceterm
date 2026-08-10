// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppSwitcherGesture: the canonical App Switcher gesture, defined once
// so the GUI menu action and the `deviceterm app-switcher` CLI verb can't
// drift apart.
//
// The iOS home-indicator / App-Switcher swipe is a SpringBoard **system
// edge gesture**, not an ordinary touch. The simulator routes a drag to
// it only when the touch is tagged with the screen edge it originates
// from (`IndigoHIDEdge`). So this is an **edge swipe** (`edge: bottom`),
// driven through `pane.input.edgeSwipe`, since a plain touch swipe is eaten by
// the foreground app (it just scrolls). Live-confirmed on an iPhone 17
// Pro sim across Messages / Safari / Maps.
//
// Coords are in the simulator surface's portrait-native space: (0.5,
// ~1.0) is the bottom-edge center, (0.5, 0.5) is mid-screen. Portrait is
// the reference orientation; the originating edge, and its
// `IndigoHIDEdge` value, rotates with the device.

public enum AppSwitcherGesture {
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

    /// Lower bound (in displayed/oriented unit-Y, before
    /// `rotateOrientedToSurface`) of the bottom-edge band that arms the
    /// system gesture. A live mouse drag whose **start** point sits at or
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
    /// value was swept and none armed the recognizer, so it returns `nil`
    /// and the caller degrades to a plain touch. The simulator's IOSurface
    /// is portrait-native, so the contact *coordinates* are mapped back to
    /// the portrait frame by `SimGestureMath.rotateOrientedToSurface`;
    /// only the edge *value* varies by orientation.
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
}
