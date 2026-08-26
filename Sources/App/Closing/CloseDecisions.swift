// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Whether the tab, pane, or window a close prompt is asking about still
/// exists. Read on the main actor whenever the `@Observable` state it
/// touches changes, so the prompt can take itself down; see
/// `CloseSheetLifetime`. A caller with nothing meaningful to watch passes
/// `nil` and its prompt stays up until answered.
typealias CloseTargetLiveness = @MainActor () -> Bool

/// The pane-close, tab-close, window-close, and quit
/// prompts.
///
/// Four call sites converge on `askBootedSimDisposition`, all asking whether
/// the sim keeps running once its surface goes away, all resolved through the
/// same `CloseSuppressionState` lookup (per-window tier, then per-session,
/// then the persistent `tab-close-default`):
///   - sim pane close (Close Pane, the pane's context menu, ⌘W)
///   - single tab close
///   - bulk tab close (Close Other Tabs / Close Tabs to the Right)
///   - window close (red X / ⌘W on the last tab)
///
/// Pane close adds singular wording, always offers the window scope, and can
/// bypass a stored answer outright when its roster lookup failed.
///
/// Quit is the fifth prompt and is not one of them: `quitWithSims` builds its
/// own alert, returns its own decision type, and reads
/// `quit-with-sims-default`. Only the `.always` scope writes across the two
/// keys.
///
/// The multi-pane confirm is a second, independent track: closing a tab,
/// a batch of tabs, or a window whose tabs hold more than one pane asks
/// a plain Close/Cancel question, but only when the sim-disposition
/// prompt is not about to run, because that prompt has Cancel and so
/// already confirms the close. One gesture never stacks two prompts
/// (`TabCloseGateDecision` picks the arm). Its "Don't ask again" reuses
/// the same scope dropdown but stores a boolean under
/// `tab-close-multi-pane`, and never cross-writes the sim keys.
///
/// The "Don't ask again" affordance is a scoped checkbox + popup, not
/// a single permanent toggle. Per-window and per-app-session tiers live
/// in `CloseSuppressionState` (in-memory, cleared on quit); the
/// long-lived tiers write `quit-with-sims-default` / `tab-close-default`
/// (sim track) or `tab-close-multi-pane` (multi-pane track) in
/// `~/.config/deviceterm/config`. The dropdown's available options and
/// default selection are derived from `CloseContext`.
@MainActor
enum CloseDecisions {
    static let tabCloseKey = "tab-close-default"
    static let quitWithSimsKey = "quit-with-sims-default"
    static let tabClosePanesKey = "tab-close-multi-pane"

