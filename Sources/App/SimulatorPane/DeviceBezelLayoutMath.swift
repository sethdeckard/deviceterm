// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

enum DeviceBezelLayoutMath {
    /// Which of a device's displays the frame is being drawn around.
    ///
    /// A foldable's two panels sit in different parts of the same body, so
    /// one family cannot describe both. The pane knows which panel is lit
    /// from the hinge events it already subscribes to.
    enum Panel: Sendable {
        /// The only display the device has.
        case standard
        /// A foldable's cover panel, outside the fold. Asymmetric: the
        /// hinge spine runs down one side of it and is thicker than the
        /// three plain edges.
        case foldableCover
        /// A foldable's inner panel, the one the hinge runs through.
        case foldableInner
    }

    /// One panel's frame: how thick it is on each of the device's own edges,
    /// and how far its display's corners are rounded.
    struct Profile: Sendable {
        /// Thickness of the frame on each edge of the device held upright,
        /// as a fraction of the display's shorter side.
        ///
        /// All four scale with that one side, so their proportions survive
        /// a resize, and a rotation, which swaps the two dimensions but not
        /// which of them is smaller.
        let portraitLeft: CGFloat
        let portraitRight: CGFloat
        let portraitTop: CGFloat
        let portraitBottom: CGFloat
        /// Points the four thicknesses are scaled into, together. Keeps a
        /// frame readable on a pane too small to show its true proportion,
        /// and off the picture-frame end on a very large one.
        let insetRange: ClosedRange<CGFloat>
        /// The display's corner radii in the device's upright frame, each
        /// as a fraction of its shorter side.
        let screenCorners: DeviceBezelLayout.Corners
        /// Points those radii are scaled into, together.
        let screenCornerRange: ClosedRange<CGFloat>
    }

    /// Frame thickness on each edge of the picture as drawn, after the
    /// device's own edges have been turned onto the screen's.
    struct Insets: Equatable, Sendable {
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    /// Phone, pad and watch geometry is derived from ratios of the screen
    /// rather than taken from a device, so each is symmetric and each
    /// family's numbers only claim to look plausible.
    private static let phoneProfile = Profile(
        portraitLeft: 0.045,
        portraitRight: 0.045,
        portraitTop: 0.045,
        portraitBottom: 0.045,
        insetRange: 8...16,
        screenCorners: DeviceBezelLayout.Corners(
            topLeft: 0.15,
            topRight: 0.15,
            bottomLeft: 0.15,
            bottomRight: 0.15
        ),
        screenCornerRange: 12...64
    )

    private static let padProfile = Profile(
        portraitLeft: 0.035,
        portraitRight: 0.035,
        portraitTop: 0.035,
        portraitBottom: 0.035,
        insetRange: 8...18,
        screenCorners: DeviceBezelLayout.Corners(
            topLeft: 0.025,
            topRight: 0.025,
            bottomLeft: 0.025,
            bottomRight: 0.025
        ),
        screenCornerRange: 4...12
    )

    /// Watch carries a noticeably thicker frame and a much larger corner
    /// radius, close to a squircle.
    private static let watchProfile = Profile(
        portraitLeft: 0.075,
        portraitRight: 0.075,
        portraitTop: 0.075,
        portraitBottom: 0.075,
        insetRange: 10...24,
        screenCorners: DeviceBezelLayout.Corners(
            topLeft: 0.17,
            topRight: 0.17,
            bottomLeft: 0.17,
            bottomRight: 0.17
        ),
        screenCornerRange: 8...40
    )

    /// A foldable's cover panel, measured off the alpha channel of
    /// `Bezel-iPhone-Duo` in Apple Design Resources, which draws the body
    /// 1:1 with device pixels. Each ratio is a thickness in those pixels
    /// over the panel's pixel width, which is its shorter side. The hinge
    /// spine runs down the left and is half again as thick as the edge
    /// opposite it.
    ///
    /// The display is a D rather than a rounded rectangle: the two corners
    /// against the spine are nearly square and the two opposite them are
    /// about seven times as round. Both pairs fit a circle closely.
    private static let foldableCoverProfile = Profile(
        portraitLeft: 77 / 1_398,
        portraitRight: 48 / 1_398,
        portraitTop: 56 / 1_398,
        portraitBottom: 47 / 1_398,
        insetRange: 8...18,
        screenCorners: DeviceBezelLayout.Corners(
            topLeft: 26 / 1_398,
            topRight: 177 / 1_398,
            bottomLeft: 26 / 1_398,
            bottomRight: 177 / 1_398
        ),
        screenCornerRange: 2...64
    )

