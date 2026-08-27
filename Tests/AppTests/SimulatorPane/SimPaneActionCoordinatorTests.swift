// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

private enum FakeBootError: Error { case refused }
private let bootUDID = "11111111-1111-1111-1111-111111111111"

/// The sim pane's boot legs and the owned-sim mirror.
///
/// Reboot, live reboot, and post-erase boot all send `device.boot` with the
/// tab's credentials plus a pending claim. All three boot from
/// a shut-down sim (live reboot and erase issue the shutdown themselves;
/// ordinary Reboot starts from the shutdown overlay), so a poll has already
/// cleared the mirror's claim before the new claim promotes. The GUI retains
/// that claim across an unanswered RPC or daemon replacement.
@MainActor
struct SimPaneActionCoordinatorTests {
    private func makeCoordinator(
        _ fake: FakeDaemonClient
    ) -> (SimPaneActionCoordinator, Router) {
        let router = Router(workspace: WorkspaceViewModel(), daemon: fake)
        let coordinator = SimPaneActionCoordinator(
            tabID: TabID(value: 1),
            router: router,
            daemonClient: fake,
            paneResurrect: PaneResurrect(daemonClient: fake),
            tabListVM: TabListViewModel(),
            windowID: WindowID(value: 1)
        )
        return (coordinator, router)
    }

    /// What the mirror hands a replacement helper, read through the path that
    /// actually sends it rather than a test-only accessor.
    private func restoredClaims(
        _ router: Router,
        _ fake: FakeDaemonClient
    ) async -> [String] {
        router.noteConnectionReplaced(generation: 99)
        router.dispatch(.recoverPanes)
        try? await Task.sleep(nanoseconds: 50_000_000)
        return fake.restoreOwnershipCalls.first?.map(\.udid) ?? []
    }

    /// A router with one window, one tab, and a mounted sim pane for `udid`,
    /// plus a coordinator bound to that tab. `asked` records every prompt the
    /// close path raises, so a test can assert it did NOT raise one.
    private func makeMountedPane(
        _ fake: FakeDaemonClient,
        udid: String,
        answer: TabCloseDecision,
        asked: @escaping @MainActor (String, Bool) -> Void
    ) async -> SimPaneActionCoordinator {
        let workspace = WorkspaceViewModel()
        let router = Router(workspace: workspace, daemon: fake)
        router.dispatch(.openWindow())
        try? await Task.sleep(nanoseconds: 50_000_000)
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: udid, displayName: "iPhone"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        return SimPaneActionCoordinator(
            tabID: tabID,
            router: router,
            daemonClient: fake,
            paneResurrect: PaneResurrect(daemonClient: fake),
            tabListVM: workspace.window(id: WindowID(value: 1))?.tabs ?? TabListViewModel(),
            windowID: WindowID(value: 1),
            askPaneClose: { _, deviceName, alwaysAsk, _, _ in
                asked(deviceName, alwaysAsk)
                return answer
            }
        )
    }

    private func booted(_ udid: String, session: String?) -> DeviceListEntry {
        DeviceListEntry(
            udid: udid,
            name: "iPhone 17 Pro",
            state: "Booted",
            ownedBySession: session
        )
    }

