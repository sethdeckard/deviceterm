// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

@MainActor
struct IntentDispatcherTests {
    private struct Harness {
        let dispatcher: IntentDispatcher
        let workspace: WorkspaceViewModel
        let fake: FakeDaemonClient
        let delegate: RecordingActionDelegate
    }

    private func makeHarness() -> Harness {
        let workspace = WorkspaceViewModel()
        let fake = FakeDaemonClient()
        let delegate = RecordingActionDelegate()
        let dispatcher = IntentDispatcher(
            workspace: workspace,
            router: Router(workspace: workspace, daemon: fake),
            actionDelegate: delegate
        )
        return Harness(
            dispatcher: dispatcher,
            workspace: workspace,
            fake: fake,
            delegate: delegate
        )
    }

    private func appendTab(
        _ workspace: WorkspaceViewModel,
        windowID: WindowID,
        tabID: TabID,
        sessionId: String,
        terminals: [TerminalPaneState]? = nil,
        panes: [SimPaneState] = [],
        devicePanes: [DevicePaneState] = []
    ) {
        let list: TabListViewModel
        if let window = workspace.window(id: windowID) {
            list = window.tabs
        } else {
            list = TabListViewModel()
            workspace.addWindow(
                WindowState(
                    id: windowID,
                    tabs: list,
                    name: "window-\(windowID.value)"
                )
            )
        }
        let primary = TerminalPaneState(
            id: TerminalPaneID(value: tabID.value),
            sessionId: sessionId,
            capability: "cap"
        )
        list.append(
            TabState(
                id: tabID,
                terminals: terminals ?? [primary],
                simPanes: panes,
                devicePanes: devicePanes,
                name: "tab-\(tabID.value)"
            )
        )
    }

