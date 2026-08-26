// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// The four sim-pane size presets, matching Apple's
/// Simulator.app Window submenu (Physical / Point Accurate / Pixel
/// Accurate / Fit Screen). The enum is the user-facing identity; the
/// pure math lives alongside in `SimSizeMath` so it tests without an
/// `NSWindow` or `NSScreen` in scope.
///
/// The chrome ribbon's size-preset dropdown and the View menu's
/// ⌃⌘1–⌃⌘4 shortcuts both route to the same compute → split-position
/// pipeline; this file is the shared shape so the two surfaces agree on
/// what each preset means.
///
/// `targetWidth(preset:device:screen:available:)` returns the pane's
/// target width in window points; the caller (PaneLayoutViewController)
/// translates that into a divider position. Returning a CGFloat keeps
/// the caller's split-arithmetic simple, with no `SizeRecommendation`
/// wrapper, no failure cases beyond returning `nil` when the device
/// dimensions aren't available yet.
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
