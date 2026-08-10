// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabTitleViewModel precedence (pure-logic tests). The chain is:
// manual rename > OSC title > session name > CWD basename > "shell";
// each source clears independently.

@testable import App
import Testing

@MainActor
struct TabTitleViewModelTests {
    @Test
    func fallsBackToShell() {
        #expect(TabTitleViewModel().displayTitle == "shell")
    }

    @Test
    func precedenceManualOverOSCOverSessionNameOverCWD() {
        let model = TabTitleViewModel()
        model.updateWorkingDirectory(path: "/Users/jane/projects/foo")
        #expect(model.displayTitle == "foo")
        // A session name (worktree branch) wins over the CWD
        // basename. When the user is sitting in `~/projects/foo` but
        // the session was opened in the worktree of branch
        // `feature-x`, the tab strip surfaces the branch.
        model.updateSessionName("feature-x")
        #expect(model.displayTitle == "feature-x")
        model.updateOSCTitle("zsh")
        #expect(model.displayTitle == "zsh")        // OSC wins over session name
        model.renameManually(to: "Build")
        #expect(model.displayTitle == "Build")      // manual wins over OSC
        model.updateOSCTitle("vim")
        #expect(model.displayTitle == "Build")      // manual still wins
    }

    @Test
    func clearingRestoresLowerPrecedence() {
        let model = TabTitleViewModel()
        model.updateWorkingDirectory(path: "/tmp/foo")
        model.updateOSCTitle("zsh")
        model.renameManually(to: "Build")
        model.renameManually(to: "   ")             // whitespace clears manual
        #expect(model.displayTitle == "zsh")
        model.updateOSCTitle("")                    // empty clears OSC
        #expect(model.displayTitle == "foo")
    }

    @Test
    func sessionNameAlsoFallsBackPastEmptyInputs() {
        // Clearing the session name (e.g. a future `tab rename` to
        // nothing) falls back to the CWD basename, then "shell":
        // the chain collapses cleanly through the optionals.
        let model = TabTitleViewModel()
        model.updateSessionName("branch")
        #expect(model.displayTitle == "branch")
        model.updateSessionName("   ")              // whitespace clears
        #expect(model.displayTitle == "shell")
        model.updateWorkingDirectory(path: "/tmp/foo")
        #expect(model.displayTitle == "foo")
        model.updateSessionName(nil)                // explicit nil clears
        #expect(model.displayTitle == "foo")
    }

    @Test
    func publishableTitleDropsWhatTheSessionNameAlreadySays() {
        // `tabs.list` carries the session name in its own field, so the
        // wire value is the label only when the label says more.
        let model = TabTitleViewModel()
        #expect(model.publishableTitle == nil)       // the generic fallback
        model.updateWorkingDirectory(path: "/tmp/foo")
        #expect(model.publishableTitle == "foo")     // no name: the CWD says more
        model.updateSessionName("branch")
        #expect(model.publishableTitle == nil)       // the label IS the name
        model.updateOSCTitle("vim foo")
        #expect(model.publishableTitle == "vim foo")
        model.updateOSCTitle("branch")               // shell echoes the name
        #expect(model.publishableTitle == nil)
        model.renameManually(to: "branch")           // so does a rename
        #expect(model.publishableTitle == nil)
        model.renameManually(to: "Build")
        #expect(model.publishableTitle == "Build")
    }

    @Test
    func publishableTitleComparesTheNormalizedForms() {
        // The comparison has to run on what actually crosses the wire.
        // Comparing raw text lets a title that only decorates the name with
        // invisible scalars read as different here and then normalize to the
        // name downstream, republishing what `tabs.list` already carries.
        let model = TabTitleViewModel()
        model.updateSessionName("branch")
        model.updateOSCTitle("branch\u{200B}")
        #expect(model.publishableTitle == nil)

        // And the published value is the normalized one, not the raw title.
        model.updateOSCTitle("vim\u{200B} foo")
        #expect(model.publishableTitle == "vim foo")
    }

    @Test
    func promotingANewPrimaryTerminalDropsTheDepartedOnesLabel() {
        // Closing the primary terminal of a split tab re-seats the tab's
        // representative session. The automatic sources are bound to the old
        // terminal, so without a reseed the promoted session would be
        // published under the departed terminal's activity string.
        let model = TabTitleViewModel()
        let first = TerminalPaneID(value: 1)
        let second = TerminalPaneID(value: 2)
        model.adoptPrimaryTerminal(
            id: first,
            oscTitle: nil,
            workingDirectory: nil,
            sessionName: "branch"
        )
        model.updateOSCTitle("vim secret.swift")
        model.updateWorkingDirectory(path: "/tmp/first")
        #expect(model.publishableTitle == "vim secret.swift")

        // Re-adopting the same terminal changes nothing.
        model.adoptPrimaryTerminal(
            id: first,
            oscTitle: nil,
            workingDirectory: nil,
            sessionName: "branch"
        )
        #expect(model.publishableTitle == "vim secret.swift")

        model.adoptPrimaryTerminal(
            id: second,
            oscTitle: nil,
            workingDirectory: "/tmp/second",
            sessionName: nil
        )
        #expect(model.displayTitle == "second")
        #expect(model.publishableTitle == "second")
    }

    @Test
    func promotionKeepsAManualRename() {
        // The user named the TAB, not the terminal, and a manual title
        // outranks every automatic source anyway.
        let model = TabTitleViewModel()
        model.adoptPrimaryTerminal(
            id: TerminalPaneID(value: 1),
            oscTitle: nil,
            workingDirectory: nil,
            sessionName: "branch"
        )
        model.renameManually(to: "Build")
        model.adoptPrimaryTerminal(
            id: TerminalPaneID(value: 2),
            oscTitle: "vim other.swift",
            workingDirectory: nil,
            sessionName: "other"
        )
        #expect(model.displayTitle == "Build")
        #expect(model.publishableTitle == "Build")
    }

    @Test
    func sessionNameSurvivesOSCTitleCycle() {
        // Regression guard: the OSC title arriving and then being
        // cleared (an empty OSC frame) must fall back to the session
        // name, not skip past it to the CWD.
        let model = TabTitleViewModel()
        model.updateSessionName("branch")
        model.updateWorkingDirectory(path: "/tmp/foo")
        model.updateOSCTitle("vim foo")
        #expect(model.displayTitle == "vim foo")
        model.updateOSCTitle("")
        #expect(model.displayTitle == "branch")     // back to session name
    }
}
