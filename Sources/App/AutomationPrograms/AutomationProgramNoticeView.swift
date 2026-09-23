// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The failure notice itself: an icon, what stopped, and a way to dismiss it.
/// Shaped like the update pill so the two read as the same kind of aside.
struct AutomationProgramNoticeView: View {
    @State var viewModel: AutomationProgramNoticeViewModel

    var body: some View {
        if viewModel.isVisible {
            HStack(spacing: 6) {
                Image(systemName: "bolt.slash")
                    .foregroundStyle(.secondary)
                Text(viewModel.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Button {
                    viewModel.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .fixedSize()
        }
    }
}