    @Test
    func closingAPaneForABorrowedSimNeverAsks() async {
        // Absent from the `.owned` roster: someone else booted it and
        // deviceterm never claimed it. Asking would offer a shutdown the app
        // has no business performing, so the pane closes.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.deviceListResult = []
        var prompts: [String] = []
        let coordinator = await makeMountedPane(
            fake,
            udid: "U",
            answer: .shutdown,
            asked: { name, _ in prompts.append(name) }
        )

        await coordinator.requestClosePane(udid: "U", displayName: "iPhone")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(prompts.isEmpty)
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .detach)])
    }

    @Test
    func aSimWhoseBooterTerminalIsGoneStillAsks() async {
        // Closing the terminal that booted a sim leaves the pane mounted and
        // the sim owned and Booted, attributed to a session the tab no longer
        // lists. That is the case most likely to strand a running sim, so it
        // has to raise the prompt rather than skip it.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.deviceListResult = [booted("U", session: "a-closed-session")]
        var prompts: [String] = []
        let coordinator = await makeMountedPane(
            fake,
            udid: "U",
            answer: .shutdown,
            asked: { name, _ in prompts.append(name) }
        )

        await coordinator.requestClosePane(udid: "U", displayName: "iPhone")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(prompts == ["iPhone"])
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .shutdown)])
    }

    @Test
    func aPaneThatDisappearsMidRequestIsNotAskedAbout() async {
        // The roster read suspends. If the pane goes in that window (tab
        // closed, resurrect swapped it), the resumed request must not put up
        // a modal about a pane the user can no longer see, nor close its
        // replacement.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.deviceListResult = [booted("U", session: "S")]
        var prompts: [String] = []
        let workspace = WorkspaceViewModel()
        let router = Router(workspace: workspace, daemon: fake)
        router.dispatch(.openWindow())
        try? await Task.sleep(nanoseconds: 50_000_000)
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let coordinator = SimPaneActionCoordinator(
            tabID: tabID,
            router: router,
            daemonClient: fake,
            paneResurrect: PaneResurrect(daemonClient: fake),
            tabListVM: workspace.window(id: WindowID(value: 1))?.tabs ?? TabListViewModel(),
            windowID: WindowID(value: 1),
            askPaneClose: { _, deviceName, _, _, _ in
                prompts.append(deviceName)
                return .shutdown
            }
        )

        fake.armDeviceListBarrier()
        let close = Task { await coordinator.requestClosePane(udid: "U", displayName: "iPhone") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        // The pane goes while the roster read is still outstanding.
        workspace.window(id: WindowID(value: 1))?.tabs
            .removeSimPane(udid: "U", fromTab: tabID)
        fake.releaseDeviceList()
        await close.value
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(prompts.isEmpty)
        #expect(fake.closePaneCalls.isEmpty)
    }

    @Test
    func anUnreachableDaemonAsksInsteadOfHonoringAStoredShutdown() async {
        // The roster read failed, so nothing verified the sim is even
        // running. A stored `shutdown` must not be applied to that unknown:
        // the close path asks, with suppression bypassed.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.deviceListError = FakeBootError.refused
        var alwaysAskFlags: [Bool] = []
        let coordinator = await makeMountedPane(
            fake,
            udid: "U",
            answer: .detach,
            asked: { _, alwaysAsk in alwaysAskFlags.append(alwaysAsk) }
        )

        await coordinator.requestClosePane(udid: "U", displayName: "iPhone")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(alwaysAskFlags == [true])
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .detach)])
    }

    @Test
    func aSimAnotherTabIsUsingIsClosedWithoutOfferingShutdown() async {
        // Tab 2 exists with its own session, and the sim is attributed to
        // it: tab 1's pane for the same udid is the stale one. Offering to
        // stop it would kill the simulator tab 2 is working in.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C"),
            SessionCreateResponse(sessionId: "S2", capability: "C")
        ]
        fake.deviceListResult = [booted("U", session: "S2")]
        var prompts: [String] = []
        let workspace = WorkspaceViewModel()
        let router = Router(workspace: workspace, daemon: fake)
        router.dispatch(.openWindow())
        try? await Task.sleep(nanoseconds: 50_000_000)
        router.dispatch(.newTab(WindowID(value: 1)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let coordinator = SimPaneActionCoordinator(
            tabID: tabID,
            router: router,
            daemonClient: fake,
            paneResurrect: PaneResurrect(daemonClient: fake),
            tabListVM: workspace.window(id: WindowID(value: 1))?.tabs ?? TabListViewModel(),
            windowID: WindowID(value: 1),
            askPaneClose: { _, deviceName, _, _, _ in
                prompts.append(deviceName)
                return .shutdown
            }
        )

        await coordinator.requestClosePane(udid: "U", displayName: "iPhone")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(prompts.isEmpty)
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .detach)])
    }

    @Test
    func asecondCloseAfterTheFirstIsEnqueuedIsIgnored() async {
        // The first request ends by enqueueing a route, not by completing
        // the close. Until the drain gets to it the pane is still mounted,
        // so a second ⌘W finds everything it needs and would ask again.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.deviceListResult = [booted("U", session: "S")]
        var prompts: [String] = []
        let coordinator = await makeMountedPane(
            fake,
            udid: "U",
            answer: .detach,
            asked: { name, _ in prompts.append(name) }
        )

        // The second request goes out without waiting for the drain. It must
        // raise nothing whether the first route is still queued or has
        // already removed the pane.
        await coordinator.requestClosePane(udid: "U", displayName: "iPhone")
        await coordinator.requestClosePane(udid: "U", displayName: "iPhone")
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(prompts == ["iPhone"])
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .detach)])
    }

    @Test
    func aTabThatClaimsTheSimDuringTheRosterReadStillCounts() async {
        // Tab membership sampled before the read would miss a tab created
        // while it was outstanding, and the simulator that tab is now using
        // would look unclaimed. A stored shutdown could then stop it.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C"),
            SessionCreateResponse(sessionId: "S2", capability: "C")
        ]
        fake.deviceListResult = [booted("U", session: "S2")]
        var prompts: [String] = []
        let workspace = WorkspaceViewModel()
        let router = Router(workspace: workspace, daemon: fake)
        router.dispatch(.openWindow())
        try? await Task.sleep(nanoseconds: 50_000_000)
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let coordinator = SimPaneActionCoordinator(
            tabID: tabID,
            router: router,
            daemonClient: fake,
            paneResurrect: PaneResurrect(daemonClient: fake),
            tabListVM: workspace.window(id: WindowID(value: 1))?.tabs ?? TabListViewModel(),
            windowID: WindowID(value: 1),
            askPaneClose: { _, deviceName, _, _, _ in
                prompts.append(deviceName)
                return .shutdown
            }
        )

        fake.armDeviceListBarrier()
        let close = Task { await coordinator.requestClosePane(udid: "U", displayName: "iPhone") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        // S2's tab appears only now, after the read went out.
        router.dispatch(.newTab(WindowID(value: 1)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        fake.releaseDeviceList()
        await close.value
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(prompts.isEmpty)
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .detach)])
    }

    @Test
    func choosingShutDownStopsTheSimWithThePane() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.deviceListResult = [booted("U", session: "S")]
        var prompts: [String] = []
        let coordinator = await makeMountedPane(
            fake,
            udid: "U",
            answer: .shutdown,
            asked: { name, _ in prompts.append(name) }
        )

        await coordinator.requestClosePane(udid: "U", displayName: "iPhone")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(prompts == ["iPhone"])
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .shutdown)])
    }

    @Test
    func cancellingLeavesThePaneMounted() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.deviceListResult = [booted("U", session: "S")]
        let coordinator = await makeMountedPane(
            fake,
            udid: "U",
            answer: .cancel,
            asked: { _, _ in }
        )

        await coordinator.requestClosePane(udid: "U", displayName: "iPhone")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(fake.closePaneCalls.isEmpty)
    }

    @Test
    func asecondCloseWhileTheFirstIsOpenIsIgnored() async {
        // Holding the roster read lets a second request arrive while the
        // first is still resolving. The marker is what stops it raising a
        // second prompt for the pane the first answer is already closing.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        fake.deviceListResult = [booted("U", session: "S")]
        var prompts: [String] = []
        let coordinator = await makeMountedPane(
            fake,
            udid: "U",
            answer: .detach,
            asked: { name, _ in prompts.append(name) }
        )

        // Hold the first roster read so the second request arrives while the
        // first is still resolving, which is the ordering production hits.
        fake.armDeviceListBarrier()
        let first = Task { await coordinator.requestClosePane(udid: "U", displayName: "iPhone") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let second = Task { await coordinator.requestClosePane(udid: "U", displayName: "iPhone") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        fake.releaseDeviceList()
        _ = await (first.value, second.value)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(prompts == ["iPhone"])
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .detach)])
    }

    @Test
    func aBootRecordsOwnershipInTheMirror() async {
        let fake = FakeDaemonClient()
        let (coordinator, router) = makeCoordinator(fake)

        await coordinator.bootAndReconcileOwnership(
            udid: bootUDID,
            sessionId: "S1",
            capability: "C"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(fake.bootDeviceCalls.map(\.udid) == [bootUDID])
        #expect(await restoredClaims(router, fake) == [bootUDID])
    }

    @Test
    func aFailedBootRecordsNothing() async {
        // The daemon recorded no ownership, so neither does the mirror.
        // Claiming a sim whose boot was refused would put a device DeviceTerm
        // doesn't own into the shut-down prompts after a restart.
        let fake = FakeDaemonClient()
        fake.bootDeviceError = FakeBootError.refused
        let (coordinator, router) = makeCoordinator(fake)

        await coordinator.bootAndReconcileOwnership(
            udid: bootUDID,
            sessionId: "S1",
            capability: "C"
        )

        #expect(fake.bootDeviceCalls.map(\.udid) == [bootUDID])
        #expect(await restoredClaims(router, fake).isEmpty)
    }

    @Test
    func anUncertainBootResultStillReconcilesOwnership() async {
        let fake = FakeDaemonClient()
        fake.bootDeviceError = DaemonClientError.transport("connection dropped")
        fake.bootDeviceErrorMarksClaimFailed = false
        fake.reconcileBootClaimStatus = .promoted
        let (coordinator, router) = makeCoordinator(fake)

        await coordinator.bootAndReconcileOwnership(
            udid: bootUDID,
            sessionId: "S1",
            capability: "C"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(fake.reconcileBootClaimCalls.count == 1)
        #expect(await restoredClaims(router, fake) == [bootUDID])
    }
}