    @Test
    func workspacePaneRenameCommitsGUIAndDaemonNamesTogether() async {
        let harness = makeHarness()
        let pane = SimPaneState(
            paneId: "P1",
            udid: "U-iphone17",
            displayName: "iPhone",
            family: "phone"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            panes: [pane]
        )

        let result = await harness.dispatcher.dispatch(
            .workspacePaneRename("P1", name: "phone"),
            origin: .inProcess
        )

        guard case let .data(.workspaceMutation(receipt)) = result else {
            Issue.record("expected workspace mutation; got \(result)")
            return
        }
        #expect(receipt.pane?.name == "phone")
        #expect(
            harness.delegate.paneRenames == [
                .init(
                    window: WindowID(value: 1),
                    tab: TabID(value: 1),
                    slot: .sim(udid: "U-iphone17"),
                    daemonPaneId: "P1",
                    name: "phone"
                )
            ]
        )
    }

    @Test
    func workspaceTabOpenReturnsCommittedTabAndTerminal() async {
        let harness = makeHarness()
        harness.fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S-new", capability: "C-new")
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-seed"
        )

        let result = await harness.dispatcher.dispatch(
            .workspaceTabOpen(window: nil, cwd: "/project", command: ["pwd"]),
            origin: .external(sessionID: "S-seed", hasAutomationGrant: true)
        )

        guard case let .data(.workspaceMutation(receipt)) = result else {
            Issue.record("expected workspace mutation; got \(result)")
            return
        }
        #expect(receipt.tab?.state == .ready)
        #expect(receipt.pane?.id == "S-new")
        #expect(receipt.pane?.terminal?.sessionId == "S-new")
    }

    @Test
    func workspaceTabOpenFailureReturnsTheCommittedFailedTab() async {
        let harness = makeHarness()
        harness.fake.createSessionError = FakeDaemonClient.InjectedFailure.sessionCreate
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-seed"
        )

        let result = await harness.dispatcher.dispatch(
            .workspaceTabOpen(window: nil, cwd: nil, command: nil),
            origin: .external(sessionID: "S-seed", hasAutomationGrant: true)
        )

        guard case let .error(.mutationFailed(_, committed)) = result else {
            Issue.record("expected partial mutation failure; got \(result)")
            return
        }
        #expect(committed.tab?.state == .failed)
        #expect(committed.tab?.paneCount == 0)
        #expect(committed.pane == nil)
        #expect(harness.workspace.window(id: WindowID(value: 1))?.tabs.tabs.count == 2)
    }

    @Test
    func workspacePaneSplitReturnsTheMintedTerminalSession() async {
        let harness = makeHarness()
        harness.fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S-split", capability: "C-split")
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-seed"
        )

        let result = await harness.dispatcher.dispatch(
            .workspacePaneSplit(nil, direction: .right),
            origin: .external(sessionID: "S-seed", hasAutomationGrant: false)
        )

        guard case let .data(.workspaceMutation(receipt)) = result else {
            Issue.record("expected workspace mutation; got \(result)")
            return
        }
        #expect(receipt.pane?.id == "S-split")
        #expect(receipt.tab?.paneCount == 2)
    }

    @Test
    func workspacePaneCloseRefusesTheLastTerminal() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-seed"
        )

        let result = await harness.dispatcher.dispatch(
            .workspacePaneClose(nil, mode: nil),
            origin: .external(sessionID: "S-seed", hasAutomationGrant: false)
        )

        #expect(result == .error(.wouldCloseTab))
    }

    @Test
    func workspacePaneCloseRejectsExplicitModeForTerminalAndDevice() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-seed",
            devicePanes: [
                DevicePaneState(
                    paneId: "P-device",
                    deviceId: "D-1",
                    displayName: "iPhone",
                    family: "phone"
                )
            ]
        )

        let terminal = await harness.dispatcher.dispatch(
            .workspacePaneClose("S-seed", mode: .shutdown),
            origin: .inProcess
        )
        let device = await harness.dispatcher.dispatch(
            .workspacePaneClose("P-device", mode: .detach),
            origin: .inProcess
        )

        #expect(
            terminal == .error(
                .unsupportedPane(verb: "close --mode", kind: .terminal)
            )
        )
        #expect(
            device == .error(
                .unsupportedPane(verb: "close --mode", kind: .device)
            )
        )
    }

    @Test
    func concreteSecondaryTerminalReceivesInputAndCapture() async {
        let harness = makeHarness()
        let terminals = [
            TerminalPaneState(
                id: TerminalPaneID(value: 1),
                sessionId: "S-primary",
                capability: "cap"
            ),
            TerminalPaneState(
                id: TerminalPaneID(value: 9),
                sessionId: "S-secondary",
                capability: "cap"
            )
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-primary",
            terminals: terminals
        )
        harness.delegate.captureResult = "secondary output"

        let send = await harness.dispatcher.dispatch(
            .workspacePaneSendInput("S-secondary", text: "ls\n", typeDelayMs: 12),
            origin: .inProcess
        )
        let capture = await harness.dispatcher.dispatch(
            .workspacePaneCaptureText("S-secondary", ansi: false),
            origin: .inProcess
        )
        let styledCapture = await harness.dispatcher.dispatch(
            .workspacePaneCaptureText("S-secondary", ansi: true),
            origin: .inProcess
        )

        guard case let .data(.workspaceMutation(receipt)) = send else {
            Issue.record("expected input receipt; got \(send)")
            return
        }
        #expect(receipt.pane?.id == "S-secondary")
        #expect(receipt.bytes == 3)
        #expect(
            harness.delegate.sendInputs == [
                .init(
                    window: WindowID(value: 1),
                    tab: TabID(value: 1),
                    terminal: TerminalPaneID(value: 9),
                    text: "ls\n",
                    typeDelayMillis: 12
                )
            ]
        )
        guard case let .data(.workspaceCapture(result)) = capture else {
            Issue.record("expected capture result; got \(capture)")
            return
        }
        #expect(result.pane.id == "S-secondary")
        #expect(result.text == "secondary output")
        guard case .data(.workspaceCapture) = styledCapture else {
            Issue.record("expected styled capture result; got \(styledCapture)")
            return
        }
        // Both dispatches hit the same pane; only the format differs, and
        // the flag has to reach the delegate rather than stop at the route.
        #expect(
            harness.delegate.captures == [
                .init(
                    window: WindowID(value: 1),
                    tab: TabID(value: 1),
                    terminal: TerminalPaneID(value: 9),
                    ansi: false
                ),
                .init(
                    window: WindowID(value: 1),
                    tab: TabID(value: 1),
                    terminal: TerminalPaneID(value: 9),
                    ansi: true
                )
            ]
        )
    }

    @Test
    func nonTerminalInputAndCaptureAreUnsupported() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            panes: [
                SimPaneState(
                    paneId: "P-sim",
                    udid: "U-sim",
                    displayName: "iPhone",
                    family: "phone"
                )
            ]
        )

        let send = await harness.dispatcher.dispatch(
            .workspacePaneSendInput("P-sim", text: "x", typeDelayMs: nil),
            origin: .inProcess
        )
        let capture = await harness.dispatcher.dispatch(
            .workspacePaneCaptureText("P-sim", ansi: false),
            origin: .inProcess
        )

        #expect(send == .error(.unsupportedPane(verb: "send-input", kind: .simulator)))
        #expect(capture == .error(.unsupportedPane(verb: "capture-text", kind: .simulator)))
    }

    @Test
    func workspaceWindowProjectionDoesNotExposeHiddenSelection() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 2),
            sessionId: "S-B"
        )
        guard let tabs = harness.workspace.window(id: WindowID(value: 1))?.tabs else {
            Issue.record("expected window tabs")
            return
        }
        tabs.setProtectionState(.protected, id: TabID(value: 1))
        tabs.select(id: TabID(value: 1))
        let result = await harness.dispatcher.dispatch(
            .workspaceWindowShow("window-1"),
            origin: .external(sessionID: "S-B", hasAutomationGrant: false)
        )

        guard case let .data(.workspaceWindow(detail)) = result else {
            Issue.record("expected window detail; got \(result)")
            return
        }
        #expect(detail.tabs.count == 1)
        #expect(detail.window.selectedTabId == nil)
        #expect(detail.tabs.first?.selected == false)
    }

    @Test
    func workspaceTabProjectionNormalizesThePublicTitle() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        harness.workspace.window(id: WindowID(value: 1))?.tabs.renameTab(
            id: TabID(value: 1),
            to: "safe\u{202E}gnitiaps"
        )

        let result = await harness.dispatcher.dispatch(
            .workspaceTabShow(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )

        guard case let .data(.workspaceTab(detail)) = result else {
            Issue.record("expected workspace tab detail; got \(result)")
            return
        }
        #expect(detail.tab.name == "safe\u{202E}gnitiaps")
        #expect(detail.tab.title == "safegnitiaps")
    }

    @Test
    func grantedPaneProjectionReadsTheTargetTerminalWorkingDirectory() async {
        let harness = makeHarness()
        let terminals = [
            TerminalPaneState(
                id: TerminalPaneID(value: 1),
                sessionId: "S-primary",
                capability: "cap",
                cwd: "/stale"
            ),
            TerminalPaneState(
                id: TerminalPaneID(value: 2),
                sessionId: "S-secondary",
                capability: "cap",
                cwd: "/also-stale"
            )
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-primary",
            terminals: terminals
        )
        harness.delegate.workingDirectories[TerminalPaneID(value: 2)] = "/live"

        let result = await harness.dispatcher.dispatch(
            .workspacePaneShow("S-secondary"),
            origin: .external(sessionID: "S-primary", hasAutomationGrant: true)
        )

        guard case let .data(.workspacePane(pane)) = result else {
            Issue.record("expected workspace pane; got \(result)")
            return
        }
        #expect(pane.terminal?.cwd == "/live")
        #expect(harness.delegate.workingDirectoryReads.map(\.terminal) == [TerminalPaneID(value: 2)])
    }

    @Test
    func ungrantedPaneProjectionOmitsWorkingDirectoryWithoutReadingIt() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            terminals: [
                TerminalPaneState(
                    id: TerminalPaneID(value: 1),
                    sessionId: "S-A",
                    capability: "cap",
                    cwd: "/stale"
                )
            ]
        )
        harness.delegate.workingDirectories[TerminalPaneID(value: 1)] = "/live"

        let result = await harness.dispatcher.dispatch(
            .workspacePaneShow(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )

        guard case let .data(.workspacePane(pane)) = result else {
            Issue.record("expected workspace pane; got \(result)")
            return
        }
        #expect(pane.terminal?.cwd == nil)
        #expect(harness.delegate.workingDirectoryReads.isEmpty)
    }

    @Test
    func nilSessionPaneProjectionOmitsWorkingDirectoryWithoutReadingIt() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        harness.delegate.workingDirectories[TerminalPaneID(value: 1)] = "/live"

        let result = await harness.dispatcher.dispatch(
            .workspacePaneShow("S-A"),
            origin: .external(sessionID: nil, hasAutomationGrant: true)
        )

        guard case let .data(.workspacePane(pane)) = result else {
            Issue.record("expected workspace pane; got \(result)")
            return
        }
        #expect(pane.terminal?.cwd == nil)
        #expect(harness.delegate.workingDirectoryReads.isEmpty)
    }

    @Test
    func inProcessPaneProjectionReadsWorkingDirectory() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        harness.delegate.workingDirectories[TerminalPaneID(value: 1)] = "/live"

        let result = await harness.dispatcher.dispatch(
            .workspacePaneShow("S-A"),
            origin: .inProcess
        )

        guard case let .data(.workspacePane(pane)) = result else {
            Issue.record("expected workspace pane; got \(result)")
            return
        }
        #expect(pane.terminal?.cwd == "/live")
        #expect(harness.delegate.workingDirectoryReads.count == 1)
    }

    @Test
    func missingLiveWorkingDirectoryDoesNotFallBackToStartupDirectory() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            terminals: [
                TerminalPaneState(
                    id: TerminalPaneID(value: 1),
                    sessionId: "S-A",
                    capability: "cap",
                    cwd: "/startup"
                )
            ]
        )

        let result = await harness.dispatcher.dispatch(
            .workspacePaneShow(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspacePane(pane)) = result else {
            Issue.record("expected workspace pane; got \(result)")
            return
        }
        #expect(pane.terminal?.cwd == nil)
        #expect(harness.delegate.workingDirectoryReads.count == 1)
    }

    /// The title and tty gates are independent of the working-directory gate.
    /// An ungranted caller is the case that proves it: it must still get a
    /// label and a tty, and still not get a directory.
    @Test
    func ungrantedPaneProjectionStillCarriesTitleAndTTY() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        harness.delegate.oscTitles[TerminalPaneID(value: 1)] = "vim Login.swift"
        harness.delegate.ttys[TerminalPaneID(value: 1)] = "/dev/ttys003"
        harness.delegate.workingDirectories[TerminalPaneID(value: 1)] = "/live"

        let result = await harness.dispatcher.dispatch(
            .workspacePaneShow(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )

        guard case let .data(.workspacePane(pane)) = result else {
            Issue.record("expected workspace pane; got \(result)")
            return
        }
        #expect(pane.terminal?.title == "vim Login.swift")
        #expect(pane.terminal?.tty == "/dev/ttys003")
        #expect(pane.terminal?.cwd == nil)
    }

    /// A pane can be addressable before its surface attaches, so an early
    /// projection may omit its tty.
    @Test
    func paneProjectionOmitsTTYBeforeTheSurfaceAttaches() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )

        let result = await harness.dispatcher.dispatch(
            .workspacePaneShow(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspacePane(pane)) = result else {
            Issue.record("expected workspace pane; got \(result)")
            return
        }
        #expect(pane.terminal?.tty == nil)
        #expect(pane.terminal?.title == "shell")
    }

    /// One tab can contain two terminals running different programs. Its single
    /// title cannot represent both.
    @Test
    func splitTabTerminalsReportTheirOwnTitles() async {
        let harness = makeHarness()
        let terminals = [
            TerminalPaneState(
                id: TerminalPaneID(value: 1),
                sessionId: "S-A",
                capability: "cap"
            ),
            TerminalPaneState(
                id: TerminalPaneID(value: 2),
                sessionId: "S-B",
                capability: "cap"
            )
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            terminals: terminals
        )
        harness.delegate.oscTitles = [
            TerminalPaneID(value: 1): "vim Login.swift",
            TerminalPaneID(value: 2): "swift test"
        ]

        let result = await harness.dispatcher.dispatch(
            .workspacePaneList(tab: nil, all: false),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspacePanes(panes)) = result else {
            Issue.record("expected workspace panes; got \(result)")
            return
        }
        #expect(panes.compactMap(\.terminal?.title) == ["vim Login.swift", "swift test"])
    }

    /// A tab with one terminal, no tab rename, and no focused device pane has
    /// nothing to say that its terminal does not, so both labels agree.
    @Test
    func paneAndTabTitlesAgreeForALoneTerminal() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        harness.delegate.tabDisplayTitles[TabID(value: 1)] = "vim Login.swift"
        harness.delegate.oscTitles[TerminalPaneID(value: 1)] = "vim Login.swift"

        let result = await harness.dispatcher.dispatch(
            .workspaceTabShow(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspaceTab(detail)) = result else {
            Issue.record("expected tab detail; got \(result)")
            return
        }
        #expect(detail.panes.first?.terminal?.title == detail.tab.title)
    }

    /// Where the two labels part company, and why the pane is the one worth
    /// having. The tab selects its raw label before normalizing, so an
    /// invisible OSC title wins that selection and then normalizes to nothing,
    /// dropping the tab onto its own name (or `"Terminal"` when it has none)
    /// and skipping the terminal tiers under it. The pane normalizes each tier
    /// as it goes, so the same title is passed over and the directory basename
    /// below it survives.
    ///
    /// The divergence is intentional here: aligning the labels would change GUI
    /// tab-strip behavior, which is separate from publishing a per-pane label.
    @Test
    func invisibleOSCTitleSeparatesPaneAndTabTitles() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        let invisible = "\u{200B}\u{200B}"
        harness.delegate.tabDisplayTitles[TabID(value: 1)] = invisible
        harness.delegate.oscTitles[TerminalPaneID(value: 1)] = invisible
        harness.delegate.oscWorkingDirectories[TerminalPaneID(value: 1)] = "/project"

        let result = await harness.dispatcher.dispatch(
            .workspaceTabShow(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspaceTab(detail)) = result else {
            Issue.record("expected tab detail; got \(result)")
            return
        }
        // The harness names its tabs, so the tab lands on the name tier here.
        #expect(detail.tab.title == "tab-1")
        #expect(detail.panes.first?.terminal?.title == "project")
    }

    /// `--all` spans windows, in window then tab then layout order, and carries
    /// each pane's tab context so a caller needs no second listing to name the
    /// tab a pane sits in.
    @Test
    func paneListAllSpansWindowsWithTabContext() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 2),
            tabID: TabID(value: 2),
            sessionId: "S-B"
        )

        let scoped = await harness.dispatcher.dispatch(
            .workspacePaneList(tab: nil, all: false),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )
        let all = await harness.dispatcher.dispatch(
            .workspacePaneList(tab: nil, all: true),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspacePanes(scopedPanes)) = scoped,
            case let .data(.workspacePanes(allPanes)) = all
        else {
            Issue.record("expected workspace panes")
            return
        }
        #expect(scopedPanes.map(\.terminal?.sessionId) == ["S-A"])
        #expect(allPanes.map(\.terminal?.sessionId) == ["S-A", "S-B"])
        #expect(allPanes.map(\.tabTitle) == ["tab-1", "tab-2"])
        #expect(Set(allPanes.map(\.windowId)).count == 2)
        #expect(allPanes.allSatisfy { !$0.windowId.isEmpty && !$0.tabTitle.isEmpty })
    }

    /// `--all` widens the listing, never the visibility rule: a foreign
    /// protected tab's panes stay out of it.
    @Test
    func paneListAllOmitsForeignProtectedTabs() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 2),
            sessionId: "S-B"
        )
        guard let tabs = harness.workspace.window(id: WindowID(value: 1))?.tabs else {
            Issue.record("expected window tabs")
            return
        }
        tabs.setProtectionState(.protected, id: TabID(value: 2))

        let result = await harness.dispatcher.dispatch(
            .workspacePaneList(tab: nil, all: true),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspacePanes(panes)) = result else {
            Issue.record("expected workspace panes; got \(result)")
            return
        }
        #expect(panes.map(\.terminal?.sessionId) == ["S-A"])
    }

    /// The protected tab's own session still sees it under `--all`, so the
    /// filter is per-caller rather than a blanket exclusion.
    @Test
    func paneListAllKeepsTheCallersOwnProtectedTab() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        guard let tabs = harness.workspace.window(id: WindowID(value: 1))?.tabs else {
            Issue.record("expected window tabs")
            return
        }
        tabs.setProtectionState(.protected, id: TabID(value: 1))

        let result = await harness.dispatcher.dispatch(
            .workspacePaneList(tab: nil, all: true),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspacePanes(panes)) = result else {
            Issue.record("expected workspace panes; got \(result)")
            return
        }
        #expect(panes.map(\.terminal?.sessionId) == ["S-A"])
    }

    @Test
    func collectionProjectionsApplyOneWorkingDirectoryPolicy() async {
        let harness = makeHarness()
        let terminals = [
            TerminalPaneState(
                id: TerminalPaneID(value: 1),
                sessionId: "S-A",
                capability: "cap"
            ),
            TerminalPaneState(
                id: TerminalPaneID(value: 2),
                sessionId: "S-B",
                capability: "cap"
            )
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            terminals: terminals
        )
        harness.delegate.workingDirectories = [
            TerminalPaneID(value: 1): "/one",
            TerminalPaneID(value: 2): "/two"
        ]

        let list = await harness.dispatcher.dispatch(
            .workspacePaneList(tab: nil, all: false),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )
        let show = await harness.dispatcher.dispatch(
            .workspaceTabShow(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspacePanes(listPanes)) = list,
            case let .data(.workspaceTab(detail)) = show
        else {
            Issue.record("expected collection projections")
            return
        }
        if WorkspaceProjection.includesTerminalCWDInCollections {
            #expect(listPanes.compactMap(\.terminal?.cwd) == ["/one", "/two"])
            #expect(detail.panes.compactMap(\.terminal?.cwd) == ["/one", "/two"])
            #expect(harness.delegate.workingDirectoryReads.count == 4)
        } else {
            #expect(listPanes.compactMap(\.terminal?.cwd).isEmpty)
            #expect(detail.panes.compactMap(\.terminal?.cwd).isEmpty)
            #expect(harness.delegate.workingDirectoryReads.isEmpty)
        }
    }

    @Test
    func mutationReceiptsDoNotReadTerminalWorkingDirectories() async {
        let harness = makeHarness()
        let terminals = [
            TerminalPaneState(
                id: TerminalPaneID(value: 1),
                sessionId: "S-A",
                capability: "cap"
            ),
            TerminalPaneState(
                id: TerminalPaneID(value: 2),
                sessionId: "S-B",
                capability: "cap"
            )
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            terminals: terminals
        )
        harness.delegate.workingDirectories = [
            TerminalPaneID(value: 1): "/one",
            TerminalPaneID(value: 2): "/two"
        ]

        let renameResult = await harness.dispatcher.dispatch(
            .workspaceTabRename(nil, name: "renamed"),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspaceMutation(renameReceipt)) = renameResult else {
            Issue.record("expected tab mutation; got \(renameResult)")
            return
        }
        #expect(renameReceipt.tab?.name == "renamed")
        #expect(renameReceipt.pane == nil)
        #expect(harness.delegate.workingDirectoryReads.isEmpty)

        let focusResult = await harness.dispatcher.dispatch(
            .workspaceWindowFocus(nil),
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspaceMutation(focusReceipt)) = focusResult else {
            Issue.record("expected window focus mutation; got \(focusResult)")
            return
        }
        #expect(focusReceipt.pane?.terminal?.sessionId == "S-A")
        #expect(focusReceipt.pane?.terminal?.cwd == nil)
        #expect(harness.delegate.workingDirectoryReads.isEmpty)

        harness.fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S-open", capability: "C-open")
        ]
        let openResult = await harness.dispatcher.dispatch(
            .workspaceWindowOpen,
            origin: .external(sessionID: "S-A", hasAutomationGrant: true)
        )

        guard case let .data(.workspaceMutation(openReceipt)) = openResult else {
            Issue.record("expected window open mutation; got \(openResult)")
            return
        }
        #expect(openReceipt.pane?.terminal?.sessionId == "S-open")
        #expect(openReceipt.pane?.terminal?.cwd == nil)
        #expect(harness.delegate.workingDirectoryReads.isEmpty)
    }

    @Test
    func crossWindowMoveMapsTheVisibleIndexIntoTheRawDestinationTabs() async throws {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-caller"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 2),
            tabID: TabID(value: 2),
            sessionId: "S-hidden"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 2),
            tabID: TabID(value: 3),
            sessionId: "S-visible-a"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 2),
            tabID: TabID(value: 4),
            sessionId: "S-visible-b"
        )
        let destinationTabs = try #require(
            harness.workspace.window(id: WindowID(value: 2))?.tabs
        )
        destinationTabs.setProtectionState(.protected, id: TabID(value: 2))
        harness.delegate.moveImplementation = { tab, source, destination, index in
            guard let moved = harness.workspace.window(id: source)?.tabs.detach(id: tab) else {
                return
            }
            harness.workspace.window(id: destination)?.tabs.insert(moved, at: index)
        }

        let result = await harness.dispatcher.dispatch(
            .workspaceTabMove("tab-1", window: "window-2", index: 1),
            origin: .external(sessionID: "S-caller", hasAutomationGrant: true)
        )

        guard case let .data(.workspaceMutation(receipt)) = result else {
            Issue.record("expected committed tab move; got \(result)")
            return
        }
        #expect(harness.delegate.moves.first?.atIndex == 2)
        #expect(receipt.window?.name == "window-2")
        #expect(destinationTabs.tabs.map(\.id) == [
            TabID(value: 2),
            TabID(value: 3),
            TabID(value: 1),
            TabID(value: 4)
        ])
    }

    @Test
    func crossWindowMoveRefusesADelegateNoOp() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-caller"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 2),
            tabID: TabID(value: 2),
            sessionId: "S-other"
        )

        let result = await harness.dispatcher.dispatch(
            .workspaceTabMove("tab-1", window: "window-2", index: nil),
            origin: .external(sessionID: "S-caller", hasAutomationGrant: true)
        )

        #expect(
            result == .error(
                .internalError("tab move was not committed in the destination window")
            )
        )
        #expect(harness.workspace.windowContaining(tab: TabID(value: 1))?.id == WindowID(value: 1))
    }

    @Test
    func paneAttachDispatchesExistingSimulatorRoute() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        let upperUDID = "7DB632B6-86D3-437D-B567-36A80E59788B"

        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: upperUDID),
            origin: .inProcess
        )

        guard case .data(.workspaceMutation) = result else {
            Issue.record("expected committed workspace receipt; got \(result)")
            return
        }
        #expect(harness.fake.attachDeviceCalls.first?.sessionId == "S-A")
        #expect(harness.fake.attachDeviceCalls.first?.udid == upperUDID.lowercased())
    }

    @Test
    func paneAttachPreservesTheDaemonFailure() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        let udid = "7DB632B6-86D3-437D-B567-36A80E59788B"
        let message = "pane.create: No port conforms to SimDisplayIOSurfaceRenderable"
        harness.fake.attachError = DaemonClientError.daemon(
            code: -32_000,
            message: message
        )

        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: udid),
            origin: .inProcess
        )

        #expect(
            result == .error(
                .attachFailed(message: message, forwardedRPCCode: -32_000)
            )
        )
        #expect(harness.fake.attachDeviceCalls.count == 1)
        let pending = harness.workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.pendingPanes.first
        guard case .failed = pending?.phase else {
            Issue.record("expected the failed placeholder to remain visible")
            return
        }
    }

    @Test
    func paneAttachRetriesAnExistingFailedPlaceholder() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )
        let udid = "7DB632B6-86D3-437D-B567-36A80E59788B"
        harness.fake.attachFailure = { _, index in
            index == 0
                ? DaemonClientError.daemon(code: -32_000, message: "pane.create: failed")
                : nil
        }

        let first = await harness.dispatcher.dispatch(
            .paneAttach(udid: udid),
            origin: .inProcess
        )
        let second = await harness.dispatcher.dispatch(
            .paneAttach(udid: udid),
            origin: .inProcess
        )

        guard case .error(.attachFailed) = first else {
            Issue.record("expected the first attach to fail; got \(first)")
            return
        }
        guard case .data(.workspaceMutation) = second else {
            Issue.record("expected the explicit retry to commit; got \(second)")
            return
        }
        #expect(harness.fake.attachDeviceCalls.count == 2)
        let tab = harness.workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))
        #expect(tab?.pendingPanes.isEmpty == true)
        #expect(tab?.simPanes.count == 1)
    }

    @Test
    func devicePaneAttachDispatchesExistingDeviceRoute() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )

        let result = await harness.dispatcher.dispatch(
            .devicePaneAttach(deviceId: "fd00::1", relinkExisting: false),
            origin: .inProcess
        )

        guard case .data(.workspaceMutation) = result else {
            Issue.record("expected committed workspace receipt; got \(result)")
            return
        }
        #expect(harness.fake.attachPhysicalDeviceCalls.first?.deviceId == "fd00::1")
        #expect(harness.fake.attachPhysicalDeviceCalls.first?.sessionId == "S-A")
    }

    @Test
    func malformedSimulatorAttachStillFailsBeforeRPC() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
        )

        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: "not-a-uuid"),
            origin: .inProcess
        )

        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)")
            return
        }
        #expect(error.code == "intent.internalError")
        #expect(harness.fake.attachDeviceCalls.isEmpty)
    }
}

