// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorQuitIllustration: the Dock right-click ▸ Quit graphic in the
// Simulator coexistence welcome.
//
// Shows the Dock path rather than ⌘Q because that is the case that
// actually bites: Simulator.app running in the background with its
// window already closed, where ⌘Q goes to whatever is frontmost and the
// user believes it's gone. ⌘Q is a line of body copy instead; it doesn't
// need a picture.
//
// Both app icons are fetched live rather than bundled as a screenshot
// crop, so the picture matches the user's own Dock: it renders native at
// any scale, follows whichever Xcode is installed, can't go stale when
// Apple redesigns the icon, and carries no baked-in dark Dock
// background that would break in light mode.
//
// The menu and its pointer are one shape (`MenuBubble`), not a panel
// with a triangle stuck underneath. Drawn as two views they get two
// borders, and the menu's bottom edge draws a line straight across the
// join, which makes the pointer look glued on. One path means one
// outline that flows around the tip.
//
// The menu is drawn flat (material, border, accent highlight) rather
// than reproducing macOS's exact vibrancy. A near-miss on the real blur
// reads as broken, where an obvious simplification reads as a diagram.
//
// Every color is semantic so the whole thing inverts correctly; nothing
// here hardcodes the dark-mode appearance it was designed against.

import AppKit
import SwiftUI

struct SimulatorQuitIllustration: View {
    /// Geometry, shared by the menu and the Dock strip so the pointer
    /// stays over the Simulator icon if any of it changes.
    private enum Metrics {
        static let iconSize: CGFloat = 44
        static let iconSpacing: CGFloat = 14
        static let dockPadding: CGFloat = 10
        static let menuWidth: CGFloat = 188
        static let menuCornerRadius: CGFloat = 9
        static let tailWidth: CGFloat = 22
        static let tailHeight: CGFloat = 12

        /// Clearance between the pointer's tip and the Dock container. A
        /// real Dock menu floats above the Dock rather than resting on
        /// it, and a touching tip reads as a join instead of a pointer.
        static let tailGap: CGFloat = 7

        static let dockWidth = dockPadding * 2 + iconSize * 2 + iconSpacing

        /// Distance from the Dock strip's leading edge to the center of
        /// the first (Simulator) icon.
        static let firstIconCenter = dockPadding + iconSize / 2

        /// The Dock is narrower than the menu and centered under it, so
        /// the pointer's offset within the menu is that inset plus the
        /// icon's own center.
        static let tailCenterX = (menuWidth - dockWidth) / 2 + firstIconCenter
    }

    /// The menu's outline, built once: both the fill and the stroke use
    /// it, which is what keeps them from drifting into a visible seam.
    private static let bubble = MenuBubble(
        cornerRadius: Metrics.menuCornerRadius,
        tailWidth: Metrics.tailWidth,
        tailHeight: Metrics.tailHeight,
        tailCenterX: Metrics.tailCenterX
    )

    var body: some View {
        VStack(spacing: Metrics.tailGap) {
            menuBubble
            dockStrip
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Right-click Simulator in the Dock and choose Quit"
        )
    }

    /// The menu and its pointer as a single bordered surface.
    private var menuBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("Device", hasSubmenu: true)
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

    private var dockStrip: some View {
        HStack(spacing: Metrics.iconSpacing) {
            dockIcon(Self.simulatorAppIcon(), label: "Simulator")
            dockIcon(NSApp.applicationIconImage, label: "DeviceTerm")
        }
        .padding(Metrics.dockPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    /// Simulator.app's icon, in three tiers.
    ///
    /// The running instance first: that is literally the icon in the
    /// user's Dock, and it's the tier that applies whenever this welcome
    /// is shown automatically or the advisory offers Learn More…. Launch
    /// Services second, for a Help-menu open with Simulator.app closed;
    /// it resolves to whatever "Open in Simulator.app" would launch,
    /// which is not guaranteed to equal `xcode-select -p` when several
    /// Xcodes are installed. Nil last, when it isn't installed at all.
    static func simulatorAppIcon() -> NSImage? {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: SimulatorDetachPolicy.simulatorBundleID)
            .first?.icon
        if let running { return running }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: SimulatorDetachPolicy.simulatorBundleID
        ) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
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

    /// One Dock icon with its running-app indicator. The dot is part of
    /// the diagram, not a live status: it depicts the coexistence the
    /// welcome is describing, and is drawn whether or not Simulator.app
    /// is running when the window opens.
    @ViewBuilder
    private func dockIcon(_ image: NSImage?, label: String) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    // Simulator.app isn't installed. Keep the slot so
                    // the menu still has something to point at.
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

private extension SimulatorQuitIllustration {
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
