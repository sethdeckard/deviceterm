// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorPaneAXInspector: SwiftUI side panel that mounts on the
// right edge of the sim pane when the AX inspector is toggled on.
// ~240pt wide; sim pixels shrink horizontally to make room. A
// dedicated panel keeps AX data off sim pixels AND off the chrome
// strip so the sim picture and the chrome both stay clean.
//
// Shows the cursor-driven label only: the same `axInspectorLabel`
// the daemon's mouse-move tracking populates. There is no element
// tree or click-to-outline.

import SwiftUI

struct SimulatorPaneAXInspector: View {
    let viewModel: SimulatorPaneAXViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accessibility Inspector")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Divider()
            if let label = viewModel.label, !label.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Under cursor")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                }
            } else {
                Text("Hover over a UI element in the sim to inspect.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GhosttyThemeColors.backgroundSwiftUI(opacity: 1.0))
    }
}
