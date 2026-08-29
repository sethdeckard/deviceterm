// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A debug hook that drives the update pill through every
/// state without fetching the configured appcast, which is how the pill
/// is exercised (manually, or via the uitest harness). Gated
/// on the DEVICETERM_UPDATE_SIMULATOR env var so it never appears in normal
/// builds; wires a "Cycle Update Pill (Debug)" app-menu item when set.
@MainActor
enum UpdateSimulator {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DEVICETERM_UPDATE_SIMULATOR"] == "1"
    }

    /// Notes shaped like a real release-notes file: a stylesheet the
    /// parser has to drop, both heading levels, inline markup, and enough
    /// bullets to scroll. It exercises both paragraph-to-list and
    /// list-to-paragraph gaps and puts two lists back to back, so the
    /// manual pass can judge the spacing rhythm. A one-liner would
    /// exercise none of the popover's layout.
    static let sampleNotes = """
        <style>
          body { font: -apple-system-body; }
          h3 { margin-top: 1.2em; }
        </style>

        <h2>DeviceTerm 0.2.0</h2>

        <p>
          Sample notes. The debug pill uses them to exercise the popover's
          layout without a live appcast, so they describe nothing that
          shipped.
        </p>

        <h3>Panes And Devices</h3>

        <ul>
          <li>
            <b>Simulator panes.</b> Booting a simulator from a tab attaches a
            live pane to that tab.
          </li>
          <li>
            <code>devices list</code> reports owned booted simulators and
            connected physical devices.
          </li>
          <li>Rotation and hardware buttons are driven from the CLI.</li>
        </ul>

        <p>
          A paragraph closing the list above, so the gap that ends a bullet
          run can be told from the gap inside one.
        </p>

        <h3>Layout Coverage</h3>

        <ul>
          <li>A short item, for the spacing between adjacent bullets.</li>
          <li>
            A deliberately long one, so the popover has to wrap it and the
            wrapped lines can be checked against the hanging indent.
          </li>
        </ul>

        <ul>
          <li>
            A second list with nothing between it and the first, which reads
            as one run.
          </li>
          <li>
            <b><code>ax sweep</code></b> stays bold where an inline code span
            sits inside emphasis.
          </li>
        </ul>

        <p>
          A first paragraph, followed by a second, for the gap between two of
          them.
        </p>

        <p>
          The second one. It also carries <a href="https://example.com">a
          link</a>, so the accent tint can be judged in both appearances.
        </p>

        <p>A paragraph running straight into a list, with no heading between.</p>

        <ul>
          <li>The bullet that opens directly beneath it.</li>
        </ul>
        """

    /// One representative instance of each pill state, in display order.
    /// Closures are no-ops; this is for driving the UI, not real updates.
    static func sampleStates() -> [UpdateViewModel.State] {
        [
            .checking(cancel: {}),
            .updateAvailable(
                version: "0.2.0",
                notes: sampleNotes,
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
