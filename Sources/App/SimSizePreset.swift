// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimSizePreset: the four sim-pane size presets, matching Apple's
// Simulator.app Window submenu (Physical / Point Accurate / Pixel
// Accurate / Fit Screen). The enum is the user-facing identity; the
// pure math lives alongside in `SimSizeMath` so it tests without an
// `NSWindow` or `NSScreen` in scope.
//
// The chrome ribbon's size-preset dropdown and the View menu's
// ⌃⌘1–⌃⌘4 shortcuts both route to the same compute → split-position
// pipeline; this file is the shared shape so the two surfaces agree on
// what each preset means.
//
// `targetWidth(preset:device:screen:available:)` returns the pane's
// target width in window points; the caller (PaneLayoutViewController)
// translates that into a divider position. Returning a CGFloat keeps
// the caller's split-arithmetic simple, with no `SizeRecommendation`
// wrapper, no failure cases beyond returning `nil` when the device
// dimensions aren't available yet.

import CoreGraphics
import DaemonProtocol

enum SimSizePreset: String, CaseIterable, Sendable {
    /// Width ≈ device's real-world physical width, approximated via
    /// the baseline 110 PPI heuristic (close-enough across modern
    /// iPhone / iPad / watch; TV has no physical reference so falls
    /// back to Fit Screen).
    case physical
    /// 1 device point = 1 Mac point. Uses a per-family approximate
    /// device scale (@2x watch / @3x phone / @2x pad / 1x tv) since
    /// the wire doesn't carry the exact device scale.
    case pointAccurate
    /// 1 device pixel = 1 Mac pixel. Window width = device pixelWidth
    /// / Mac backing scale factor.
    case pixelAccurate
    /// Fill the available pane area, preserving the device's aspect.
    /// Default for new panes, so there is no surprise resizing on attach.
    case fitScreen

    /// Display label for menus + the chrome picker.
    var displayName: String {
        switch self {
        case .physical:
            return "Physical Size"

        case .pointAccurate:
            return "Point Accurate"

        case .pixelAccurate:
            return "Pixel Accurate"

        case .fitScreen:
            return "Fit Screen"
        }
    }
}

/// Device-side inputs to size-preset math. Kept as a tiny value type
/// so the pure function signature reads naturally and the unit tests
/// can construct fixtures inline.
struct SimDeviceMetrics: Equatable, Sendable {
    /// Native pixel width of the device's display (from
    /// `SimDisplayHandle.displaySize` via the attach response).
    let pixelWidth: Int
    /// Native pixel height of the device's display. Pairs with
    /// `pixelWidth` to derive aspect ratio.
    let pixelHeight: Int
    /// Coarse device family. Picks the @x default for Point Accurate
    /// and the native PPI baseline for Physical Size. Watch overrides
    /// to @2x; phone defaults to @3x (modern Pro models); pad @2x;
    /// tv @1x; unknown @1x as a conservative fallback.
    let family: DeviceFamily
}

/// Mac-side inputs to size-preset math.
struct MacScreenMetrics: Equatable, Sendable {
    /// `NSScreen.backingScaleFactor` of the screen the pane is on
    /// (typically 2.0 for Retina, 1.0 for non-Retina).
    let backingScaleFactor: CGFloat
    /// Pixels-per-inch of the Mac screen, used for the Physical Size
    /// preset. Defaults to 110 PPI matching the SwiftUI baseline.
    let pointsPerInch: CGFloat
}

enum SimSizeMath {
    /// Approximate device PPI for the Physical Size preset, baseline
    /// 110 PPI (close to modern iPhone density).
    /// Watch is denser; TV is undefined (large-screen).
    static func devicePixelsPerInch(family: DeviceFamily) -> CGFloat {
        switch family {
        case .watch:
            return 326

        case .phone:
            return 460

        case .pad:
            return 264

        case .tv, .unknown:
            return 110
        }
    }

    /// Approximate device logical-to-pixel scale for the Point Accurate
    /// preset. The wire doesn't carry the exact `@x` for the booted
    /// device; family defaults are close enough for the size preset
    /// (the user wanting pixel-exact mapping uses Pixel Accurate).
    static func deviceScale(family: DeviceFamily) -> CGFloat {
        switch family {
        case .watch:
            return 2.0

        case .phone:
            return 3.0

        case .pad:
            return 2.0

        case .tv, .unknown:
            return 1.0
        }
    }

