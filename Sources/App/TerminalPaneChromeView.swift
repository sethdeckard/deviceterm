// SPDX-License-Identifier: GPL-3.0-or-later
//
// TerminalPaneChromeView: a minimal drag handle. A very
// thin strip (~8pt) that paints just a centered ⋯ handle as the
// pane-action affordance. Title and close button are deliberately
// absent: the tab strip already shows the tab/pane title, and close
// lives in the ⋯ menu. The handle stays hidden at rest and fades in
// on hover so the chrome reads as an empty seam most of the time.
//
// The ⋯ icon uses overlay so it doesn't add to the layout height;
// the strip stays 8pt tall regardless of the icon. Hover is detected
// on the strip itself via SwiftUI `.onHover`.

import SwiftUI

@MainActor
struct TerminalPaneChromeView: View {
    let viewModel: TerminalPaneChromeViewModel
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 8)
                .frame(maxWidth: .infinity)
                .background(GhosttyThemeColors.backgroundSwiftUI(opacity: 1.0))
                .overlay(
                    // The handle is the tap target for the pane-action
                    // menu. The wider 60×12 frame around the visible
                    // 28×3 capsule keeps the tap area generous even
                    // when the capsule itself is hover-faded.
                    Color.clear
                        .frame(width: 60, height: 12)
                        .overlay(
                            Capsule()
                                .fill(Color.secondary)
                                .frame(width: 28, height: 3)
                                .opacity(isHovering ? 0.55 : 0.0)
                        )
                        .contentShape(Rectangle())
                        .help("Pane Actions")
                        .onTapGesture { viewModel.onOpenContextMenu() }
                )
            // Transparent 6pt extension below the visible chrome. The
            // terminal surface peeks through, but clicks here still
            // belong to chromeHost (it's on top in AppKit z-order),
            // giving the pane-drag a larger grab target without making
            // the visible chrome any taller.
            Color.clear
                .frame(height: 6)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}
