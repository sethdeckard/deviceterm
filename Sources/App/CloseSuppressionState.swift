// SPDX-License-Identifier: GPL-3.0-or-later
//
// CloseSuppressionState: in-memory tiers behind the close-prompt's
// scope dropdown.
//
// The prompt's "Don't ask again" checkbox grew a scope qualifier so
// the user can choose how long the suppression lasts. The
// persistent-forever tier still lives in `~/.config/deviceterm/config`
// via `ConfigFile`; the two softer tiers (per-window and
// per-app-session) live here, cleared on app quit.
//
// Lookup order at prompt-time is most-specific-wins: window override →
// session override → persistent file. The persistent layer is checked
// by `CloseDecisions` itself, not by this state; this type only owns
// the in-memory tiers.

import AppKit

@MainActor
final class CloseSuppressionState {
    static let shared = CloseSuppressionState()

    private(set) var perWindow: [WindowID: TabCloseDecision] = [:]
    private(set) var perSession: TabCloseDecision?

    // In-memory tiers for the multi-pane tab-close confirm. Boolean
    // rather than decision-valued: the confirm has no disposition to
    // store, only "stop asking".
    private(set) var paneConfirmPerWindow: Set<WindowID> = []
    private(set) var paneConfirmPerSession = false

    func recordClose(
        decision: TabCloseDecision,
        scope: SuppressionScope,
        windowID: WindowID?,
        config: ConfigFile
    ) {
        switch scope {
        case .window:
            if let windowID {
                perWindow[windowID] = decision
            }

        case .session:
            perSession = decision

        case .appExit:
            // Not a valid scope for close prompts; the dropdown only
            // offers `.appExit` in the quit prompt. If a caller reaches
            // here, treat it as a no-op rather than mis-persisting.
            break

        case .always:
            // Evict every softer tier before persisting so the new
            // permanent default takes effect immediately. Otherwise a
            // stale per-window or per-session pick would still beat
            // the just-written persistent default (lookupClose walks
            // most-specific-first), defeating the user's intent.
            perWindow.removeAll()
            perSession = nil
            persistClose(decision: decision, config: config)
            // "Always" cross-writes the quit-prompt key too so the
            // user's intent ("never ask me about sims again") extends
            // across both prompt types. detach ↔ keep, shutdown ↔
            // shutdown.
            let quit: QuitDecision = decision == .shutdown ? .shutdownSims : .keepSims
            persistQuit(decision: quit, config: config)
        }
    }

    func recordQuit(
        decision: QuitDecision,
        scope: SuppressionScope,
        config: ConfigFile
    ) {
        switch scope {
        case .window, .session:
            // The quit dropdown never offers `.window` or `.session`;
            // ignore if a caller mis-routes.
            break

        case .appExit:
            persistQuit(decision: decision, config: config)

        case .always:
            // Mirror the close-prompt path: evict softer close-prompt
            // tiers so the cross-written `.tabCloseKey` actually wins
            // the next close lookup.
            perWindow.removeAll()
            perSession = nil
            persistQuit(decision: decision, config: config)
            // Cross-write the close-prompt key. keepSims → detach,
            // shutdownSims → shutdown.
            let close: TabCloseDecision = decision == .shutdownSims ? .shutdown : .detach
            persistClose(decision: close, config: config)
        }
    }

    /// Record "don't ask again" for the multi-pane tab-close confirm.
    /// A separate track from `recordClose`: the confirm stores no
    /// disposition, only the fact that it should stop appearing, so the
    /// tiers are a window set and a flag rather than decisions.
    ///
    /// Unlike `recordClose`, `.always` evicts nothing: every tier
    /// stores the same fact and `lookupPaneConfirmSuppressed` ORs them,
    /// so no softer tier can contradict the just-written persistent
    /// value. It also cross-writes nothing; whether to confirm a
    /// multi-pane close is orthogonal to what happens to sims.
    func recordPaneConfirmSuppression(
        scope: SuppressionScope,
        windowID: WindowID?,
        config: ConfigFile
    ) {
        switch scope {
        case .window:
            if let windowID {
                paneConfirmPerWindow.insert(windowID)
            }

        case .session:
            paneConfirmPerSession = true

        case .appExit:
            // Not a valid scope for close prompts; the dropdown only
            // offers `.appExit` in the quit prompt. If a caller reaches
            // here, treat it as a no-op rather than mis-persisting.
            break

        case .always:
            config.setValue("close", forKey: CloseDecisions.tabClosePanesKey)
            config.seedDocumentedExamples()
            try? config.save()
        }
    }

    /// Whether the multi-pane tab-close confirm is suppressed for
    /// `windowID`. Any tier suffices: window set, session flag, or a
    /// persistent `tab-close-multi-pane = close`. An explicit `ask` (or
    /// an absent key) keeps the confirm.
    func lookupPaneConfirmSuppressed(windowID: WindowID?, config: ConfigFile) -> Bool {
        if let windowID, paneConfirmPerWindow.contains(windowID) {
            return true
        }
        if paneConfirmPerSession {
            return true
        }
        return config.value(forKey: CloseDecisions.tabClosePanesKey) == "close"
    }

    /// Resolve the close prompt's pre-stored decision. Returns nil
    /// when no tier hits, at which point the caller shows the dialog.
    func lookupClose(windowID: WindowID?, config: ConfigFile) -> TabCloseDecision? {
        if let windowID, let pinned = perWindow[windowID] {
            return pinned
        }
        if let session = perSession {
            return session
        }
        switch config.value(forKey: CloseDecisions.tabCloseKey) {
        case "detach":
            return .detach

        case "shutdown":
            return .shutdown

        default:
            return nil
        }
    }

    /// Resolve the quit prompt's pre-stored decision. The quit
    /// dropdown only offers permanent scopes (`.appExit`, `.always`),
    /// so there's no in-memory tier to consult; the persistent file
    /// is the only state.
    func lookupQuit(config: ConfigFile) -> QuitDecision? {
        switch config.value(forKey: CloseDecisions.quitWithSimsKey) {
        case "keep":
            return .keepSims

        case "shutdown":
            return .shutdownSims

        default:
            return nil
        }
    }

    private func persistClose(decision: TabCloseDecision, config: ConfigFile) {
        config.setValue(
            decision == .shutdown ? "shutdown" : "detach",
            forKey: CloseDecisions.tabCloseKey
        )
        config.seedDocumentedExamples()
        try? config.save()
    }

    private func persistQuit(decision: QuitDecision, config: ConfigFile) {
        config.setValue(
            decision == .shutdownSims ? "shutdown" : "keep",
            forKey: CloseDecisions.quitWithSimsKey
        )
        config.seedDocumentedExamples()
        try? config.save()
    }
}
