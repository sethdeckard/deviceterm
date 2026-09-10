// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `--pane <ref>`, the universal targeting selector.
///
/// Every verb that drives a device pane takes it, and every one resolves
/// it the same way, so it is declared once rather than per verb.
struct PaneOption: ParsableArguments {
    @Option(
        name: .long,
        help: "Pane to target. Defaults to DEVICETERM_TARGET_PANE, then the tab's only device pane.",
        completion: .custom { _, _, _ in RefCompletion.panes() }
    )
    var pane: String?
}
