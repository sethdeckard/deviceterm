// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Observation

/// A tab's strip/window label state, extracted
/// from TabContentViewController as an `@Observable` view model used
/// with the `observe()` keystone.
///
/// Label inputs, highest precedence first:
///   1. manual rename: the user explicitly named it; nothing else wins
///   2. focused device name: while a simulator or device pane holds focus it
///      is the most specific thing the tab can say, and it outranks the
///      background terminal's activity
///   3. shell OSC 0/2 title: often command-aware ("vim foo.swift") and
///      worth surfacing in real time when the shell sends it
///   4. session name: session-stable creation metadata, such as a worktree
///      branch detected at session creation; a
///      meaningful default when the shell isn't emitting OSC titles
///   5. working-directory basename: the OSC-7 CWD, the last resort before
///      the generic "shell" fallback
///
/// Each source writes only its own field (via the mutators below), so a
/// later CWD or OSC update can't erase a manual rename. The fields live
/// on the tab, so they survive strip rebuilds and tab switches.
///
/// The OSC-7 path is also retained in full, which is not a label input:
/// it backs the window's titlebar proxy icon, whose directory is
/// independent of whatever the label ends up saying.
@MainActor
@Observable
final class TabTitleViewModel {
    private(set) var manualTitle: String?
    private(set) var lastOSCTitle: String?
    /// The bound terminal pane's current name: the worktree branch supplied at
    /// `session.create`, until a `pane rename` replaces it. Sits between the
    /// OSC title and the CWD basename in the precedence chain, a stable
    /// identifier that wins over the CWD inference but yields to a real-time
    /// OSC title from the shell.
    ///
    /// `publishableTitle` measures its candidate against this, so the baseline
    /// follows a rename. A terminal rename stays GUI-side: the intent layer
    /// sends no daemon pane id for a terminal, so the daemon's session name
    /// keeps its `session.create` value however many times the pane is
    /// renamed. The GUI never reads that value back, and `tab.list` projects
    /// GUI state, so nothing a caller sees is wrong.
    ///
    /// A daemon restart closes the gap on its own. The restore inventory
    /// re-supplies this GUI value, so a session the daemon has to re-insert
    /// adopts the current name; one it still holds keeps the old one.
    private(set) var sessionName: String?
    private(set) var lastCWDBasename: String?
    /// Full OSC-7 path, retained alongside the basename to back the titlebar
    /// proxy icon. `lastCWDBasename` is the label input; this is the directory
    /// the icon resolves to, so dragging it or opening it in Finder acts on the
    /// tab being displayed.
    private(set) var lastCWDPath: String?
    /// Name of the simulator or device pane currently holding focus. Nil
    /// while a terminal holds focus, which is what makes the tier collapse
    /// back to the terminal's own activity rather than stranding a device
    /// name on a tab the user has moved on from.
    ///
    /// Not a daemon-cached input: `publishableTitle` ignores it, because a
    /// device's name says nothing about what the terminal session it would be
    /// cached under is doing.
    private(set) var focusedDeviceName: String?
    /// The terminal the automatic label sources currently describe. A tab
    /// shows one label and it belongs to whichever terminal the user last
    /// focused, so all three automatic fields are bound to that terminal and
    /// have to be reseeded when focus moves to another one.
    private(set) var titleTerminalID: TerminalPaneID?

    /// Effective tab-strip / window label derived from the precedence
    /// above.
    var displayTitle: String {
        manualTitle ?? focusedDeviceName ?? lastOSCTitle ?? sessionName ?? lastCWDBasename ?? "shell"
    }

    /// The cacheable part of the tab's label, as far as it says anything the
    /// daemon doesn't already know. The daemon already stores the session
    /// name, so a label that is identical to it adds nothing; the generic
    /// "shell" fallback is also omitted. A manual title, shell OSC title, or
    /// inferred CWD basename is cached only when it adds information.
    ///
    /// Not necessarily what the tab shows. `focusedDeviceName` outranks the
    /// automatic terminal tiers on screen, though not a manual title, and is
    /// never cached. So the two diverge while a device pane holds focus and
    /// the tab carries no manual rename.
    ///
    /// The comparison runs on the *normalized* forms, which is also what
    /// crosses the wire. Comparing raw text would let an OSC title that
    /// merely decorates the name with invisible scalars ("branch\u{200B}")
    /// read as different here and then normalize to the name downstream,
    /// republishing what the daemon already stores.
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
    /// terminal's own latest values. A no-op while the bound terminal is
    /// unchanged; when focus moves to another terminal (or the bound one
    /// closes) it drops the departed terminal's OSC title, CWD, and session
    /// name, so the tab stops showing one session's activity under another.
    /// The label is also cached under that terminal's session, so a stale
    /// value would misattribute activity both on screen and in daemon state.
    ///
    /// A manual rename is deliberately untouched: the user named the tab,
    /// not the terminal, and it outranks every automatic source anyway.
    func adoptTitleTerminal(
        id: TerminalPaneID,
        oscTitle: String?,
        workingDirectory: String?,
        sessionName: String?
    ) {
        guard id != titleTerminalID else { return }
        titleTerminalID = id
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

    /// Record the name of the simulator or device pane holding focus. Nil, or
    /// a name that is all whitespace, clears the tier so the label falls back
    /// to the bound terminal's own sources.
    ///
    /// Writes only on a change: the reconcile pass re-applies this every time
    /// anything about the tab moves, and Observation fires on every write,
    /// not only on the ones that alter the value.
    func updateFocusedDeviceName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard resolved != focusedDeviceName else { return }
        focusedDeviceName = resolved
    }

    /// Record the working directory from an OSC 7 update: the basename for the
    /// label, the full path for the proxy icon. An empty path clears both.
    func updateWorkingDirectory(path: String) {
        let base = (path as NSString).lastPathComponent
        lastCWDBasename = base.isEmpty ? nil : base
        lastCWDPath = path.isEmpty ? nil : path
    }

    /// Apply a manual rename. Empty input resets to automatic titling
    /// (focused device name / OSC title / session name / CWD basename).
    func renameManually(to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        manualTitle = trimmed.isEmpty ? nil : trimmed
    }

    /// Set the session-bound name. Nil clears it.
    /// `TabContentViewController.init` calls this with the worktree
    /// branch returned from `session.create`. Tab rename writes the separate
    /// manual-title tier and leaves this creation metadata unchanged.
    /// Writes only on a change, for the same reason as
    /// `updateFocusedDeviceName`: the reconcile pass re-applies it every time
    /// anything about the tab moves.
    func updateSessionName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard resolved != sessionName else { return }
        sessionName = resolved
    }
}
