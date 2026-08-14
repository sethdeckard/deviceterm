// SPDX-License-Identifier: GPL-3.0-or-later
//
// Help topics for the verbs that drive a device: touch, hardware input,
// and accessibility inspection.
//
// This is a behavior-grouping extension, not a conformance split. The
// catalog's prose is partitioned the way the overview partitions it, so a
// help edit touches one file rather than a single long one.

extension HelpCatalog {
    static let driveTopics: [HelpTopic] = [
        HelpTopic(
            "tap",
            .command(.drive),
            summary: "Single discrete tap",
            detail: """
              tap <x> <y>
                  Single discrete tap.
                  Example: deviceterm tap 0.5 0.5
            """
        ),
        HelpTopic(
            "swipe",
            .command(.drive),
            summary: "Interpolated drag between two points",
            detail: """
              swipe <fromX> <fromY> <toX> <toY> [--duration <ms>] [--hold <ms>]
                  Interpolated drag at ~60 Hz. Default 200 ms. Durations
                  below the one-frame floor (32 ms) collapse to a tap-shape
                  wire; the daemon surfaces this via `dispatched=tap` so
                  callers can detect the silent promotion. `--hold <ms>` adds
                  an active dwell at the end point (the finger keeps being
                  reported, decelerated to a stop, before lifting).
                  Example: deviceterm swipe 0.5 0.8 0.5 0.2 --duration 250
            """
        ),
        HelpTopic(
            "long-press",
            .command(.drive),
            summary: "Down at a point, hold, up at the same point",
            detail: """
              long-press <x> <y> [--duration <ms>]
                  Down at point, hold, up at the same point. Default 500 ms
                  (matches iOS's UIKit long-press threshold).
                  Example: deviceterm long-press 0.5 0.5 --duration 800
            """
        ),
        HelpTopic(
            "pinch",
            .command(.drive),
            summary: "Two-finger interpolated path",
            detail: """
              pinch <f1x> <f1y> <f2x> <f2y> <tf1x> <tf1y> <tf2x> <tf2y> \\
                    [--duration <ms>]
                  Two-finger interpolated path from (f1,f2) to (tf1,tf2).
                  Default 300 ms.
                  Example: deviceterm pinch 0.45 0.5 0.55 0.5  0.30 0.5 0.70 0.5
            """
        ),
        HelpTopic(
            "app-switcher",
            .command(.drive),
            summary: "Open the iOS App Switcher",
            detail: """
              app-switcher
                  Open the iOS App Switcher with an edge-tagged swipe up from
                  the bottom edge with a dwell. That is a system gesture,
                  not a content swipe (portrait). A physical device that
                  doesn't support the edge gesture falls back to a
                  consumer-HID Home double-press.
                  Example: deviceterm app-switcher
            """
        )
    ]

    static let hardwareTopics: [HelpTopic] = [
        HelpTopic(
            "button",
            .command(.hardware),
            summary: "Press a hardware button",
            detail: """
              button <home|lock|side|apple-pay|siri|digital-crown>
                  Press a hardware button. `digital-crown` is the press-in
                  click on watchOS sims; rotation lives on `crown`. Names
                  are accepted in kebab-case (canonical), snake_case,
                  camelCase, or all lowercase.
                  Example: deviceterm button home
            """
        ),
        HelpTopic(
            "key",
            .command(.hardware),
            summary: "Send a kVK virtual key code down or up",
            detail: """
              key <keyCode> <down|up>
                  kVK virtual key code (the value of NSEvent.keyCode, e.g.
                  0x30 for Tab). Daemon translates kVK to USB HID. Discrete
                  events; pair each `down` with a matching `up`.
                  Example: deviceterm key 0x30 down; deviceterm key 0x30 up
            """
        ),
        HelpTopic(
            "text",
            .command(.hardware),
            summary: "Type an ASCII string",
            detail: """
              text <string>
                  Type an ASCII string. Each character maps to a kVK
                  keypress. Unsupported characters surface as an error
                  carrying the offending character so the caller can split
                  or filter rather than silently lose input.
                  Example: deviceterm text "hello world"
            """
        ),
        HelpTopic(
            "rotate",
            .command(.hardware),
            summary: "Set device orientation",
            detail: """
              rotate <portrait|portrait-upside-down|landscape-left|landscape-right>
                  Set device orientation. Names match UIKit's
                  UIDeviceOrientation; kebab-case (canonical), snake_case,
                  camelCase, and all lowercase are all accepted.
                  Example: deviceterm rotate landscape-left

              rotate <left|right>
                  Rotate 90 degrees from where DeviceTerm last put the
                  device, the same step the Device menu's Rotate Left and
                  Rotate Right take. DeviceTerm tracks only rotations it
                  performed, so an app that forces its own orientation
                  leaves that base stale.
                  Example: deviceterm rotate left
            """
        ),
        HelpTopic(
            "crown",
            .command(.hardware),
            summary: "Rotate the watchOS Digital Crown",
            detail: """
              crown <delta> [--velocity <v>] [--duration <ms>]
                  Rotate the watchOS Digital Crown. `delta` is signed: sign
                  is direction (positive = forward/down), magnitude is
                  distance in the bridge's raw crown unit (~1 unit per
                  physical detent at sensitivity .medium).

                  `--duration` > 0 sub-steps the rotation at ~60 Hz for a
                  smooth scroll; 0 (default) sends the whole delta at once.

                  `--velocity` is accepted on the wire for forward-compat
                  but is silently ignored at the daemon, because the
                  SimulatorKit crown builder takes only a delta.

                  For fine placement on tight SwiftUI Float bindings like
                  `.digitalCrownRotation(in: 0...1, by: 0.005)` use the
                  single-shot form `deviceterm crown N` (omit --duration). N
                  = 1..8 maps to roughly 0.18..0.95 of the binding range
                  on sensitivity .medium. The streaming --duration path
                  silently no-ops below the watchOS recognizer's
                  coalescing floor (~0.97-1.08 units per event in the
                  recorded configuration at ~60 Hz).
                  Examples:
                    deviceterm crown 5                        # fine placement
                    deviceterm crown 100 --duration 1500      # smooth scroll
            """
        )
    ]

    static let inspectTopics: [HelpTopic] = [
        HelpTopic(
            "ax",
            .command(.inspect),
            summary: "Dump the accessibility tree, one point, or a grid sweep",
            detail: """
              ax tree
                  Dump the frontmost iOS app's accessibility tree as JSON.
                  On watchOS the bridge's accessibilityChildren walk often
                  returns empty by design; the response carries a `note`
                  field pointing at `ax sweep` as the workaround.
                  Example: deviceterm ax tree

              ax point <x> <y>
                  Single AX element at a normalized point. Same shape as
                  `ax tree` minus children.
                  Example: deviceterm ax point 0.5 0.5

              ax sweep [--step <0..1>]
                  Grid-walk the screen via objectAtPoint and aggregate
                  unique elements. Default step 0.05; clamped into
                  [0.01, 0.5]. Result mirrors `ax tree` shape with a
                  synthetic root role `AXSweepRoot`. Use when `ax tree`
                  returns empty (the watchOS workaround).
                  Example: deviceterm ax sweep --step 0.04
            """
        )
    ]
}
