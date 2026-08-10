// SPDX-License-Identifier: GPL-3.0-or-later
//
// PendingPaneView: the SwiftUI surface for a placeholder pane while a
// sim/device attach is in flight, or after it failed. This is exactly
// the "loading / error+retry empty state" the SwiftUI-first convention
// routes away from the AppKit hot path: a spinner + label while
// attaching, an error message + Retry/Close when it threw. Hosted by
// `PendingPaneViewController` via `NSHostingView`; driven by an
// `@Observable` view model the controller flips when the daemon attach
// resolves.
//
// Black background so the swap to the real pane is visually smooth:
// the live pane letterboxes black and the daemon's own "Booting…"
// overlay sits on black too, so attaching → booting → rendering reads
// as one continuous load.

import SwiftUI

struct PendingPaneView: View {
    let model: PendingPaneViewModel

    var body: some View {
        ZStack {
            Color.black
            content
                .padding(24)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .attaching:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .colorScheme(.dark)
                Text(model.label)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Connecting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.yellow)
                Text("Couldn't connect to \(model.label)")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                HStack(spacing: 12) {
                    Button("Retry") { model.onRetry() }
                        .keyboardShortcut(.defaultAction)
                    Button("Close") { model.onCancel() }
                }
                .padding(.top, 4)
            }
        }
    }
}