@MainActor
private final class RecordingActionDelegate: IntentActionDelegate {
    struct SendInput: Equatable {
        let window: WindowID
        let tab: TabID
        let terminal: TerminalPaneID
        let text: String
        let typeDelayMillis: Int?
    }

    struct Capture: Equatable {
        let window: WindowID
        let tab: TabID
        let terminal: TerminalPaneID
        let ansi: Bool
    }

    struct MoveAcross: Equatable {
        let tab: TabID
        let from: WindowID
        let destination: WindowID
        let atIndex: Int
    }

    struct PaneRename: Equatable {
        let window: WindowID
        let tab: TabID
        let slot: PaneSlot
        let daemonPaneId: String?
        let name: String?
    }

    struct WorkingDirectoryRead: Equatable {
        let window: WindowID
        let tab: TabID
        let terminal: TerminalPaneID
    }

    struct FactsRead: Equatable {
        let window: WindowID
        let tab: TabID
        let terminal: TerminalPaneID
        let includeWorkingDirectory: Bool
    }

    private(set) var sendInputs: [SendInput] = []
    private(set) var captures: [Capture] = []
    private(set) var moves: [MoveAcross] = []
    private(set) var raises: [WindowID] = []
    private(set) var paneRenames: [PaneRename] = []
    /// Every facts hop, whether or not it asked for the working directory.
    private(set) var factsReads: [FactsRead] = []
    /// The hops that actually requested a working directory. The projection
    /// now reads a terminal's label and tty unconditionally, so "did not read
    /// the directory" is a property of the request rather than of the call
    /// happening at all.
    var workingDirectoryReads: [WorkingDirectoryRead] {
        factsReads.filter(\.includeWorkingDirectory).map {
            WorkingDirectoryRead(window: $0.window, tab: $0.tab, terminal: $0.terminal)
        }
    }

