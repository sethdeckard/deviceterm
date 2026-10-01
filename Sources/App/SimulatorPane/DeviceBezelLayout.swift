// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// Pure geometry for the simulator pane's device
/// frame. The wrapper view paints a programmatic bezel (rounded rect
/// + optional crown sublayer) keyed off `DeviceFamily`; this
/// file owns the dimensions so the math tests without an AppKit view
/// or Metal context in scope.
///
/// One `layout(family:imageRect:panel:orientation:)` entry point per call
/// site. Returns `nil` for tv (no bezel, letterbox stays as-is). Otherwise
/// hands back the bezel rect, per-corner body and screen radii, and an
/// optional sub-rect for the watch Digital Crown. Sub-rects are positioned
/// in the same coordinate space as `imageRect` (the parent view's flipped
/// coordinates), so the caller can position layers directly.
struct DeviceBezelLayout: Equatable, Sendable {
    /// Four corner radii, named by where the viewer sees them.
    ///
    /// Four rather than one because a display is not always a rounded
    /// rectangle. A foldable's cover panel is a D: the two corners against
    /// the hinge spine are nearly square and the two opposite them are
    /// heavily rounded, and one radius can only be wrong at one end or the
    /// other.
    struct Corners: Equatable, Sendable {
        /// No rounding anywhere, for a pane that has no device frame to
        /// draw yet.
        static let square = Corners(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0)

        let topLeft: CGFloat
        let topRight: CGFloat
        let bottomLeft: CGFloat
        let bottomRight: CGFloat

        /// The largest of the four, for a caller that needs one number.
        var widest: CGFloat {
            max(max(topLeft, topRight), max(bottomLeft, bottomRight))
        }
    }

    /// The outer bezel rect: the frame painted around the screen.
    ///
    /// Built from a thickness per edge, which can place the display off
    /// centre in it.
    let bezelRect: CGRect
    /// The body's outer corner radii, used for the painted outline.
    ///
    /// Each is the display's radius at that corner plus the thinner of the
    /// two frame edges meeting there.
    let cornerRadii: Corners
    /// How far the display's own corners are rounded. The content view
    /// masks the picture to these, so they are what the viewer reads as
    /// the shape of the screen.
    let screenCornerRadii: Corners
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
