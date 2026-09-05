// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A slice of Dock showing one of Apple's apps next to DeviceTerm, used by
/// both coexistence illustrations.
///
/// Coexistence is the subject of both welcomes, and two icons side by side
/// with running indicators is the picture of it. Shared so the two windows
/// can't drift apart, and so the geometry has one home:
/// `CoexistenceQuitIllustration` aims a menu pointer at the first icon and
/// derives that offset from `Metrics`.
///
/// Both icons are fetched live rather than bundled as a screenshot crop,
/// so the picture matches the user's own Dock: it renders native at any
/// scale, follows whichever Xcode is installed, can't go stale when Apple
/// redesigns the icon, and carries no baked-in dark Dock background that
/// would break in light mode.
struct WelcomeDockStrip: View {
    /// Read by `CoexistenceQuitIllustration` to place its menu pointer over
    /// the first icon, so the two stay aligned if any of this changes.
    enum Metrics {
        static let iconSize: CGFloat = 44
        static let iconSpacing: CGFloat = 14
        static let padding: CGFloat = 10
        static let cornerRadius: CGFloat = 14

        static let width = padding * 2 + iconSize * 2 + iconSpacing

        /// Distance from the strip's leading edge to the center of the
        /// first icon, which is Apple's app.
        static let firstIconCenter = padding + iconSize / 2
    }

    /// Apple's app, drawn first. DeviceTerm always follows it.
    let app: CoexistenceApp

    var body: some View {
        HStack(spacing: Metrics.iconSpacing) {
            icon(app.icon(), label: app.displayName)
            icon(NSApp.applicationIconImage, label: "DeviceTerm")
        }
        .padding(Metrics.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    /// One Dock icon with its running-app indicator. The dot is part of
    /// the diagram, not a live status: it depicts the coexistence the
    /// welcome is describing, and is drawn whether or not the app is
    /// running when the window opens.
    @ViewBuilder
    private func icon(_ image: NSImage?, label: String) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    // Apple's app isn't installed, which a Help-menu open
                    // reaches. Keep the slot so the strip still has the
                    // shape the prose describes.
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                }
            }
            .frame(width: Metrics.iconSize, height: Metrics.iconSize)
            .accessibilityHidden(true)

            Circle()
                .fill(.secondary)
                .frame(width: 4, height: 4)
        }
        .help(label)
    }
}