    var workingDirectories: [TerminalPaneID: String] = [:]
    var oscTitles: [TerminalPaneID: String] = [:]
    var oscWorkingDirectories: [TerminalPaneID: String] = [:]
    var ttys: [TerminalPaneID: String] = [:]
    /// Stands in for `TabTitleViewModel.displayTitle`, which the tab projection
    /// reads before normalizing. Set it alongside `oscTitles` to model a tab and
    /// its lone terminal seeing the same OSC title.
    var tabDisplayTitles: [TabID: String] = [:]
    var sendInputError: IntentError?
    var captureResult = ""
    var captureError: IntentError?
    var moveImplementation: ((TabID, WindowID, WindowID, Int) -> Void)?

    func renameTab(window: WindowID, tab: TabID, to name: String?) {}

    func renamePane(
        window: WindowID,
        tab: TabID,
        slot: PaneSlot,
        daemonPaneId: String?,
        to name: String?
    ) {
        paneRenames.append(
            PaneRename(
                window: window,
                tab: tab,
                slot: slot,
                daemonPaneId: daemonPaneId,
                name: name
            )
        )
    }

    func sendInput(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        text: String,
        typeDelayMillis: Int?
    ) throws {
        if let error = sendInputError {
            sendInputError = nil
            throw error
        }
        sendInputs.append(
            SendInput(
                window: window,
                tab: tab,
                terminal: terminal,
                text: text,
                typeDelayMillis: typeDelayMillis
            )
        )
    }