    /// Compute the pane's target extent (Mac points) along the split's
    /// divider axis for the requested preset. Returns nil only when the
    /// device pixel dimensions are missing (renderable not bound yet);
    /// caller falls back to the existing split-view layout in that case.
    ///
    /// `axisIsVertical` matches `NSSplitView.isVertical`: `true` (the
    /// default, side-by-side panes) uses the device's `pixelWidth`;
    /// `false` (top/bottom panes after Toggle Split Direction) uses
    /// `pixelHeight` so a portrait iPhone in a horizontal split sizes
    /// to its tall pixel dimension, not its narrow one.
    ///
    /// Fit Screen shrinks the pane along the divided axis so the
    /// device's aspect fills the perpendicular extent, leaving no
    /// letterbox bars in the rendered screen. `availableWidth` is
    /// the parent split's full extent on the divided axis; the
    /// caller (PaneLayoutViewController) supplies the pane's
    /// perpendicular extent via `perpendicularExtent`. The
    /// `orientation` field matters: CoreSimulator keeps the
    /// IOSurface at the device's portrait pixel dimensions even
    /// when the device is rotated, so `pixelWidth / pixelHeight`
    /// gives the PORTRAIT aspect; the renderer swaps W/H for
    /// landscape. Fit Screen has to use the same swapped aspect
    /// or a rotated phone would size to its portrait width and
    /// still letterbox.
    ///
    /// `bezelReserve` lets the caller reserve room on each
    /// perpendicular edge for the device-frame bezel layers so
    /// Fit Screen doesn't push the screen edge-to-edge against
    /// the pane boundary (which would clip the bezel). Passed as
    /// the bezel inset for the relevant family.
    static func targetWidth(
        preset: SimSizePreset,
        device: SimDeviceMetrics,
        screen: MacScreenMetrics,
        availableWidth: CGFloat,
        axisIsVertical: Bool = true,
        perpendicularExtent: CGFloat = 0,
        orientation: Orientation = .portrait,
        bezelReserve: CGFloat = 0
    ) -> CGFloat? {
        guard device.pixelWidth > 0, device.pixelHeight > 0 else { return nil }
        let pixelExtent = axisIsVertical ? device.pixelWidth : device.pixelHeight
        switch preset {
        case .fitScreen:
            // Fit-screen needs the perpendicular extent to compute
            // an aspect-correct width; if the caller hasn't
            // supplied it, fall back to the available extent (no
            // shrink) so we never produce a worse layout than the
            // pre-fit state.
            guard perpendicularExtent > 0 else { return availableWidth }
            // Shrink the perpendicular by 2×bezelReserve so the
            // screen + bezel together fit; one inset on each
            // perpendicular edge.
            let perpendicularForScreen = max(0, perpendicularExtent - 2 * bezelReserve)
            // Displayed aspect (W / H of what the user sees). The
            // IOSurface is fixed at portrait dimensions; landscape
            // orientations swap W/H in the rendered quad.
            let isLandscape = orientation == .landscapeLeft
                || orientation == .landscapeRight
            let displayWidth = isLandscape
                ? CGFloat(device.pixelHeight) : CGFloat(device.pixelWidth)
            let displayHeight = isLandscape
                ? CGFloat(device.pixelWidth) : CGFloat(device.pixelHeight)
            let widthOverHeight = displayWidth / displayHeight
            // `axisIsVertical` true → divider runs vertically →
            // we're sizing the pane's WIDTH against a fixed HEIGHT.
            // Add the bezel reserve back so the FINAL pane width
            // is `screen + 2×reserve`. Flip when the divider is
            // horizontal so the math is self-consistent across
            // split orientations.
            let screenExtent = axisIsVertical
                ? perpendicularForScreen * widthOverHeight
                : perpendicularForScreen / widthOverHeight
            return min(screenExtent + 2 * bezelReserve, availableWidth)

        case .pixelAccurate:
            // 1 device pixel → 1 Mac pixel. Window points = pixels /
            // backing scale. Backing factor of 0 would be a malformed
            // screen metric, so fall back to 1.0 rather than divide-by-zero.
            // Bezel reserve is added so the pane extent covers the
            // rendered screen + the device-frame bezel (the renderer
            // subtracts `displayInset` on both sides before drawing).
            let backing = max(screen.backingScaleFactor, 1.0)
            return CGFloat(pixelExtent) / backing + 2 * bezelReserve

        case .pointAccurate:
            // Device pixels → device points → Mac points (1:1 at the
            // point level). Scale-0 would mean an unclassified family;
            // fall back to 1.0 so we still produce a finite answer.
            let scale = max(deviceScale(family: device.family), 1.0)
            return CGFloat(pixelExtent) / scale + 2 * bezelReserve

        case .physical:
            // Physical inches = device pixels / device PPI. Mac points
            // = inches × screen PPI. TV / unknown fall through to the
            // PPI-110 baseline so the math still produces a sane value
            // even though "physical TV" isn't meaningful.
            let devicePPI = devicePixelsPerInch(family: device.family)
            let inches = CGFloat(pixelExtent) / devicePPI
            return inches * screen.pointsPerInch + 2 * bezelReserve
        }
    }
}
