// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Opens one Automation tab per configured program at launch and runs its
/// command there.
///
/// The feature's whole trust story is that this changes nothing about who
/// issues authority. The GUI opens the tab and the GUI issues the grant,
/// exactly as it does for Shell ▸ Open Automation Tab; `AutomationGrantCoordinator`
/// picks the tab up on terminal bind and needs no help from here, so there is
/// deliberately no grant code in this type. The only new input is a file the
/// user edits by hand, which already sits at the trust level of a shell rc
/// file.
///
/// **Nothing configured means nothing happens.** An absent file yields no
/// entries, and this dispatches nothing at all.
///
/// Every seam is injected so the launch pass is testable without a workspace,
/// a daemon, or a window server.
@MainActor
final class AutomationProgramCoordinator {
    /// Injected seams, following `InventorySyncCoordinator.Dependencies`.
    struct Dependencies {
        /// Read the configured programs and whatever the file got wrong.
        var loadEntries: @MainActor () -> (
            entries: [AutomationProgramEntry],
            defects: [AutomationProgramDefect]
        )
        /// The window to open tabs in, creating one if the workspace has
        /// none. Nil when no window could be had.
        var ensureWindow: @MainActor () async -> WindowID?
        /// Open an Automation tab running `command` in `cwd`, and answer
        /// which tab it turned out to be. Nil when the open failed.
        var openAutomationTab: @MainActor (WindowID, String, [String]) async -> TabID?
        /// Title the tab with the program's name.
        var renameTab: @MainActor (WindowID, TabID, String) -> Void
    }

    /// Subsystem is the app's bundle identifier, matching the daemon's
    /// `com.deviceterm.daemon`. Configuration defects are reported only
    /// through this unified-log category.
    private let log = Logger(subsystem: "com.deviceterm", category: "automation-programs")

    private let deps: Dependencies
    private var hasStarted = false

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Run the launch pass once: report what the file got wrong, then open a
    /// tab per usable program, in file order.
    ///
    /// Sequential rather than concurrent, so tab order matches file order.
    /// Re-calling is a no-op; launch happens once per run of the app.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        let (entries, defects) = deps.loadEntries()
        for defect in defects {
            // A defect never stops deviceterm from starting and never stops
            // the other programs from running, so this reports and moves on.
            log.error("automation-programs: \(defect.summary, privacy: .public)")
        }
        guard !entries.isEmpty else { return }

        for entry in entries {
            guard let windowID = await deps.ensureWindow() else {
                log.error(
                    """
                    automation-programs: no window to open \
                    \(entry.name, privacy: .public) in
                    """
                )
                continue
            }
            guard let tabID = await deps.openAutomationTab(windowID, entry.cwd, entry.command)
            else {
                log.error(
                    """
                    automation-programs: could not open a tab for \
                    \(entry.name, privacy: .public)
                    """
                )
                continue
            }
            deps.renameTab(windowID, tabID, entry.name)
        }
    }
}
