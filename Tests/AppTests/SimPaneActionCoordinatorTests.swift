// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

// The sim pane's boot legs and the owned-sim mirror.
//
// Reboot, live reboot, and post-erase boot all send `device.boot` with the
// tab's credentials, which records ownership daemon-side. All three boot from
// a shut-down sim (live reboot and erase issue the shutdown themselves;
// ordinary Reboot starts from the shutdown overlay), so a poll has already
// cleared the mirror's claim before the boot puts it back: a pane closed in
// between would leave a booted sim deviceterm owns with no live, trusted claim
// for recovery to act on.

private enum FakeBootError: Error { case refused }

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
            simResurrect: SimResurrect(daemonClient: fake),
            tabListVM: TabListViewModel()
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

    @Test
    func aBootRecordsOwnershipInTheMirror() async {
        let fake = FakeDaemonClient()
        let (coordinator, router) = makeCoordinator(fake)

        await coordinator.bootAndRecordOwnership(
            udid: "U",
            sessionId: "S1",
            capability: "C"
        )

        #expect(fake.bootDeviceCalls.map(\.udid) == ["U"])
        #expect(await restoredClaims(router, fake) == ["u"])
    }

    @Test
    func aFailedBootRecordsNothing() async {
        // The daemon recorded no ownership, so neither does the mirror.
        // Claiming a sim whose boot was refused would put a device DeviceTerm
        // doesn't own into the shut-down prompts after a restart.
        let fake = FakeDaemonClient()
        fake.bootDeviceError = FakeBootError.refused
        let (coordinator, router) = makeCoordinator(fake)

        await coordinator.bootAndRecordOwnership(
            udid: "U",
            sessionId: "S1",
            capability: "C"
        )

        #expect(fake.bootDeviceCalls.map(\.udid) == ["U"])
        #expect(await restoredClaims(router, fake).isEmpty)
    }
}