    /// Closing one sim pane, where exactly one sim is at stake and it has
    /// a name to use. The buttons go singular for the same reason.
    ///
    /// Callers pass `hasOtherTabsInWindow: true` unconditionally, because
    /// the tab survives a pane close: "For this window" is a meaningful
    /// scope even when it is the window's only tab. `windowClose` forces
    /// the opposite for the same reason reversed.
    /// `alwaysAsk` ignores the stored answer for this one call. The caller
    /// passes it when it could not confirm what the sim is doing: a stored
    /// `shutdown` would then stop a simulator on an unverified premise,
    /// which is the one outcome here that destroys state. Asking is the
    /// only honest thing to do with an unknown.
    static func paneClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext,
        deviceName: String,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness? = nil,
        alwaysAsk: Bool = false
    ) async -> TabCloseDecision {
        await askBootedSimDisposition(
            config: config,
            state: state,
            context: context,
            window: window,
            whileTargetLives: isAlive,
            messageText: "Close this pane?",
            informativeText: alwaysAsk
                ? "DeviceTerm could not reach the daemon to check whether "
                    + "\(deviceName) is still running."
                : "Detach keeps \(deviceName) running. Shut Down stops it.",
            detachTitle: "Detach (Keep Sim Running)",
            shutdownTitle: "Shut Down Sim",
            alwaysAsk: alwaysAsk
        )
    }

    static func tabClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness? = nil
    ) async -> TabCloseDecision {
        await askBootedSimDisposition(
            config: config,
            state: state,
            context: context,
            window: window,
            whileTargetLives: isAlive,
            messageText: "Close this tab?",
            informativeText:
                "Detach keeps any simulators this tab booted running. "
                + "Shut Down stops them."
        )
    }

    /// Bulk variant for "Close Other Tabs" / "Close Tabs to the Right".
    /// Asks ONCE and applies the chosen disposition to every tab, so
    /// Cancel aborts the whole operation rather than only the first tab
    /// while the rest still prompt and close. Shares the same scope
    /// machinery as single-tab close.
    ///
    /// `count == 1` (e.g. Close Others on a two-tab window) still uses
    /// bulk wording ("Close 1 tab?") because the affected tab is NOT
    /// the one the user right-clicked; the single-tab "Close this
    /// tab?" wording would be misleading there.
    static func bulkTabClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext,
        count: Int,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness? = nil
    ) async -> TabCloseDecision {
        let noun = count == 1 ? "tab" : "tabs"
        return await askBootedSimDisposition(
            config: config,
            state: state,
            context: context,
            window: window,
            whileTargetLives: isAlive,
            messageText: "Close \(count) \(noun)?",
            informativeText:
                "Detach keeps any simulators these tabs booted running. "
                + "Shut Down stops them."
        )
    }

    static func windowClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        windowID: WindowID,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness? = nil
    ) async -> TabCloseDecision {
        await askBootedSimDisposition(
            config: config,
            state: state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: false),
            window: window,
            whileTargetLives: isAlive,
            messageText: "Close this window?",
            informativeText:
                "Detach keeps any simulators booted from this "
                + "window's tabs running. Shut Down stops them."
        )
    }

    static func quitWithSims(
        config: ConfigFile,
        state: CloseSuppressionState
    ) -> QuitDecision {
        if let pinned = state.lookupQuit(config: config) {
            return pinned
        }
        let alert = NSAlert()
        alert.messageText = "Quit DeviceTerm?"
        alert.informativeText =
            "Simulators booted from DeviceTerm are still running."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Shut Down All & Quit")
        let accessory = SuppressionAccessory(scopes: [.appExit, .always])
        alert.accessoryView = accessory.view

        let response = alert.runModal()
        let decision: QuitDecision =
            response == .alertSecondButtonReturn ? .shutdownSims : .keepSims
        if accessory.suppressionEnabled, let scope = accessory.selectedScope {
            state.recordQuit(decision: decision, scope: scope, config: config)
        }
        return decision
    }

    /// Confirm closing one tab that holds more than one pane. Returns
    /// true to proceed. Runs only when the sim-disposition prompt won't
    /// (see `TabCloseGateDecision`). The caller resolves the dispatch
    /// mode separately; this function only gates the close.
    static func multiPaneTabClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext,
        paneCount: Int,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness? = nil
    ) async -> Bool {
        await askMultiPaneConfirmation(
            config: config,
            state: state,
            context: context,
            window: window,
            whileTargetLives: isAlive,
            messageText: "Close this tab?",
            informativeText:
                "This tab contains \(paneCount) panes. "
                + "Closing the tab closes all of them."
        )
    }

    /// Bulk variant for "Close Other Tabs" / "Close Tabs to the Right":
    /// one confirmation for the whole batch, so Cancel aborts every
    /// close. Same `count == 1` bulk-wording rule as `bulkTabClose`.
    static func bulkMultiPaneTabClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext,
        tabCount: Int,
        multiPaneTabCount: Int,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness? = nil
    ) async -> Bool {
        let noun = tabCount == 1 ? "tab" : "tabs"
        let detail: String
        if tabCount == 1 {
            detail = "That tab contains multiple panes. "
                + "Closing it closes all of them."
        } else if multiPaneTabCount == 1 {
            detail = "One of these tabs contains multiple panes. "
                + "Closing it closes all of them."
        } else {
            detail = "\(multiPaneTabCount) of these tabs contain multiple panes. "
                + "Closing them closes every pane."
        }
        return await askMultiPaneConfirmation(
            config: config,
            state: state,
            context: context,
            window: window,
            whileTargetLives: isAlive,
            messageText: "Close \(tabCount) \(noun)?",
            informativeText: detail
        )
    }

    /// Window flavor of the multi-pane confirm: the whole window is
    /// going away, so the wording counts tabs rather than naming one.
    /// Same `hasOtherTabsInWindow: false` reasoning as `windowClose`:
    /// the window scope is meaningless on a window about to close.
    static func multiPaneWindowClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        windowID: WindowID,
        tabCount: Int,
        multiPaneTabCount: Int,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness? = nil
    ) async -> Bool {
        let detail: String
        if tabCount == 1 {
            detail = "Its tab contains multiple panes. "
                + "Closing the window closes all of them."
        } else if multiPaneTabCount == 1 {
            detail = "One of its tabs contains multiple panes. "
                + "Closing the window closes every pane."
        } else {
            detail = "\(multiPaneTabCount) of its tabs contain multiple panes. "
                + "Closing the window closes every pane."
        }
        return await askMultiPaneConfirmation(
            config: config,
            state: state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: false),
            window: window,
            whileTargetLives: isAlive,
            messageText: "Close this window?",
            informativeText: detail
        )
    }

    /// The button titles default to the plural wording every multi-sim
    /// caller wants; only `paneClose`, which speaks about one sim,
    /// overrides them.
    private static func askBootedSimDisposition(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness?,
        messageText: String,
        informativeText: String,
        detachTitle: String = "Detach (Keep Sims Running)",
        shutdownTitle: String = "Shut Down Sims",
        alwaysAsk: Bool = false
    ) async -> TabCloseDecision {
        if !alwaysAsk,
            let pinned = state.lookupClose(windowID: context.windowID, config: config) {
            return pinned
        }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: detachTitle)
        alert.addButton(withTitle: shutdownTitle)
        alert.addButton(withTitle: "Cancel")
        let scopes: [SuppressionScope] = context.hasOtherTabsInWindow
            ? [.window, .session, .always]
            : [.session, .always]
        let accessory = SuppressionAccessory(scopes: scopes)
        alert.accessoryView = accessory.view

        let response = await runAlert(alert, in: window, whileTargetLives: isAlive)
        let decision: TabCloseDecision
        switch response {
        case .alertFirstButtonReturn:
            decision = .detach

        case .alertSecondButtonReturn:
            decision = .shutdown

        default:
            decision = .cancel
        }
        if decision != .cancel,
            accessory.suppressionEnabled,
            let scope = accessory.selectedScope {
            state.recordClose(
                decision: decision,
                scope: scope,
                windowID: context.windowID,
                config: config
            )
        }
        return decision
    }

    /// The multi-pane confirm shared by the single-tab, bulk-tab, and
    /// window closes. Suppression short-circuits to proceed; Cancel
    /// records nothing, matching `askBootedSimDisposition`.
    private static func askMultiPaneConfirmation(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext,
        window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness?,
        messageText: String,
        informativeText: String
    ) async -> Bool {
        if state.lookupPaneConfirmSuppressed(windowID: context.windowID, config: config) {
            return true
        }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        let scopes: [SuppressionScope] = context.hasOtherTabsInWindow
            ? [.window, .session, .always]
            : [.session, .always]
        let accessory = SuppressionAccessory(scopes: scopes)
        alert.accessoryView = accessory.view

        let proceed = await runAlert(
            alert,
            in: window,
            whileTargetLives: isAlive
        ) == .alertFirstButtonReturn
        if proceed,
            accessory.suppressionEnabled,
            let scope = accessory.selectedScope {
            state.recordPaneConfirmSuppression(
                scope: scope,
                windowID: context.windowID,
                config: config
            )
        }
        return proceed
    }

    /// Run `alert` as a window-modal sheet when `window` exists;
    /// otherwise use the app-modal `runModal` fallback.
    ///
    /// The sheet is worth the async signature because `runModal` spins a
    /// nested modal run loop, and while it is up the MainActor stops
    /// servicing the `app.commands` drain, so CLI workspace verbs go
    /// unanswered until someone dismisses the prompt. A sheet spins no
    /// such loop. Matches `GhosttyTerminalSurface.presentConfirmSheet`.
    ///
    /// A sheet whose `isAlive` target goes away is ended with
    /// `.cancel`, which every caller already reads as "don't proceed"
    /// and which records no suppression. The app-modal fallback has no
    /// such watch: `runModal` is the path taken when there is no window
    /// to anchor to, and it holds the main actor, so nothing could
    /// observe a removal while it is up anyway.
    ///
    /// Exactly one resume: `endSheet` dismisses through the same
    /// completion handler a button press does, so the watch never
    /// resumes the continuation itself.
    private static func runAlert(
        _ alert: NSAlert,
        in window: NSWindow?,
        whileTargetLives isAlive: CloseTargetLiveness?
    ) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        let lifetime = isAlive.map { alive in
            CloseSheetLifetime(isTargetAlive: alive) { [weak window] in
                // No window left means no sheet left to take down.
                guard let window else { return true }
                // The alert may still be animating in or queued behind
                // another sheet. Retry until it attaches; the identity
                // check prevents ending a different sheet.
                guard window.attachedSheet === alert.window else { return false }
                window.endSheet(alert.window, returnCode: .cancel)
                return true
            }
        }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            // Armed on the next main-actor turn rather than here, so the
            // watch is never the thing that has to reason about a
            // half-presented sheet. Nothing is missed in that gap: the
            // watch evaluates the target against current state on its
            // first pass rather than waiting for a change.
            if let lifetime {
                Task { @MainActor in lifetime.start() }
            }
        }
        lifetime?.finish()
        return response
    }
}

