// SPDX-License-Identifier: GPL-3.0-or-later
//
// CloseDecisions: the tab-close, window-close, and quit prompts.
//
// Three call sites converge on `askBootedSimDisposition`:
//   - tab close (single + bulk variants)
//   - window close (red X / ⌘W on the last tab)
//   - app quit (separate prompt, separate decision type)
//
// The "Don't ask again" affordance is a scoped checkbox + popup, not
// a single permanent toggle. Per-window and per-app-session tiers live
// in `CloseSuppressionState` (in-memory, cleared on quit); the two
// long-lived tiers (`When quitting DeviceTerm` and `Always`) write
// `quit-with-sims-default` / `tab-close-default` in
// `~/.config/deviceterm/config`. The dropdown's available options and
// default selection are derived from `CloseContext`.

import AppKit

enum TabCloseDecision {
    case detach
    case shutdown
    case cancel
}

enum QuitDecision {
    case keepSims
    case shutdownSims
}

/// Scope qualifier picked alongside "Don't ask again". Each scope maps
/// to a different storage tier in `CloseSuppressionState`.
enum SuppressionScope: Sendable {
    /// This window only, held in-memory as `[WindowID: …]`.
    case window
    /// Until DeviceTerm quits, held in an in-memory app-singleton.
    case session
    /// Permanent, quit-prompt only. Persisted to file.
    case appExit
    /// Permanent across every close + quit prompt. Persisted to file;
    /// cross-writes both keys.
    case always
}

/// Carries the prompt-time context the dropdown options/default are
/// derived from. `windowID` is nil for the quit prompt.
struct CloseContext: Sendable {
    let windowID: WindowID?
    let hasOtherTabsInWindow: Bool
}

@MainActor
enum CloseDecisions {
    static let tabCloseKey = "tab-close-default"
    static let quitWithSimsKey = "quit-with-sims-default"

    static func tabClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext
    ) -> TabCloseDecision {
        askBootedSimDisposition(
            config: config,
            state: state,
            context: context,
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
        count: Int
    ) -> TabCloseDecision {
        let noun = count == 1 ? "tab" : "tabs"
        return askBootedSimDisposition(
            config: config,
            state: state,
            context: context,
            messageText: "Close \(count) \(noun)?",
            informativeText:
                "Detach keeps any simulators these tabs booted running. "
                + "Shut Down stops them."
        )
    }

    static func windowClose(
        config: ConfigFile,
        state: CloseSuppressionState,
        windowID: WindowID
    ) -> TabCloseDecision {
        askBootedSimDisposition(
            config: config,
            state: state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: false),
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

    private static func askBootedSimDisposition(
        config: ConfigFile,
        state: CloseSuppressionState,
        context: CloseContext,
        messageText: String,
        informativeText: String
    ) -> TabCloseDecision {
        if let pinned = state.lookupClose(windowID: context.windowID, config: config) {
            return pinned
        }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Detach (Keep Sims Running)")
        alert.addButton(withTitle: "Shut Down Sims")
        alert.addButton(withTitle: "Cancel")
        let scopes: [SuppressionScope] = context.hasOtherTabsInWindow
            ? [.window, .session, .always]
            : [.session, .always]
        let accessory = SuppressionAccessory(scopes: scopes)
        alert.accessoryView = accessory.view

        let response = alert.runModal()
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
}

/// Accessory view for the close + quit alerts: a checkbox over a popup.
/// The popup is disabled while the checkbox is off (no scope choice to
/// make) and enables on toggle. `selectedScope` returns nil when the
/// checkbox is off so the caller can short-circuit without inspecting
/// either control.
@MainActor
private final class SuppressionAccessory {
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
