// SPDX-License-Identifier: GPL-3.0-or-later
//
// The unhandled-action diagnostic. A user `keybind =` that fires an action
// deviceterm answers itself gets no answer; with no report the callback
// returns false in silence and the shortcut looks broken.
//
// The property that matters is that nothing is filtered by tag, because a
// tag does not reveal whether a keystroke produced the action. Any filter
// resting on that guess silences a real shortcut. So the tests below pin
// the absence of a filter rather than the contents of one: an unlabeled
// tag reports, a labeled tag reports, and every app-targeted binding
// action reports.
//
// `reportedTags` is process-wide, so every test resets it first. These
// bodies never suspend, which alone makes them atomic on the main actor.
// The suite is serialized so a suspending test cannot interleave its reset
// with another test's run.

import GhosttyKit
@testable import LibghosttyBridge
import Testing

/// App-targeted actions covered by this table. libghostty dispatches them
/// against the app rather than a surface (`src/App.zig`,
/// `App.performAction`), so they reach `action_cb` before any surface is
/// resolved and the callback must report them from its guard rather than
/// its `default:` arm. `show_gtk_inspector` is app-targeted too and is
/// covered by `misleadinglyNamedBindingActions` below.
///
/// File scope, not a static member: `@Test(arguments:)` evaluates its
/// argument outside the actor, so a `@MainActor` type's static property
/// is unreachable from there.
private let appTargetedBindingActions: [(String, UInt32)] = [
    ("quit", GHOSTTY_ACTION_QUIT.rawValue),
    ("open_config", GHOSTTY_ACTION_OPEN_CONFIG.rawValue),
    ("reload_config", GHOSTTY_ACTION_RELOAD_CONFIG.rawValue),
    ("close_all_windows", GHOSTTY_ACTION_CLOSE_ALL_WINDOWS.rawValue),
    ("toggle_quick_terminal", GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL.rawValue),
    ("toggle_visibility", GHOSTTY_ACTION_TOGGLE_VISIBILITY.rawValue),
    ("check_for_updates", GHOSTTY_ACTION_CHECK_FOR_UPDATES.rawValue),
    ("undo", GHOSTTY_ACTION_UNDO.rawValue),
    ("redo", GHOSTTY_ACTION_REDO.rawValue)
]

/// Tags whose names invite the wrong conclusion about whether a binding
/// produced them. Each stays covered so no classification can silence its
/// diagnostic.
private let misleadinglyNamedBindingActions: [(String, UInt32)] = [
    // Emitted only from the `toggle_readonly` binding, despite reading
    // like after-the-fact engine feedback.
    ("readonly", GHOSTTY_ACTION_READONLY.rawValue),
    // Core `App.performAction` ships it on every apprt, not just GTK.
    ("show_gtk_inspector", GHOSTTY_ACTION_SHOW_GTK_INSPECTOR.rawValue),
    // `toggle_secure_input` sends `.toggle`; only the payload separates
    // it from termios password detection, so the tag itself must report.
    ("secure_input", GHOSTTY_ACTION_SECURE_INPUT.rawValue)
]

@MainActor
@Suite(.serialized)
struct GhosttyActionDispositionTests {
    /// Far above any tag libghostty defines, so it stands in for one this
    /// build has never seen.
    private static let unknownTag = UInt32.max

    // MARK: - Nothing is filtered by tag

    @Test
    func reportsATagItHasNoLabelFor() {
        // The load-bearing property. A libghostty upgrade adds actions
        // faster than a hand table tracks them, so an unlabeled tag must
        // still surface by number when no label exists.
        GhosttyActionDisposition.resetReportedTags()
        #expect(GhosttyActionDisposition.name(for: Self.unknownTag) == nil)
        let message = GhosttyActionDisposition.unhandledMessage(for: Self.unknownTag)
        #expect(message?.contains("\(Self.unknownTag)") == true)
    }

    @Test(arguments: appTargetedBindingActions)
    func reportsEveryAppTargetedBindingAction(named name: String, tag: UInt32) {
        // These bypass the surface-targeted switch entirely, so they are
        // the ones a missing report would hide most completely.
        GhosttyActionDisposition.resetReportedTags()
        #expect(GhosttyActionDisposition.unhandledMessage(for: tag)?.contains(name) == true)
    }

    @Test(arguments: misleadinglyNamedBindingActions)
    func reportsTagsWhoseNamesInviteFiltering(named name: String, tag: UInt32) {
        GhosttyActionDisposition.resetReportedTags()
        #expect(GhosttyActionDisposition.unhandledMessage(for: tag)?.contains(name) == true)
    }

    // MARK: - One report per tag

    @Test
    func reportsEachTagOnce() {
        GhosttyActionDisposition.resetReportedTags()
        let newTab = GHOSTTY_ACTION_NEW_TAB.rawValue
        let newSplit = GHOSTTY_ACTION_NEW_SPLIT.rawValue

        let first = GhosttyActionDisposition.unhandledMessage(for: newTab)
        let repeated = GhosttyActionDisposition.unhandledMessage(for: newTab)
        let other = GhosttyActionDisposition.unhandledMessage(for: newSplit)

        #expect(first != nil)
        #expect(repeated == nil, "a repeated tag must stay silent")
        #expect(other != nil, "a second tag reports on its own")
    }

    @Test
    func resetClearsTheReportedSet() {
        GhosttyActionDisposition.resetReportedTags()
        let tag = GHOSTTY_ACTION_CLOSE_TAB.rawValue
        #expect(GhosttyActionDisposition.unhandledMessage(for: tag) != nil)
        GhosttyActionDisposition.resetReportedTags()
        #expect(GhosttyActionDisposition.unhandledMessage(for: tag) != nil)
    }

    // MARK: - Message shape

    @Test
    func namesTheActionInTheMessage() {
        GhosttyActionDisposition.resetReportedTags()
        let message = GhosttyActionDisposition.unhandledMessage(
            for: GHOSTTY_ACTION_NEW_TAB.rawValue
        )
        #expect(message?.contains("new_tab") == true)
        #expect(message?.hasSuffix("\n") == true, "stderr writes are line-terminated")
    }

    @Test
    func claimsOnlyThatTheActionWentUnhandled() {
        // Not "declined". The callback cannot see whether a keystroke
        // caused an action, so the wording states what is observable and
        // never why.
        GhosttyActionDisposition.resetReportedTags()
        let message = GhosttyActionDisposition.unhandledMessage(
            for: GHOSTTY_ACTION_NEW_TAB.rawValue
        )
        #expect(message?.contains("unhandled") == true)
        #expect(message?.contains("declined") != true)
    }

    @Test
    func labelsPromptTitleByItsActionNotAGuessedBinding() {
        // One action can back several bindings: `prompt_surface_title` and
        // `prompt_tab_title` both emit this tag, discriminated by a
        // payload the diagnostic doesn't read. Naming either one would be
        // wrong half the time, so it reports the action's own name.
        #expect(
            GhosttyActionDisposition.name(for: GHOSTTY_ACTION_PROMPT_TITLE.rawValue)
                == "prompt_title"
        )
    }
}