    /// A foldable's inner panel, from the same art and in the same portrait
    /// coordinates, over the shorter side of its native 2007x2853 surface.
    /// Symmetric about both axes, and thicker at the top and bottom, which
    /// are the ends of the long axis the device presents across the screen
    /// once it is open.
    private static let foldableInnerProfile = Profile(
        portraitLeft: 48 / 2_007,
        portraitRight: 48 / 2_007,
        portraitTop: 61 / 2_007,
        portraitBottom: 61 / 2_007,
        insetRange: 8...18,
        screenCorners: DeviceBezelLayout.Corners(
            topLeft: 168 / 2_007,
            topRight: 168 / 2_007,
            bottomLeft: 168 / 2_007,
            bottomRight: 168 / 2_007
        ),
        screenCornerRange: 8...56
    )

    /// Compute the bezel layout for `family` around `imageRect`.
    ///
    /// `panel` picks a foldable's cover or inner geometry; `orientation` is
    /// how the device is presenting, which decides where its thicker edges
    /// come out on screen. Returns `nil` when the family doesn't carry a
    /// device frame (tv → just letterbox) or when `imageRect` is degenerate.
    static func layout(
        family: DeviceFamily,
        imageRect: CGRect,
        panel: Panel = .standard,
        orientation: Orientation = .portrait
    ) -> DeviceBezelLayout? {
        guard imageRect.width > 0, imageRect.height > 0,
            let profile = profile(family: family, panel: panel) else { return nil }
        let reference = min(imageRect.width, imageRect.height)
        let insets = displayed(
            insets: scaled(profile: profile, reference: reference),
            orientation: orientation
        )
        let bezelRect = CGRect(
            x: imageRect.minX - insets.left,
            y: imageRect.minY - insets.top,
            width: imageRect.width + insets.left + insets.right,
            height: imageRect.height + insets.top + insets.bottom
        )
        let screenCorners = displayed(
            corners: scaled(corners: profile, reference: reference),
            orientation: orientation
        )
        return DeviceBezelLayout(
            bezelRect: bezelRect,
            cornerRadii: body(corners: screenCorners, insets: insets),
            screenCornerRadii: screenCorners,
            crownRect: family == .watch
                ? crownRect(imageRect: imageRect, bezelRect: bezelRect, inset: insets.right)
                : nil,
            crownCornerRadius: family == .watch
                ? crownWidth(inset: insets.right) / 2
                : nil
        )
    }

    /// Upper bound on the bezel inset the wrapper might draw for
    /// `family`. Fit Screen reserves this much on each
    /// perpendicular edge so the screen + bezel together fit
    /// inside the pane. At worst we over-reserve by a few points
    /// (the actual inset is recomputed from the final imageRect),
    /// which manifests as a thin margin around the bezel rather
    /// than the bezel being clipped. tv has no bezel.
    ///
    /// One scalar, and the thickest edge rather than any particular one:
    /// the reserve stays symmetric and the body is drawn asymmetrically
    /// inside it, which is what an off-centre display looks like anyway.
    static func maxBezelInset(family: DeviceFamily) -> CGFloat {
        switch family {
        case .tv:
            return 0

        case .phone, .unknown:
            return 18

        case .pad:
            return 18

        case .watch:
            return 24
        }
    }

    // MARK: - Per-panel geometry

    private static func profile(family: DeviceFamily, panel: Panel) -> Profile? {
        switch family {
        case .tv:
            // Letterboxes and draws no frame at all.
            return nil

        case .pad:
            return foldableProfile(panel) ?? padProfile

        case .watch:
            return foldableProfile(panel) ?? watchProfile

        case .phone, .unknown:
            return foldableProfile(panel) ?? phoneProfile
        }
    }

    /// The geometry for one panel of a foldable, or nil when the panel is
    /// the only display its device has and the family decides.
    private static func foldableProfile(_ panel: Panel) -> Profile? {
        switch panel {
        case .standard:
            return nil

        case .foldableCover:
            return foldableCoverProfile

        case .foldableInner:
            return foldableInnerProfile
        }
    }

    /// The four thicknesses in points, scaled into the profile's range.
    ///
    /// One scale for all four rather than a clamp on each, so a frame too
    /// thick or thin for the pane it is drawn in keeps the proportions
    /// between its edges. Clamping them separately would square up an
    /// asymmetric frame at exactly the sizes where the clamp bites.
    private static func scaled(profile: Profile, reference: CGFloat) -> Insets {
        let raw = Insets(
            left: profile.portraitLeft * reference,
            right: profile.portraitRight * reference,
            top: profile.portraitTop * reference,
            bottom: profile.portraitBottom * reference
        )
        let thinnest = min(raw.left, raw.right, raw.top, raw.bottom)
        let thickest = max(raw.left, raw.right, raw.top, raw.bottom)
        guard thinnest > 0, thickest > 0 else { return raw }
        var scale: CGFloat = 1
        if thinnest < profile.insetRange.lowerBound {
            scale = profile.insetRange.lowerBound / thinnest
        }
        if thickest * scale > profile.insetRange.upperBound {
            scale = profile.insetRange.upperBound / thickest
        }
        return Insets(
            left: raw.left * scale,
            right: raw.right * scale,
            top: raw.top * scale,
            bottom: raw.bottom * scale
        )
    }

