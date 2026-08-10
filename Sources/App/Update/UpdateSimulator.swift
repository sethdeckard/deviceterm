// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdateSimulator: a debug hook that drives the update pill through every
// state without a live appcast. There's no feed until release, so this is
// how the pill is exercised (manually, or via the uitest harness). Gated
// on the DEVICETERM_UPDATE_SIMULATOR env var so it never appears in normal
// builds; wires a "Cycle Update Pill (Debug)" app-menu item when set.

import Foundation

@MainActor
enum UpdateSimulator {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DEVICETERM_UPDATE_SIMULATOR"] == "1"
    }

    /// One representative instance of each pill state, in display order.
    /// Closures are no-ops; this is for driving the UI, not real updates.
    static func sampleStates() -> [UpdateViewModel.State] {
        [
            .checking(cancel: {}),
            .updateAvailable(
                version: "0.2.0",
                notes: "<h3>What's new</h3><ul><li>Faster sim boot.</li>"
                    + "<li>Fixed a rotation glitch.</li></ul>",
                install: {},
                dismiss: {}
            ),
            .downloading(fraction: 0.42, cancel: {}),
            .extracting(fraction: 0.8),
            .readyToInstall(install: {}),
            .notFound(dismiss: {}),
            .error(message: "Couldn't reach the update server.", dismiss: {})
        ]
    }

    /// Step the view model through every sample state (2 s each), then
    /// reset. Lets a human or the uitest harness watch the pill render.
    static func drive(_ viewModel: UpdateViewModel) {
        Task { @MainActor in
            for state in sampleStates() {
                viewModel.set(state)
                try? await Task.sleep(for: .seconds(2))
            }
            viewModel.reset()
        }
    }
}
