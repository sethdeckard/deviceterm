// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// The bridge from RouteIntent to either a
/// Router dispatch, an actionDelegate call, or a workspace-read
/// payload.
///
/// Mutating intents fire the matching Route on the Router (asserted
/// via FakeDaemonClient's recorded calls). Read-only intents
/// (`tabInfo`, `paneInfo`, `windowsList`) return `.data` carrying the
/// wire payload. Resolver errors land as `.error`.
@MainActor
struct IntentDispatcherTests {
    // MARK: - Helpers

    /// Bundle of test-time references the harness builds so each
    /// test can poke at the recording fake, the workspace, etc.
    private struct Harness {
        let dispatcher: IntentDispatcher
        let workspace: WorkspaceViewModel
        let router: Router
        let fake: FakeDaemonClient
        let actionDelegate: RecordingActionDelegate
    }

    private func makeHarness() -> Harness {
        let workspace = WorkspaceViewModel()
        let fake = FakeDaemonClient()
        let router = Router(workspace: workspace, daemon: fake)
        let actionDelegate = RecordingActionDelegate()
        let dispatcher = IntentDispatcher(
            workspace: workspace,
            router: router,
            actionDelegate: actionDelegate
        )
        return Harness(
            dispatcher: dispatcher,
            workspace: workspace,
            router: router,
            fake: fake,
            actionDelegate: actionDelegate
        )
    }

