// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabTitleViewModel: a tab's strip/window label state, extracted
// from TabContentViewController as an `@Observable` view model used
// with the `observe()` keystone.
//
// Label inputs, highest precedence first:
//   1. manual rename: the user explicitly named it; nothing else wins
//   2. shell OSC 0/2 title: often command-aware ("vim foo.swift") and
//      worth surfacing in real time when the shell sends it
//   3. session name: session-stable identity (e.g. worktree branch
//      at session-create, or a future `deviceterm tab rename`); a
//      meaningful default when the shell isn't emitting OSC titles
//   4. working-directory basename: the OSC-7 CWD, the last resort before
//      the generic "shell" fallback
//
// Each source writes only its own field (via the mutators below), so a
// later CWD or OSC update can't erase a manual rename. The fields live
// on the tab, so they survive strip rebuilds and tab switches.

import DaemonProtocol
import Foundation
import Observation

@MainActor
@Observable
final class TabTitleViewModel {
    private(set) var manualTitle: String?
    private(set) var lastOSCTitle: String?
    /// Session-bound name (worktree branch at session.create; or a
    /// future `deviceterm tab rename` value). Sits between the OSC title
    /// and the CWD basename in the precedence chain: a stable
    /// identifier that wins over the CWD inference but yields to a
    /// real-time OSC title from the shell.
    private(set) var sessionName: String?
    private(set) var lastCWDBasename: String?
    /// The terminal the automatic label sources currently describe. A tab
    /// shows one label and it belongs to the primary terminal, so all three
    /// automatic fields are bound to that terminal and have to be reseeded
    /// when a different one is promoted.
    private(set) var primaryTerminalID: TerminalPaneID?

    /// Effective tab-strip / window label derived from the precedence
    /// above.
    var displayTitle: String {
        manualTitle ?? lastOSCTitle ?? sessionName ?? lastCWDBasename ?? "shell"
    }

    /// The label as far as it says anything the daemon doesn't already
    /// know. `tabs.list` carries the session name in its own field, so a
    /// label that IS the session name adds nothing, and the generic
    /// "shell" fallback is pure noise on a daemon-wide read; both publish
    /// as nil and consumers fall back to the name. Only a real signal (a
    /// rename, a shell's OSC title, a CWD basename standing in for an
    /// absent name) goes on the wire.
    ///
    /// The comparison runs on the *normalized* forms, which is also what
    /// crosses the wire. Comparing raw text would let an OSC title that
    /// merely decorates the name with invisible scalars ("branch\u{200B}")
    /// read as different here and then normalize to the name downstream,
    /// republishing what `tabs.list` already carries.
    var publishableTitle: String? {
        // Read unconditionally so Observation keeps tracking it: the name is
        // both the fallback the daemon already has and the value every
        // candidate is measured against.
        let name = DisplayTitleNormalizer.normalize(sessionName)
        let candidate: String?
        if let manualTitle {
            candidate = manualTitle
        } else if let lastOSCTitle {
            candidate = lastOSCTitle
        } else {
            // With a name present the label IS the name; when it later
            // clears, the CWD basename becomes publishable.
            candidate = sessionName == nil ? lastCWDBasename : nil
        }
        guard let normalized = DisplayTitleNormalizer.normalize(candidate) else { return nil }
        return normalized == name ? nil : normalized
    }

    /// Bind the automatic label sources to `id`, reseeding them from that
    /// terminal's own latest values. A no-op while the primary is unchanged;
    /// on promotion (the primary terminal of a split tab closed) it drops
    /// the departed terminal's OSC title, CWD, and session name, so the tab
    /// stops showing one session's activity under another. That now matters
    /// twice over: the label is published, so a stale one misattributes on
    /// the wire as well as on screen.
    ///
    /// A manual rename is deliberately untouched: the user named the tab,
    /// not the terminal, and it outranks every automatic source anyway.
    func adoptPrimaryTerminal(
        id: TerminalPaneID,
        oscTitle: String?,
        workingDirectory: String?,
        sessionName: String?
    ) {
        guard id != primaryTerminalID else { return }
        primaryTerminalID = id
        updateOSCTitle(oscTitle ?? "")
        updateWorkingDirectory(path: workingDirectory ?? "")
        updateSessionName(sessionName)
    }

    /// Record the shell's latest OSC 0/2 title. An empty string clears it
    /// (some shells emit an empty title to mean "no title") so the label
    /// falls back to the session name / CWD basename rather than going blank.
    func updateOSCTitle(_ title: String) {
        lastOSCTitle = title.isEmpty ? nil : title
    }

    /// Record the working-directory basename from an OSC 7 update.
    func updateWorkingDirectory(path: String) {
        let base = (path as NSString).lastPathComponent
        lastCWDBasename = base.isEmpty ? nil : base
    }

    /// Apply a manual rename. Empty input resets to automatic titling
    /// (OSC title / session name / CWD basename).
    func renameManually(to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        manualTitle = trimmed.isEmpty ? nil : trimmed
    }

    /// Set the session-bound name. Nil clears it.
    /// `TabContentViewController.init` calls this with the worktree
    /// branch returned from `session.create`; a future `tab rename`
    /// route will call it when the daemon-side name changes.
    func updateSessionName(_ name: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty else {
            sessionName = nil
            return
        }
        sessionName = name
    }
}
