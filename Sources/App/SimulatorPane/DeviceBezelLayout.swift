// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// Pure geometry for the simulator pane's device
/// frame. The wrapper view paints a programmatic bezel (rounded rect
/// + optional notch / crown sublayer) keyed off `DeviceFamily`; this
/// file owns the dimensions so the math tests without an AppKit view
/// or Metal context in scope.
///
/// One `layout(family:imageRect:)` entry point per call site. Returns
/// `nil` for tv (no bezel, letterbox stays as-is). Otherwise hands
/// back the bezel rect, its corner radius, and optional sub-rects for
/// the phone notch + watch Digital Crown. Sub-rects are positioned in
/// the same coordinate space as `imageRect` (the parent view's
/// flipped coordinates), so the caller can position layers directly.
struct DeviceBezelLayout: Equatable, Sendable {
    /// The outer bezel rect: the frame painted around the screen.
    let bezelRect: CGRect
    /// Bezel + screen-cutout corner radius. The bezel layer uses
    /// it for the outer rounded rect; the screen cutout inherits it
    /// minus the bezel inset so the inner edge curves with the
    /// outer.
    let cornerRadius: CGFloat
    /// Phone only: small dark rounded rect at top center. Visual,
    /// not interactive.
    let notchRect: CGRect?
    /// Phone notch corner radius, half of the notch height for a
    /// stadium shape.
    let notchCornerRadius: CGFloat?
    /// Watch only: Digital Crown bump on the right edge.
    /// `SimulatorContentView` hit-tests against this rect (read
    /// from the wrapper's `currentCrownRect` mirror) so a click
    /// inside it fires the wrapper's `onCrownPress` closure and
    /// vertical drags fire `onCrownUp`/`onCrownDown` detents.
    let crownRect: CGRect?
    /// Watch crown corner radius, half of the crown width for a
    /// pill shape.
    let crownCornerRadius: CGFloat?
}