    /// Let the Router's serial drain process queued routes.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func appendTab(
        _ workspace: WorkspaceViewModel,
        windowID: WindowID,
        tabID: TabID,
        sessionId: String,
        panes: [SimPaneState] = []
    ) {
        let list: TabListViewModel
        if let existing = workspace.window(id: windowID) {
            list = existing.tabs
        } else {
            list = TabListViewModel()
            workspace.addWindow(WindowState(id: windowID, tabs: list))
        }
        let primary = TerminalPaneState(
            id: TerminalPaneID(value: tabID.value),
            sessionId: sessionId,
            capability: "cap"
        )
        list.append(
            TabState(
            id: tabID,
            terminals: [primary],
            simPanes: panes
        )
            )
    }

    // MARK: - Mutating intents

    @Test
    func moveTabSameWindowDispatchesReorderRoute() async {
        let harness = makeHarness()
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 1), sessionId: "S-A")
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 2), sessionId: "S-B")
        let result = await harness.dispatcher.dispatch(
            .moveTab(.sessionId("S-A"), toIndex: 1, toWindow: nil), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        #expect(
            harness.workspace.window(id: WindowID(value: 1))?.tabs.tabs.map(\.id)
                == [TabID(value: 2), TabID(value: 1)]
        )
        // Same-window reorder goes through the Router, not the delegate.
        #expect(harness.actionDelegate.moves.isEmpty)
    }

    @Test
    func moveTabToAnotherWindowHitsActionDelegate() async {
        let harness = makeHarness()
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 1), sessionId: "S-A")
        appendTab(harness.workspace, windowID: WindowID(value: 2), tabID: TabID(value: 2), sessionId: "S-B")
        let result = await harness.dispatcher.dispatch(
            .moveTab(.sessionId("S-A"), toIndex: nil, toWindow: .index(2)), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        // toIndex nil → append at the destination's end (1 existing tab).
        #expect(
            harness.actionDelegate.moves == [
                .init(
                    tab: TabID(value: 1),
                    from: WindowID(value: 1),
                    destination: WindowID(value: 2),
                    atIndex: 1
                )
            ]
        )
    }

    @Test
    func moveTabToSameWindowWithoutIndexIsRejected() async {
        // `--to-window` that resolves to the tab's own window is a
        // same-window reorder, which requires an explicit `--to`. Without
        // it the intent must error, not slide the tab to the last slot.
        let harness = makeHarness()
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 1), sessionId: "S-A")
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 2), sessionId: "S-B")
        let result = await harness.dispatcher.dispatch(
            .moveTab(.sessionId("S-A"), toIndex: nil, toWindow: .index(1)), origin: .inProcess
        )
        await settle()
        if case .error = result {
            // expected
        } else {
            Issue.record("expected .error; got \(result)")
        }
        #expect(harness.actionDelegate.moves.isEmpty)
        #expect(
            harness.workspace.window(id: WindowID(value: 1))?.tabs.tabs.map(\.id)
                == [TabID(value: 1), TabID(value: 2)]
        )
    }

    @Test
    func openWindowDispatchesOpenWindowRoute() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(.openWindow, origin: .inProcess)
        await settle()
        #expect(result == .ok)
        #expect(harness.workspace.windows.count == 1)
    }

    @Test
    func closeTabDispatchesCloseTabRoute() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-A"), mode: .shutdown), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.fake.closeSessionCalls.first?.mode == .shutdown)
    }

    @Test
    func renameTabRoutesThroughActionDelegate() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .renameTab(.sessionId("S-A"), name: "feature"), origin: .inProcess
        )
        #expect(result == .ok)
        #expect(
            harness.actionDelegate.renames == [
            RecordingActionDelegate.Rename(
                window: WindowID(value: 1),
                tab: TabID(value: 1),
                name: "feature"
            )
            ]
            )
    }

    @Test
    func selectTabFiresSelectTabRoute() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .selectTab(.sessionId("S-A")), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
    }

    @Test
    func selectTabDoesNotRaiseItsWindow() async {
        // The deliberate split between the two selection verbs: `tab
        // select` moves the selection inside its window and leaves
        // window order alone, so a granted caller can stage a
        // background window's tab without taking the human's
        // attention. `window focus` is the verb that raises.
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
        let result = await harness.dispatcher.dispatch(
            .selectTab(.sessionId("S-A")), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.actionDelegate.raises.isEmpty)
        #expect(harness.workspace.selectedWindowID == WindowID(value: 2))
    }

    @Test
    func focusWindowRaisesTheResolvedWindow() async {
        // The raise is the whole verb: the dispatcher writes no
        // selection of its own. The recording delegate raises nothing,
        // so no `windowDidBecomeKey` follows it and the workspace stays
        // on window 2 where `appendTab` left it. What that pins is the
        // absence of a second write here, not what the real AppKit
        // mirror does with the raise.
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
        let result = await harness.dispatcher.dispatch(
            .focusWindow(.index(1)), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.actionDelegate.raises == [WindowID(value: 1)])
        #expect(harness.workspace.selectedWindowID == WindowID(value: 2))
    }

    @Test
    func focusWindowRaisesNothingWhenTheRefDoesNotResolve() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .focusWindow(.index(9)), origin: .inProcess
        )
        await settle()
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.notFound")
        #expect(harness.actionDelegate.raises.isEmpty)
    }

    @Test
    func focusWindowRaisesTheExternalCallersOwnWindow() async {
        // `.current` for an external caller is its own window, never
        // the human's key one, so the raise follows the session rather
        // than whatever is frontmost.
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
        let result = await harness.dispatcher.dispatch(
            .focusWindow(.current), origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.actionDelegate.raises == [WindowID(value: 1)])
    }

    @Test
    func openPaneTerminalAddsTerminalToNamedTab() async {
        // The Intent layer's openPaneTerminal verb now dispatches the
        // real Route.openTerminalPane (replacing the prior newTab
        // fallback). The Router mints a fresh session and appends a
        // TerminalPaneState, so the tab gains a second terminal.
        let harness = makeHarness()
        harness.fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S-A", capability: "C-A"),
            SessionCreateResponse(sessionId: "S-A2", capability: "C-A2")
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .openPaneTerminal(
                inTab: .sessionId("S-A"),
                cwd: nil,
                cmd: nil
            ), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        let tab = harness.workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))
        #expect(tab?.terminals.count == 2)
        // session.create fired once for the new terminal; the appended
        // primary's session was pre-seeded by the test fixture.
        #expect(harness.fake.createSessionCalls.count == 1)
    }

    @Test
    func openPaneTerminalCurrentTargetsCallerTab() async {
        // With no `--tab` ref and a current session, the Intent
        // resolves to the caller's tab and adds a terminal there.
        let harness = makeHarness()
        harness.fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S-new", capability: "C-new")
        ]
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-caller"
            )
        let result = await harness.dispatcher.dispatch(
            .openPaneTerminal(inTab: nil, cwd: nil, cmd: nil),
            origin: .external(sessionID: "S-caller", hasAutomationGrant: false)
        )
        await settle()
        #expect(result == .ok)
        #expect(
            harness.workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.terminals.count == 2
            )
    }

    @Test
    func openTabThreadsCwdAndCmdToPrimaryTerminal() async {
        // --cwd / --cmd flow Route.newTab → Router.addTab →
        // TerminalPaneState so the GUI's libghostty attach can
        // honor them. Pin both ends: the dispatched .openTab
        // carries them and the resulting primary terminal records
        // them on its state.
        //
        // Seed the workspace with an existing window first, since `.openTab(
        // inWindow: nil)` resolves to "current key window"; the
        // headless test fixture has none until appendTab fills one.
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
            .openTab(
                inWindow: nil,
                role: .agent,
                cwd: "/proj",
                cmd: ["claude --print"]
            ), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        let tabs = harness.workspace.window(id: WindowID(value: 1))?
            .tabs.tabs ?? []
        #expect(tabs.count == 2)
        // The newly-minted tab is the second one; its primary
        // terminal carries the threaded cwd/cmd.
        let primary = tabs.last?.terminals.first
        #expect(primary?.sessionId == "S-new")
        #expect(primary?.cwd == "/proj")
        #expect(primary?.command == ["claude --print"])
    }

    @Test
    func openPaneTerminalThreadsCwdAndCmdToNewTerminal() async {
        // Same plumbing as openTab but on the
        // `openPaneTerminal(inTab:cwd:cmd:)` path. The added
        // terminal must carry the requested cwd/cmd.
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
            .openPaneTerminal(
                inTab: .sessionId("S-seed"),
                cwd: "/work",
                cmd: ["python3", "manage.py", "runserver"]
            ), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        let added = harness.workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?
            .terminals.last
        #expect(added?.sessionId == "S-new")
        #expect(added?.cwd == "/work")
        #expect(added?.command == ["python3", "manage.py", "runserver"])
    }

    @Test
    func closePaneDispatchesDetachSimPane() async {
        let harness = makeHarness()
        let pane = SimPaneState(
            paneId: "P1",
            udid: "U-iphone17",
            displayName: "iPhone",
            family: "iPhone"
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            panes: [pane]
            )
        let result = await harness.dispatcher.dispatch(
            .closePane(.udid("U-iphone17"), mode: .detach), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
    }

    // MARK: - Read-only intents

    @Test
    func tabInfoReturnsPayloadForResolvedTab() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .tabInfo(.sessionId("S-A")), origin: .inProcess
        )
        guard case .data(.tabInfo(let payload)) = result else {
            Issue.record("expected .data(.tabInfo); got \(result)"); return
        }
        #expect(payload.sessionId == "S-A")
        #expect(payload.role == "agent")
    }

    @Test
    func tabInfoMarksCallerOwnTabAsCurrent() async {
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
        let ownResult = await harness.dispatcher.dispatch(
            .tabInfo(.sessionId("S-A")),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        guard case .data(.tabInfo(let own)) = ownResult else {
            Issue.record("expected own tabInfo"); return
        }
        #expect(own.isCurrent)
        let otherResult = await harness.dispatcher.dispatch(
            .tabInfo(.sessionId("S-B")),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        guard case .data(.tabInfo(let other)) = otherResult else {
            Issue.record("expected other tabInfo"); return
        }
        #expect(other.isCurrent == false)
    }

    @Test
    func windowsListDefaultScopesToCallerWindow() async {
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
        let result = await harness.dispatcher.dispatch(
            .windowsList(all: false),
            origin: .external(sessionID: "S-B", hasAutomationGrant: false)
        )
        guard case .data(.windowsList(let payload)) = result else {
            Issue.record("expected .data(.windowsList); got \(result)"); return
        }
        #expect(payload.count == 1)
        #expect(payload[0].index == 2)
    }

    @Test
    func windowsListAllEnumeratesEveryWindowInOrder() async {
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
        let result = await harness.dispatcher.dispatch(
            .windowsList(all: true),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        guard case .data(.windowsList(let payload)) = result else {
            Issue.record("expected .data(.windowsList); got \(result)"); return
        }
        #expect(payload.count == 2)
        #expect(payload[0].index == 1)
        #expect(payload[1].index == 2)
    }

    @Test
    func windowsListWithoutCallerSessionReturnsEmpty() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(.windowsList(all: false), origin: .inProcess)
        guard case .data(.windowsList(let payload)) = result else {
            Issue.record("expected .data(.windowsList); got \(result)"); return
        }
        #expect(payload.isEmpty)
    }

    // MARK: - Errors

    @Test
    func unresolvedTabRefReturnsError() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-MISSING"), mode: .detach), origin: .inProcess
        )
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.notFound")
    }

    @Test
    func paneAttachDispatchesAttachSimPaneRouteForCurrentTab() async {
        // Resolves caller's current tab and dispatches the existing
        // `Route.attachSimPane` pipeline, the same one that
        // discovery / orphan-recovery / shim-intercept boot all flow
        // through. Verified by observing the Router's downstream
        // `daemon.attachDevice` call: the fake records the
        // `(sessionId, capability, udid)` triple, and the assertion
        // pins that the current tab's session creds were forwarded
        // and that the dispatcher canonicalized the UDID to its
        // lowercased form on the way down.
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        // appendTab → addWindow sets selectedWindowID; append sets
        // the tab's selectedIndex, so the resolver's `.current` path
        // is satisfied without further setup.
        let upperUDID = "7DB632B6-86D3-437D-B567-36A80E59788B"
        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: upperUDID), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.fake.attachDeviceCalls.count == 1)
        #expect(harness.fake.attachDeviceCalls.first?.sessionId == "S-A")
        #expect(
            harness.fake.attachDeviceCalls.first?.udid
                == upperUDID.lowercased()
            )
    }

    @Test
    func devicePaneAttachDispatchesAttachDevicePaneRouteForCurrentTab() async {
        // The `.device` arm of `device attach <ref>`: resolves the
        // caller's current tab and dispatches `Route.attachDevicePane`,
        // observed via the Router's downstream
        // `daemon.attachPhysicalDevice(deviceId:sessionId:)` call.
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .devicePaneAttach(deviceId: "fd00::1", relinkExisting: false), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.fake.attachPhysicalDeviceCalls.count == 1)
        #expect(harness.fake.attachPhysicalDeviceCalls.first?.deviceId == "fd00::1")
        #expect(harness.fake.attachPhysicalDeviceCalls.first?.sessionId == "S-A")
    }

    @Test
    func devicePaneAttachRelinkMovesMirrorAcrossTabs() async {
        // The shim's contextual trigger (`relinkExisting: true`): a device
        // already mirrored in tab A moves to the calling tab B: detach A,
        // attach B, on the serial router drain (detach first).
        let harness = makeHarness()
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 1), sessionId: "S-A")
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 2), sessionId: "S-B")
        _ = await harness.dispatcher.dispatch(
            .devicePaneAttach(deviceId: "fd00::1", relinkExisting: false),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        await settle()
        #expect(harness.fake.attachPhysicalDeviceCalls.count == 1)

        let result = await harness.dispatcher.dispatch(
            .devicePaneAttach(deviceId: "fd00::1", relinkExisting: true),
            origin: .external(sessionID: "S-B", hasAutomationGrant: false)
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.fake.closePaneCalls.contains { $0.mode == .detach })
        #expect(harness.fake.attachPhysicalDeviceCalls.count == 2)
        #expect(harness.fake.attachPhysicalDeviceCalls.last?.sessionId == "S-B")
        let tabA = harness.workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1))
        let tabB = harness.workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 2))
        #expect(tabA?.devicePanes.contains { $0.deviceId == "fd00::1" } == false)
        #expect(tabB?.devicePanes.contains { $0.deviceId == "fd00::1" } == true)
    }

    @Test
    func devicePaneAttachWithoutRelinkRejectsCrossTab() async {
        // The explicit CLI verb (`relinkExisting: false`): a device
        // mirrored in tab A is NOT stolen by an attach from tab B. Hard
        // reject: no second daemon attach, A keeps the mirror, no detach.
        let harness = makeHarness()
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 1), sessionId: "S-A")
        appendTab(harness.workspace, windowID: WindowID(value: 1), tabID: TabID(value: 2), sessionId: "S-B")
        _ = await harness.dispatcher.dispatch(
            .devicePaneAttach(deviceId: "fd00::1", relinkExisting: false),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        await settle()
        #expect(harness.fake.attachPhysicalDeviceCalls.count == 1)

        let result = await harness.dispatcher.dispatch(
            .devicePaneAttach(deviceId: "fd00::1", relinkExisting: false),
            origin: .external(sessionID: "S-B", hasAutomationGrant: false)
        )
        await settle()
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.internalError")
        #expect(harness.fake.attachPhysicalDeviceCalls.count == 1)
        #expect(harness.fake.closePaneCalls.isEmpty)
        let tabA = harness.workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1))
        #expect(tabA?.devicePanes.contains { $0.deviceId == "fd00::1" } == true)
    }

    @Test
    func paneAttachIsIdempotentWhenUDIDAlreadyInCurrentTab() async {
        // Same-tab repeat is a no-op (no second daemon.attachDevice
        // call), matching the agent workflow of "boot a sim, run
        // `deviceterm device attach` once, then run it again to verify
        // and not have it create a duplicate pane".
        let harness = makeHarness()
        let udid = "7db632b6-86d3-437d-b567-36a80e59788b"
        let existing = SimPaneState(
            paneId: "P-1",
            udid: udid,
            displayName: "Sim 7db632b6",
            family: "phone",
            shortId: "p1",
            name: nil
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            panes: [existing]
            )
        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: udid), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.fake.attachDeviceCalls.isEmpty)
    }

    @Test
    func paneAttachRejectsUDIDAlreadyAttachedToDifferentTab() async {
        // Cross-tab attempt: refuses to steal the pane (which would
        // duplicate the daemon record and break the original
        // stream). Surfaces an internalError with a hint pointing
        // at the GUI-drag re-link path.
        let harness = makeHarness()
        let udid = "7db632b6-86d3-437d-b567-36a80e59788b"
        let existing = SimPaneState(
            paneId: "P-1",
            udid: udid,
            displayName: "Sim 7db632b6",
            family: "phone",
            shortId: "p1",
            name: nil
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            panes: [existing]
            )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 2),
            sessionId: "S-B"
            )
        // Make tab 2 (the empty one) the current target.
        harness.workspace.window(id: WindowID(value: 1))?
            .tabs.select(id: TabID(value: 2))
        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: udid), origin: .inProcess
        )
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.internalError")
        #expect(harness.fake.attachDeviceCalls.isEmpty)
    }

    @Test
    func paneAttachCanonicalizesUDIDCaseAcrossDuplicateChecks() async {
        // UDIDs are case-insensitive, so the existing pane may have been
        // stored as uppercase (discovery / orphan recovery paths
        // preserve simctl's `list` output) and a re-attach call from
        // an agent that lowercased the value (or vice versa) must
        // still hit the same-tab idempotency guard, not stack a
        // duplicate via a second daemon.attachDevice round-trip.
        let harness = makeHarness()
        let upperUDID = "7DB632B6-86D3-437D-B567-36A80E59788B"
        let lowerUDID = upperUDID.lowercased()
        let existing = SimPaneState(
            paneId: "P-1",
            udid: upperUDID,
            displayName: "Sim 7DB632B6",
            family: "phone",
            shortId: "p1",
            name: nil
        )
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A",
            panes: [existing]
            )
        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: lowerUDID), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
        #expect(harness.fake.attachDeviceCalls.isEmpty)
    }

    @Test
    func paneAttachRejectsMalformedUDID() async {
        // Fail fast in the dispatcher rather than relying on the
        // daemon's terser `malformed UDID` after a round-trip, so the
        // CLI's user sees an actionable hint instead of a bridge
        // error code.
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: "not-a-uuid"), origin: .inProcess
        )
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.internalError")
        #expect(harness.fake.attachDeviceCalls.isEmpty)
    }

    @Test
    func paneAttachWithoutCurrentTabReturnsNotFound() async {
        // No current session, no key window with a selected tab →
        // resolver can't pin "current," so the intent surfaces
        // notFound rather than silently no-oping. CLI prints the
        // resolver's hint so the caller knows to open a tab first.
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: "7DB632B6-86D3-437D-B567-36A80E59788B"), origin: .inProcess
        )
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.notFound")
        #expect(harness.fake.attachDeviceCalls.isEmpty)
    }

    @Test
    func sendInputForwardsToActionDelegate() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .sendInput(.sessionId("S-A"), text: "ping\n", typeDelayMillis: nil), origin: .inProcess
        )
        #expect(result == .ok)
        #expect(
            harness.actionDelegate.sendInputs == [
            RecordingActionDelegate.SendInput(
                window: WindowID(value: 1),
                tab: TabID(value: 1),
                text: "ping\n",
                typeDelayMillis: nil
            )
            ]
            )
    }

    @Test
    func sendInputThreadsTypeDelayToActionDelegate() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        let result = await harness.dispatcher.dispatch(
            .sendInput(.sessionId("S-A"), text: "ls\n", typeDelayMillis: 45), origin: .inProcess
        )
        #expect(result == .ok)
        #expect(
            harness.actionDelegate.sendInputs == [
            RecordingActionDelegate.SendInput(
                window: WindowID(value: 1),
                tab: TabID(value: 1),
                text: "ls\n",
                typeDelayMillis: 45
            )
            ]
            )
    }

    @Test
    func sendInputRelaysDelegateError() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        harness.actionDelegate.sendInputError = IntentError.notFound(
            kind: "tab",
            ref: "1"
        )
        let result = await harness.dispatcher.dispatch(
            .sendInput(.sessionId("S-A"), text: "ping", typeDelayMillis: nil), origin: .inProcess
        )
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.notFound")
    }

    @Test
    func sendInputUnresolvedTabReturnsNotFound() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .sendInput(.sessionId("S-MISSING"), text: "ping", typeDelayMillis: nil), origin: .inProcess
        )
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.notFound")
    }

    @Test
    func captureTabReturnsPayloadFromActionDelegate() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        harness.actionDelegate.captureResult = "first line\nsecond line\n"
        let result = await harness.dispatcher.dispatch(
            .captureTab(.sessionId("S-A")), origin: .inProcess
        )
        guard case .data(.tabCapture(let payload)) = result else {
            Issue.record("expected .data(.tabCapture); got \(result)"); return
        }
        #expect(payload.text == "first line\nsecond line\n")
        #expect(
            harness.actionDelegate.captures == [
            RecordingActionDelegate.Capture(
                window: WindowID(value: 1),
                tab: TabID(value: 1)
            )
            ]
            )
    }

    @Test
    func captureTabRelaysDelegateError() async {
        let harness = makeHarness()
        appendTab(
            harness.workspace,
            windowID: WindowID(value: 1),
            tabID: TabID(value: 1),
            sessionId: "S-A"
            )
        harness.actionDelegate.captureError = IntentError.notFound(
            kind: "tab",
            ref: "1"
        )
        let result = await harness.dispatcher.dispatch(
            .captureTab(.sessionId("S-A")), origin: .inProcess
        )
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.notFound")
    }

    @Test
    func captureTabUnresolvedRefReturnsNotFound() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .captureTab(.sessionId("S-MISSING")), origin: .inProcess
        )
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        #expect(error.code == "intent.notFound")
    }
}