    func captureTerminal(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        ansi: Bool
    ) throws -> String {
        if let error = captureError {
            captureError = nil
            throw error
        }
        captures.append(
            Capture(window: window, tab: tab, terminal: terminal, ansi: ansi)
        )
        return captureResult
    }

    func tabDisplayTitle(window: WindowID, tab: TabID) -> String? {
        tabDisplayTitles[tab]
    }

    func terminalFacts(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        includeWorkingDirectory: Bool
    ) -> TerminalPaneFacts? {
        factsReads.append(
            .init(
                window: window,
                tab: tab,
                terminal: terminal,
                includeWorkingDirectory: includeWorkingDirectory
            )
        )
        return TerminalPaneFacts(
            oscTitle: oscTitles[terminal],
            oscWorkingDirectory: oscWorkingDirectories[terminal],
            tty: ttys[terminal],
            cwd: includeWorkingDirectory ? workingDirectories[terminal] : nil
        )
    }

    func moveTabAcrossWindows(
        _ tab: TabID,
        from: WindowID,
        to destination: WindowID,
        atIndex: Int
    ) {
        moves.append(.init(tab: tab, from: from, destination: destination, atIndex: atIndex))
        moveImplementation?(tab, from, destination, atIndex)
    }

    func raiseWindow(_ window: WindowID) {
        raises.append(window)
    }
}
