// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// TabTitleViewModel precedence (pure-logic tests). The chain is:
/// manual rename > OSC title > session name > CWD basename > "shell";
/// each source clears independently. The full OSC-7 path is tracked
/// alongside the chain, backing the titlebar proxy icon rather than
/// the label.
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
        // Clearing creation-time session metadata falls back to the CWD
        // basename, then "shell":
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
        // The daemon already carries the session name, so the cached label is
        // present only when it says more.
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
        // name downstream, republishing what the daemon already carries.
        let model = TabTitleViewModel()
        model.updateSessionName("branch")
        model.updateOSCTitle("branch\u{200B}")
        #expect(model.publishableTitle == nil)

        // And the published value is the normalized one, not the raw title.
        model.updateOSCTitle("vim\u{200B} foo")
        #expect(model.publishableTitle == "vim foo")
    }

    @Test
    func adoptingAnotherTerminalDropsTheDepartedOnesLabel() {
        // Focus moving to another terminal of a split tab re-points the label.
        // The automatic sources are bound to the terminal left behind, so
        // without a reseed the newly bound session would be published under
        // the departed terminal's activity string.
        let model = TabTitleViewModel()
        let first = TerminalPaneID(value: 1)
        let second = TerminalPaneID(value: 2)
        model.adoptTitleTerminal(
            id: first,
            oscTitle: nil,
            workingDirectory: nil,
            sessionName: "branch"
        )
        model.updateOSCTitle("vim secret.swift")
        model.updateWorkingDirectory(path: "/tmp/first")
        #expect(model.publishableTitle == "vim secret.swift")

        // Re-adopting the same terminal changes nothing.
        model.adoptTitleTerminal(
            id: first,
            oscTitle: nil,
            workingDirectory: nil,
            sessionName: "branch"
        )
        #expect(model.publishableTitle == "vim secret.swift")

        model.adoptTitleTerminal(
            id: second,
            oscTitle: nil,
            workingDirectory: "/tmp/second",
            sessionName: nil
        )
        #expect(model.displayTitle == "second")
        #expect(model.publishableTitle == "second")
    }

    @Test
    func adoptingAnotherTerminalKeepsAManualRename() {
        // The user named the TAB, not the terminal, and a manual title
        // outranks every automatic source anyway.
        let model = TabTitleViewModel()
        model.adoptTitleTerminal(
            id: TerminalPaneID(value: 1),
            oscTitle: nil,
            workingDirectory: nil,
            sessionName: "branch"
        )
        model.renameManually(to: "Build")
        model.adoptTitleTerminal(
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

    @Test
    func retainsTheFullCWDPathAlongsideTheBasename() {
        // The label takes the basename; the proxy icon needs the whole path to
        // resolve a folder Finder can open.
        let model = TabTitleViewModel()
        model.updateWorkingDirectory(path: "/Users/jane/projects/foo")
        #expect(model.lastCWDBasename == "foo")
        #expect(model.lastCWDPath == "/Users/jane/projects/foo")
    }

    @Test
    func anEmptyCWDClearsBothTheBasenameAndThePath() {
        // A cleared path has to leave no folder rather than a stale one: the
        // icon is a control, so a leftover would open the wrong directory.
        let model = TabTitleViewModel()
        model.updateWorkingDirectory(path: "/tmp/foo")
        model.updateWorkingDirectory(path: "")
        #expect(model.lastCWDBasename == nil)
        #expect(model.lastCWDPath == nil)
        #expect(model.displayTitle == "shell")
    }

    @Test
    func adoptingAnotherTerminalReseedsTheCWDPath() {
        // The proxy icon follows the terminal the label is bound to, so
        // adopting another has to re-point it, and clear it when the newly
        // bound terminal has no cwd.
        let model = TabTitleViewModel()
        model.adoptTitleTerminal(
            id: TerminalPaneID(value: 1),
            oscTitle: nil,
            workingDirectory: "/tmp/first",
            sessionName: nil
        )
        #expect(model.lastCWDPath == "/tmp/first")
        model.adoptTitleTerminal(
            id: TerminalPaneID(value: 2),
            oscTitle: nil,
            workingDirectory: "/tmp/second",
            sessionName: nil
        )
        #expect(model.lastCWDPath == "/tmp/second")
        model.adoptTitleTerminal(
            id: TerminalPaneID(value: 3),
            oscTitle: nil,
            workingDirectory: nil,
            sessionName: nil
        )
        #expect(model.lastCWDPath == nil)
    }

    @Test
    func aFocusedDeviceNameOutranksTheOSCTitle() {
        // While a device pane holds focus it is the most specific thing the
        // tab can say; the terminal's activity is happening in the background.
        let model = TabTitleViewModel()
        model.updateSessionName("branch")
        model.updateOSCTitle("vim foo.swift")
        model.updateFocusedDeviceName("iPhone 17 Pro")
        #expect(model.displayTitle == "iPhone 17 Pro")
    }

    @Test
    func aManualRenameOutranksAFocusedDeviceName() {
        // The user named the TAB. Nothing automatic displaces that.
        let model = TabTitleViewModel()
        model.renameManually(to: "Build")
        model.updateFocusedDeviceName("iPhone 17 Pro")
        #expect(model.displayTitle == "Build")
    }

    @Test
    func clearingTheDeviceNameRestoresTheTerminalTiers() {
        // Focus returning to a terminal must not strand the device's name on
        // a tab the user has moved on from.
        let model = TabTitleViewModel()
        model.updateOSCTitle("vim foo.swift")
        model.updateFocusedDeviceName("iPhone 17 Pro")
        #expect(model.displayTitle == "iPhone 17 Pro")
        model.updateFocusedDeviceName(nil)
        #expect(model.displayTitle == "vim foo.swift")
    }

    @Test
    func aWhitespaceDeviceNameClearsTheTier() {
        let model = TabTitleViewModel()
        model.updateOSCTitle("vim foo.swift")
        model.updateFocusedDeviceName("   ")
        #expect(model.displayTitle == "vim foo.swift")
    }

    @Test
    func theDeviceNameIsNotPublishedToTheDaemon() {
        // The cache is keyed by session, and a device's name says nothing
        // about what that terminal session is doing.
        let model = TabTitleViewModel()
        model.updateSessionName("branch")
        model.updateFocusedDeviceName("iPhone 17 Pro")
        #expect(model.displayTitle == "iPhone 17 Pro")
        #expect(model.publishableTitle == nil)

        model.updateOSCTitle("vim foo.swift")
        #expect(model.displayTitle == "iPhone 17 Pro")
        #expect(model.publishableTitle == "vim foo.swift")
    }

    @Test
    func adoptingATerminalLeavesAFocusedDeviceNameIntact() {
        // The two bindings are independent: a terminal closing underneath a
        // focused device pane re-seats one without disturbing the other.
        let model = TabTitleViewModel()
        model.updateFocusedDeviceName("iPhone 17 Pro")
        model.adoptTitleTerminal(
            id: TerminalPaneID(value: 2),
            oscTitle: "vim other.swift",
            workingDirectory: nil,
            sessionName: "other"
        )
        #expect(model.displayTitle == "iPhone 17 Pro")
    }

    @Test
    func aManualRenameLeavesTheCWDPathIntact() {
        // The proxy icon addresses the directory, not the label, so renaming
        // the tab must not move where the folder points.
        let model = TabTitleViewModel()
        model.updateWorkingDirectory(path: "/tmp/foo")
        model.renameManually(to: "Build")
        #expect(model.displayTitle == "Build")
        #expect(model.lastCWDPath == "/tmp/foo")
    }
}