// MARK: - Helpers

@MainActor
private final class RecordingActionDelegate: IntentActionDelegate {
    struct Rename: Equatable {
        let window: WindowID
        let tab: TabID
        let name: String?
    }
    struct SendInput: Equatable {
        let window: WindowID
        let tab: TabID
        let text: String
        let typeDelayMillis: Int?
    }
    struct Capture: Equatable {
        let window: WindowID
        let tab: TabID
    }
    struct MoveAcross: Equatable {
        let tab: TabID
        let from: WindowID
        let destination: WindowID
        let atIndex: Int
    }
    private(set) var renames: [Rename] = []
    private(set) var sendInputs: [SendInput] = []
    private(set) var captures: [Capture] = []
    private(set) var moves: [MoveAcross] = []
    private(set) var raises: [WindowID] = []
    /// When set, the next `sendInput` call throws this error instead
    /// of recording. Lets tests pin the dispatcher's error-relay
    /// path.
    var sendInputError: IntentError?
    /// Text the next `captureTab` call returns (when no error is
    /// scripted). Defaults to empty.
    var captureResult: String = ""
    /// When set, the next `captureTab` call throws this error.
    var captureError: IntentError?

    func renameTab(window: WindowID, tab: TabID, to name: String?) {
        renames.append(Rename(window: window, tab: tab, name: name))
    }

    func sendInput(
        window: WindowID,
        tab: TabID,
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
                text: text,
                typeDelayMillis: typeDelayMillis
            )
        )
    }

    func captureTab(window: WindowID, tab: TabID) throws -> String {
        if let error = captureError {
            captureError = nil
            throw error
        }
        captures.append(Capture(window: window, tab: tab))
        return captureResult
    }

    func moveTabAcrossWindows(_ tab: TabID, from: WindowID, to destination: WindowID, atIndex: Int) {
        moves.append(MoveAcross(tab: tab, from: from, destination: destination, atIndex: atIndex))
    }

    func raiseWindow(_ window: WindowID) {
        raises.append(window)
    }
}