private extension SuppressionScope {
    var menuTitle: String {
        switch self {
        case .window:
            return "For this window"

        case .session:
            // Temporary: lives only until the next launch.
            return "Until DeviceTerm restarts"

        case .appExit:
            // Permanent, scoped to the quit prompt.
            return "Every time I quit"

        case .always:
            return "Always"
        }
    }
}

private extension CloseDecisions {
    /// Accessory view for the close + quit alerts: a checkbox over a popup.
    /// The popup is disabled while the checkbox is off (no scope choice to
    /// make) and enables on toggle. `selectedScope` returns nil when the
    /// checkbox is off so the caller can short-circuit without inspecting
    /// either control.
    @MainActor
    final class SuppressionAccessory {
        let view: NSView
        private let checkbox: NSButton
        private let popup: NSPopUpButton
        private let scopes: [SuppressionScope]

        var suppressionEnabled: Bool { checkbox.state == .on }
        var selectedScope: SuppressionScope? {
            guard suppressionEnabled, popup.indexOfSelectedItem >= 0 else { return nil }
            return scopes[popup.indexOfSelectedItem]
        }

        init(scopes: [SuppressionScope]) {
            self.scopes = scopes
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for scope in scopes {
                popup.addItem(withTitle: scope.menuTitle)
            }
            popup.isEnabled = false
            self.popup = popup

            let checkbox = NSButton(
                checkboxWithTitle: "Don't ask again",
                target: nil,
                action: nil
            )
            self.checkbox = checkbox

            let stack = NSStackView(views: [checkbox, popup])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            // NSAlert reads the accessory's `fittingSize` to position it
            // and grow the panel. Leaving `translatesAutoresizingMaskInto
            // Constraints = true` (the default for the stack handed off
            // here) lets NSAlert frame the view directly; if we'd turned
            // it off, NSAlert would lay the accessory on top of the
            // informative text. The frame's height is the stack's
            // intrinsic size; width comes from the alert's panel.
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
            self.view = stack

            checkbox.target = self
            checkbox.action = #selector(toggleSuppression(_:))
        }

        @objc
        private func toggleSuppression(_ sender: NSButton) {
            popup.isEnabled = sender.state == .on
        }
    }
}
