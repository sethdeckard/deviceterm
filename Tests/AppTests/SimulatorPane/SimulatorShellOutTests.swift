// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// The capture commands name the lit panel on a foldable and nothing on a
/// single-panel device.
///
/// Without a display, `simctl` picks a foldable's panel by its own rule,
/// which is often the dark one, so a Duo screenshot comes out black.
struct SimulatorShellOutTests {
    @Test
    func aScreenshotWithNoPanelKeepsTheDefaultArguments() {
        #expect(
            SimulatorShellOut.screenshotArguments(udid: "U1", display: nil, path: "/tmp/a.png")
                == ["simctl", "io", "U1", "screenshot", "/tmp/a.png"]
        )
    }

    @Test
    func aScreenshotNamesTheLitPanelBeforeThePath() {
        #expect(
            SimulatorShellOut.screenshotArguments(udid: "U1", display: 3, path: "/tmp/a.png")
                == ["simctl", "io", "U1", "screenshot", "--display=3", "/tmp/a.png"]
        )
    }

    @Test
    func aRecordingWithNoPanelKeepsTheDefaultArguments() {
        #expect(
            SimulatorShellOut.recordingArguments(udid: "U1", display: nil, path: "/tmp/a.mov")
                == ["simctl", "io", "U1", "recordVideo", "/tmp/a.mov"]
        )
    }

    @Test
    func aRecordingNamesTheLitPanelBeforeThePath() {
        #expect(
            SimulatorShellOut.recordingArguments(udid: "U1", display: 1, path: "/tmp/a.mov")
                == ["simctl", "io", "U1", "recordVideo", "--display=1", "/tmp/a.mov"]
        )
    }
}
