// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The unobtrusive update notification, a frosted
/// material pill with a semantic-colored icon (or a spinner while
/// checking), the state title, an action button for actionable states, and
/// a close affordance for dismissible ones. The pill background is neutral
/// in every state; only the icon carries color, and the accent shows up
/// only when there's something to act on.
struct UpdatePillView: View {
    let viewModel: UpdateViewModel
    @State private var showingNotes = false

    var body: some View {
        let state = viewModel.state
        if viewModel.isVisible {
            HStack(spacing: 6) {
                leading(for: state)
                Text(state.title)
                    .font(.callout)
                    .lineLimit(1)
                if let details = state.updateDetails {
                    notesDisclosure(details, state: state)
                }
                if let action = state.primaryAction {
                    Button(action.label, action: action.run)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                if let dismiss = state.dismissAction {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .fixedSize()
        }
    }

    /// A chevron that opens the release-notes popover for the available
    /// update. The popover's Install/Later reuse the state's own closures.
    private func notesDisclosure(
        _ details: (version: String, notes: String?),
        state: UpdateViewModel.State
    ) -> some View {
        Button {
            showingNotes.toggle()
        } label: {
            Image(systemName: "chevron.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Release notes")
        .popover(isPresented: $showingNotes, arrowEdge: .bottom) {
            UpdatePopoverView(
                version: details.version,
                notes: details.notes,
                install: {
                    showingNotes = false
                    state.primaryAction?.run()
                },
                later: {
                    showingNotes = false
                    // Tell Sparkle "not now" so the session doesn't stay
                    // pending and the pill dismisses.
                    state.dismissAction?()
                }
            )
        }
    }

    @ViewBuilder
    private func leading(for state: UpdateViewModel.State) -> some View {
        if case .checking = state {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: state.systemImage)
                .foregroundStyle(color(for: state.tint))
        }
    }

    private func color(for tint: UpdateTint) -> Color {
        switch tint {
        case .neutral:
            return .secondary

        case .accent:
            return .accentColor

        case .positive:
            return .green

        case .negative:
            return .red
        }
    }
}