    /// The display's four radii in points, scaled into the profile's range.
    ///
    /// One scale for all four, for the reason the thicknesses have one: a D
    /// is the ratio between its two radii, and clamping them separately
    /// would round off its flat end at the sizes where the clamp bites.
    private static func scaled(
        corners profile: Profile,
        reference: CGFloat
    ) -> DeviceBezelLayout.Corners {
        let raw = DeviceBezelLayout.Corners(
            topLeft: profile.screenCorners.topLeft * reference,
            topRight: profile.screenCorners.topRight * reference,
            bottomLeft: profile.screenCorners.bottomLeft * reference,
            bottomRight: profile.screenCorners.bottomRight * reference
        )
        let smallest = min(
            min(raw.topLeft, raw.topRight),
            min(raw.bottomLeft, raw.bottomRight)
        )
        guard smallest > 0, raw.widest > 0 else { return raw }
        var scale: CGFloat = 1
        if smallest < profile.screenCornerRange.lowerBound {
            scale = profile.screenCornerRange.lowerBound / smallest
        }
        if raw.widest * scale > profile.screenCornerRange.upperBound {
            scale = profile.screenCornerRange.upperBound / raw.widest
        }
        return DeviceBezelLayout.Corners(
            topLeft: raw.topLeft * scale,
            topRight: raw.topRight * scale,
            bottomLeft: raw.bottomLeft * scale,
            bottomRight: raw.bottomRight * scale
        )
    }

    /// The body's radii, each the display's at that corner plus the thinner
    /// of the two frame edges meeting there.
    ///
    /// Taking the thinner keeps the frame from pinching: an outer curve
    /// drawn for the thicker edge would cut inside the display's own on the
    /// other one. Checked against the art, where the two corners that could
    /// be measured came out within a few pixels of this.
    private static func body(
        corners: DeviceBezelLayout.Corners,
        insets: Insets
    ) -> DeviceBezelLayout.Corners {
        DeviceBezelLayout.Corners(
            topLeft: corners.topLeft + min(insets.left, insets.top),
            topRight: corners.topRight + min(insets.right, insets.top),
            bottomLeft: corners.bottomLeft + min(insets.left, insets.bottom),
            bottomRight: corners.bottomRight + min(insets.right, insets.bottom)
        )
    }

    /// Turn the device's corners onto the ones the viewer sees.
    ///
    /// A displayed corner is the device corner whose two edges land on the
    /// two displayed edges meeting there, which follows from the edge
    /// mapping below and has to agree with it.
    private static func displayed(
        corners: DeviceBezelLayout.Corners,
        orientation: Orientation
    ) -> DeviceBezelLayout.Corners {
        switch orientation {
        case .portrait:
            return corners

        case .landscapeLeft:
            return DeviceBezelLayout.Corners(
                topLeft: corners.topRight,
                topRight: corners.bottomRight,
                bottomLeft: corners.topLeft,
                bottomRight: corners.bottomLeft
            )

        case .portraitUpsideDown:
            return DeviceBezelLayout.Corners(
                topLeft: corners.bottomRight,
                topRight: corners.bottomLeft,
                bottomLeft: corners.topRight,
                bottomRight: corners.topLeft
            )

        case .landscapeRight:
            return DeviceBezelLayout.Corners(
                topLeft: corners.bottomLeft,
                topRight: corners.topLeft,
                bottomLeft: corners.bottomRight,
                bottomRight: corners.topRight
            )
        }
    }

    /// Turn the device's own edges onto the ones the viewer sees.
    ///
    /// Which displayed edge each device edge lands on follows from
    /// `Orientation.surfacePoint(displayedX:displayedY:)`, the mapping the
    /// daemon rotates input through, read in the same direction: a
    /// displayed edge is named by the native edge its points map onto.
    private static func displayed(insets: Insets, orientation: Orientation) -> Insets {
        switch orientation {
        case .portrait:
            return insets

        case .landscapeLeft:
            return Insets(
                left: insets.top,
                right: insets.bottom,
                top: insets.right,
                bottom: insets.left
            )

        case .portraitUpsideDown:
            return Insets(
                left: insets.right,
                right: insets.left,
                top: insets.bottom,
                bottom: insets.top
            )

        case .landscapeRight:
            return Insets(
                left: insets.bottom,
                right: insets.top,
                top: insets.left,
                bottom: insets.right
            )
        }
    }

    // MARK: - Helpers

    /// The crown bump sits on the right edge, vertically centered, sized
    /// for an easy click target.
    private static func crownRect(
        imageRect: CGRect,
        bezelRect: CGRect,
        inset: CGFloat
    ) -> CGRect {
        let width = crownWidth(inset: inset)
        let height = imageRect.height * 0.22
        return CGRect(
            x: bezelRect.maxX - width / 2,
            y: imageRect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func crownWidth(inset: CGFloat) -> CGFloat {
        max(8, min(14, inset * 0.85))
    }
}
