// SPDX-License-Identifier: GPL-3.0-or-later
//
// ConfigCreatePromptView: the SwiftUI confirmation shown when
// Settings… is invoked and no config file exists yet. A self-contained
// card (not a system `NSAlert`) so it presents reliably even with no
// key window open, and stays in the SwiftUI column for product UI. The
// buttons drive the view model; `SettingsPromptWindowController` hosts
// it and closes once the view model resolves.

import SwiftUI

struct ConfigCreatePromptView: View {
    let viewModel: ConfigSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a config file?")
                .font(.system(size: 14, weight: .semibold))
            Text(
                "deviceterm has no config file at ~/.config/deviceterm/config. "
                + "Create one seeded with documented examples of every "
                + "available setting?"
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { viewModel.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create & Open") { viewModel.confirmCreate() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}
