// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

enum DeviceBezelLayoutMath {
    /// Compute the bezel layout for `family` around `imageRect`.
    /// Returns `nil` when the family doesn't carry a device frame
    /// (tv → just letterbox) or when `imageRect` is degenerate.
    static func layout(
        family: DeviceFamily,
        imageRect: CGRect
    ) -> DeviceBezelLayout? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        switch family {
        case .tv:
            return nil

        case .phone, .unknown:
            return phoneLayout(imageRect: imageRect)

        case .pad:
            return padLayout(imageRect: imageRect)

        case .watch:
            return watchLayout(imageRect: imageRect)
        }
    }

    // MARK: - Per-family geometry

    private static func phoneLayout(imageRect: CGRect) -> DeviceBezelLayout {
        let inset = bezelInset(imageRect: imageRect, ratio: 0.045, range: 8...16)
        // Real iPhone outer corner radius is ~55pt at typical
        // screen sizes; scaled-by-width that's roughly 20% of the
        // shorter dimension, capped at ~80pt so a maxed-out pane
        // doesn't get clown-shoe rounded corners.
        let radius = cornerRadius(imageRect: imageRect, ratio: 0.20, range: 24...80)
        let bezelRect = imageRect.insetBy(dx: -inset, dy: -inset)
        let notchWidth = imageRect.width * 0.28
        let notchHeight = max(6, min(10, inset * 0.7))
        let notchRect = CGRect(
            x: imageRect.midX - notchWidth / 2,
            y: imageRect.minY,
            width: notchWidth,
            height: notchHeight
        )
        return DeviceBezelLayout(
            bezelRect: bezelRect,
            cornerRadius: radius,
            notchRect: notchRect,
            notchCornerRadius: notchHeight / 2,
            crownRect: nil,
            crownCornerRadius: nil
        )
    }

    private static func padLayout(imageRect: CGRect) -> DeviceBezelLayout {
        let inset = bezelInset(imageRect: imageRect, ratio: 0.035, range: 8...18)
        let radius = cornerRadius(imageRect: imageRect, ratio: 0.085, range: 12...28)
        let bezelRect = imageRect.insetBy(dx: -inset, dy: -inset)
        return DeviceBezelLayout(
            bezelRect: bezelRect,
            cornerRadius: radius,
            notchRect: nil,
            notchCornerRadius: nil,
            crownRect: nil,
            crownCornerRadius: nil
        )
    }

    private static func watchLayout(imageRect: CGRect) -> DeviceBezelLayout {
        // Watch carries a noticeably thicker bezel and a much larger
        // corner radius, close to a squircle. The crown bump sits on
        // the right edge, vertically centered, sized for an easy
        // click target.
        let inset = bezelInset(imageRect: imageRect, ratio: 0.075, range: 10...24)
        let radius = cornerRadius(imageRect: imageRect, ratio: 0.30, range: 24...60)
        let bezelRect = imageRect.insetBy(dx: -inset, dy: -inset)
        let crownWidth = max(8, min(14, inset * 0.85))
        let crownHeight = imageRect.height * 0.22
        let crownRect = CGRect(
            x: bezelRect.maxX - crownWidth / 2,
            y: imageRect.midY - crownHeight / 2,
            width: crownWidth,
            height: crownHeight
        )
        return DeviceBezelLayout(
            bezelRect: bezelRect,
            cornerRadius: radius,
            notchRect: nil,
            notchCornerRadius: nil,
            crownRect: crownRect,
            crownCornerRadius: crownWidth / 2
        )
    }

    /// Upper bound on the bezel inset the wrapper might draw for
    /// `family`. Fit Screen reserves this much on each
    /// perpendicular edge so the screen + bezel together fit
    /// inside the pane. At worst we over-reserve by a few points
    /// (the actual inset is recomputed from the final imageRect),
    /// which manifests as a thin margin around the bezel rather
    /// than the bezel being clipped. tv has no bezel.
    static func maxBezelInset(family: DeviceFamily) -> CGFloat {
        switch family {
        case .tv:
            return 0

        case .phone, .unknown:
            return 16

        case .pad:
            return 18

        case .watch:
            return 24
        }
    }

    // MARK: - Helpers

    private static func bezelInset(
        imageRect: CGRect,
        ratio: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        let raw = min(imageRect.width, imageRect.height) * ratio
        return max(range.lowerBound, min(range.upperBound, raw))
    }

    private static func cornerRadius(
        imageRect: CGRect,
        ratio: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        let raw = min(imageRect.width, imageRect.height) * ratio
        return max(range.lowerBound, min(range.upperBound, raw))
    }
}
