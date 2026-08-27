// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// The pane's view controller is destroyed and rebuilt whenever the daemon
/// record behind the pane is replaced, so the size preset cannot live only on
/// it. These pin the two halves of carrying it: the rebuilt controller seeds
/// itself from the pane state, and a preset that differs from the one the
/// pane rests on is reported back out so the pane state has it to hand back.
@MainActor
struct SimulatorPanePresetRestoreTests {
    @Test
    func aRestoredPresetSeedsTheChromeSelection() {
        let pane = makePane(sizePreset: .pixelAccurate)
        _ = pane.view
        #expect(pane.chromeViewModel.selectedPreset == .pixelAccurate)
    }

    @Test
    func aPaneWithNoStoredPresetShowsNoSelection() {
        let pane = makePane()
        _ = pane.view
        #expect(pane.chromeViewModel.selectedPreset == nil)
    }

    @Test
    func pickingADifferentPresetReportsItUpward() {
        let pane = makePane()
        _ = pane.view
        var reported: [SimSizePreset] = []
        pane.onSizePresetChange = { reported.append($0) }
        pane.applySizePreset(.physical)
        #expect(reported == [.physical])
    }

    @Test(arguments: [("phone", SimSizePreset.fitScreen), ("watch", .pointAccurate)])
    func thePresetThePaneIsAlreadyOnReportsNothing(family: String, resting: SimSizePreset) {
        // An auto-fit re-applies the pane's own preset after a rearrange, and
        // it must not read as a fresh choice. The family defaults are here for
        // the same reason: a user picking the one the pane already rests on
        // writes nothing, and falls back to that same default on the way back.
        let pane = makePane(family: family)
        _ = pane.view
        var reported: [SimSizePreset] = []
        pane.onSizePresetChange = { reported.append($0) }
        pane.applySizePreset(resting)
        #expect(reported.isEmpty)
    }

    @Test
    func aRestoredPresetIsTheOneTheReportMeasuresAgainst() {
        // The restored preset has to reach `lastAppliedPreset`, not just the
        // chrome, or a rearrange replays the family default over the user's
        // sizing. Re-picking it is the observable proof: only a pane already
        // resting there stays quiet.
        let pane = makePane(sizePreset: .physical)
        _ = pane.view
        var reported: [SimSizePreset] = []
        pane.onSizePresetChange = { reported.append($0) }
        pane.applySizePreset(.physical)
        #expect(reported.isEmpty)
        pane.applySizePreset(.fitScreen)
        #expect(reported == [.fitScreen])
    }

    /// An unmounted pane. `applySizePreset` walks the responder chain for a
    /// layout controller to move the divider and finds none here, which is
    /// fine: the report fires before that walk, and the divider arithmetic is
    /// pinned by `SimulatorPaneRotationLayoutTests` against a mounted pane.
    private func makePane(
        family: String = "phone",
        sizePreset: SimSizePreset? = nil
    ) -> SimulatorPaneViewController {
        SimulatorPaneViewController(
            simPane: SimPaneState(
                paneId: "p1",
                udid: "U-TEST",
                displayName: "iPhone 17 Pro",
                family: family,
                pixelWidth: 1_206,
                pixelHeight: 2_622,
                sizePreset: sizePreset
            ),
            daemonClient: FakeDaemonClient(),
            advisory: .silent()
        )
    }
}
