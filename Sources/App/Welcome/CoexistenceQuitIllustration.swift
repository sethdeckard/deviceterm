// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The Dock right-click ▸ Quit graphic, shared by both coexistence
/// welcomes.
///
/// One picture for both because both welcomes ask for the same thing:
/// DeviceTerm doesn't need either app, so quit it before booting a sim.
/// Only the icon and the app-specific menu rows differ.
///
/// Shows the Dock path rather than ⌘Q because that is the case that
/// actually bites: Apple's app running in the background with its window
/// already closed, where ⌘Q goes to whatever is frontmost and the user
/// believes it's gone. ⌘Q is a line of body copy instead; it doesn't need
/// a picture.
///
/// The Dock strip is `WelcomeDockStrip`. The pointer's horizontal offset
/// is derived from that type's geometry, so the tip stays over Apple's
/// icon.
///
/// The menu and its pointer are one shape (`MenuBubble`), not a panel
/// with a triangle stuck underneath. Drawn as two views they get two
/// borders, and the menu's bottom edge draws a line straight across the
/// join, which makes the pointer look glued on. One path means one
/// outline that flows around the tip.
///
/// The menu is drawn flat (material, border, accent highlight) rather
/// than reproducing macOS's exact vibrancy. A near-miss on the real blur
/// reads as broken, where an obvious simplification reads as a diagram.
///
/// The surfaces take semantic colors so the whole thing inverts correctly.
/// The two literals are the selected row's white text and the menu's black
/// shadow, which macOS draws the same way in both appearances.
struct CoexistenceQuitIllustration: View {
    /// The menu's own geometry. The pointer's position reads
    /// `WelcomeDockStrip.Metrics` rather than restating it, so the tip
    /// follows the icon if the strip changes.
    private enum Metrics {
        static let menuWidth: CGFloat = 188
        static let menuCornerRadius: CGFloat = 9
        static let tailWidth: CGFloat = 22
        static let tailHeight: CGFloat = 12

        /// Clearance between the pointer's tip and the Dock container. A
        /// real Dock menu floats above the Dock rather than resting on
        /// it, and a touching tip reads as a join instead of a pointer.
        static let tailGap: CGFloat = 7

        /// The Dock is narrower than the menu and centered under it, so
        /// the pointer's offset within the menu is that inset plus the
        /// icon's own center.
        static let tailCenterX = (menuWidth - WelcomeDockStrip.Metrics.width) / 2
            + WelcomeDockStrip.Metrics.firstIconCenter
    }

    /// The menu's outline, built once: both the fill and the stroke use
    /// it, which is what keeps them from drifting into a visible seam.
    private static let bubble = MenuBubble(
        cornerRadius: Metrics.menuCornerRadius,
        tailWidth: Metrics.tailWidth,
        tailHeight: Metrics.tailHeight,
        tailCenterX: Metrics.tailCenterX
    )

    /// Whose Dock icon is being right-clicked.
    let app: CoexistenceApp

    /// Rows this app adds above the ones every Dock menu has.
    ///
    /// Simulator.app contributes a Device submenu. Device Hub's own
    /// additions have not been read off a running copy, so it shows only
    /// the standard rows rather than invented ones.
    private var appSpecificRows: [String] {
        switch app {
        case .simulator:
            ["Device"]

        case .deviceHub:
            []
        }
    }

    var body: some View {
        VStack(spacing: Metrics.tailGap) {
            menuBubble
            WelcomeDockStrip(app: app)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Right-click \(app.displayName) in the Dock and choose Quit"
        )
    }

    /// The menu and its pointer as a single bordered surface.
    private var menuBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(appSpecificRows, id: \.self) { title in
                menuRow(title, hasSubmenu: true)
            }
            // Options is standard in every app's Dock menu, so it needs
            // no per-app knowledge.
            menuRow("Options", hasSubmenu: true)
            Divider().padding(.vertical, 4)
            menuRow("Show All Windows")
            menuRow("Hide")
            quitRow
        }
        .padding(.vertical, 5)
        // Reserve the pointer's height inside the shape's bounds; the
        // rows stay in the body above it.
        .padding(.bottom, Metrics.tailHeight)
        .frame(width: Metrics.menuWidth, alignment: .leading)
        .background(Self.bubble.fill(.regularMaterial))
        .overlay(Self.bubble.stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// The highlighted row. `.accentColor` rather than a fixed blue so
    /// it matches whatever the user picked in System Settings.
    private var quitRow: some View {
        Text("Quit")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 5)
    }

    private func menuRow(_ title: String, hasSubmenu: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(title)
            if hasSubmenu {
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension CoexistenceQuitIllustration {
    /// A rounded rectangle with a downward pointer on its bottom edge, as
    /// one closed path so a fill and a stroke both flow around the tip
    /// instead of drawing a seam where the two would otherwise meet.
    ///
    /// The passed rect includes `tailHeight`: the body occupies everything
    /// above it, and `tailCenterX` is measured from the rect's leading edge.
    struct MenuBubble: Shape {
        let cornerRadius: CGFloat
        let tailWidth: CGFloat
        let tailHeight: CGFloat
        let tailCenterX: CGFloat

        /// A hard point looks like a drawing artifact at this size; macOS
        /// rounds it.
        private let tipRadius: CGFloat = 2.5

        func path(in rect: CGRect) -> Path {
            let bodyBottom = rect.maxY - tailHeight
            let tipX = rect.minX + tailCenterX
            var path = Path()
            // Start mid-way up the left edge so every corner below is an
            // arc between two known tangents, with no seam at the origin.
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
                radius: cornerRadius
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: bodyBottom),
                radius: cornerRadius
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: bodyBottom),
                tangent2End: CGPoint(x: rect.minX, y: bodyBottom),
                radius: cornerRadius
            )
            // Along the bottom edge to the pointer, down to the rounded
            // tip, and back up to the bottom edge.
            path.addLine(to: CGPoint(x: tipX + tailWidth / 2, y: bodyBottom))
            path.addArc(
                tangent1End: CGPoint(x: tipX, y: rect.maxY),
                tangent2End: CGPoint(x: tipX - tailWidth / 2, y: bodyBottom),
                radius: tipRadius
            )
            path.addLine(to: CGPoint(x: tipX - tailWidth / 2, y: bodyBottom))
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: bodyBottom),
                tangent2End: CGPoint(x: rect.minX, y: rect.minY),
                radius: cornerRadius
            )
            path.closeSubpath()
            return path
        }
    }
}
